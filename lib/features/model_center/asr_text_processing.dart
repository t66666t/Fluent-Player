import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import 'asr_enhancement_options.dart';
import 'asr_enhancement_processing.dart';
import 'qwen_asr_runtime.dart';

class AsrTextUnit {
  const AsrTextUnit(this.text, this.start, this.end);
  final String text;
  final int start, end;
}

class AsrLanguageDecision {
  const AsrLanguageDecision(this.language, this.source, [this.confidence]);
  final String language, source;
  final double? confidence;
  bool get known => language.isNotEmpty && language != 'und';
}

/// Script is evidence, not a blanket Han->Chinese or Latin->English rule.
AsrLanguageDecision decideAsrLanguage({
  required String text,
  String selected = 'auto',
  String recognized = '',
  String identified = '',
  double? confidence,
  String neighboring = '',
  bool shortSpeech = false,
}) {
  final manual = normalizeAsrLanguage(selected);
  if (manual.isNotEmpty && manual != 'auto') {
    return AsrLanguageDecision(manual, 'selected');
  }
  final kana = RegExp(r'[\u3040-\u30ff]').hasMatch(text);
  final hangul = RegExp(
    r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
  ).hasMatch(text);
  bool compatible(String language) =>
      (kana && hangul ? language == 'ja' || language == 'ko' : true) &&
      (!kana || hangul || language == 'ja') &&
      (!hangul || kana || language == 'ko');
  bool known(String value) =>
      RegExp(r'^[a-z]{2,3}$').hasMatch(value) &&
      !{'und', 'nan'}.contains(value);
  final tag = normalizeAsrLanguage(recognized);
  if (tag.isNotEmpty && known(tag) && compatible(tag)) {
    return AsrLanguageDecision(tag, 'asr');
  }
  if (kana && !hangul) return const AsrLanguageDecision('ja', 'script');
  if (hangul && !kana) return const AsrLanguageDecision('ko', 'script');
  final audio = normalizeAsrLanguage(identified.split(',').first.trim());
  if (!shortSpeech &&
      known(audio) &&
      confidence != null &&
      confidence.isFinite &&
      confidence >= .8 &&
      compatible(audio)) {
    return AsrLanguageDecision(audio, 'audio', confidence);
  }
  final neighbor = normalizeAsrLanguage(neighboring);
  if (shortSpeech && known(neighbor) && compatible(neighbor)) {
    return AsrLanguageDecision(neighbor, 'context');
  }
  return const AsrLanguageDecision('und', 'uncertain');
}

/// A single enhancement owner can switch between LID and alignment; their
/// large model buffers are never resident together. Dictionaries are shared.
class AsrTextProcessor {
  AsrTextProcessor({
    required this.directories,
    required this.threads,
    required this.checkCancelled,
    this.acceleration = 'cpu',
    this.review = true,
    QwenAsrRuntime? runtime,
  }) : runtime = runtime ?? QwenAsrRuntime();
  final Map<String, String> directories;
  int threads;
  final void Function() checkCancelled;
  final String acceleration;
  final bool review;
  final QwenAsrRuntime runtime;
  String? residentModelId;
  int? _loadedThreads;
  bool _languageFailed = false;
  bool _alignmentCpuFallback = false;
  bool memoryCpuAlignment = false;
  String _alignmentBackend = 'cpu';
  final _units = <String, List<AsrTextUnit>>{};
  static const textWorkingSetBytes = 160 * 1024 * 1024;

  int modelBytes(String id, {bool? gpu}) {
    final directory = directories[id];
    if (directory == null) return 0;
    final file = p.join(
      directory,
      id == AsrEnhancementOptions.languageId
          ? 'ecapa-lid-107-f16.gguf'
          : 'qwen3-forced-aligner-0.6b-f16.gguf',
    );
    if (!File(file).existsSync()) return 0;
    return id == AsrEnhancementOptions.alignmentQwenId
        ? qwenAudioWorkingSetBytes(
            File(file).lengthSync(),
            gpu:
                gpu ??
                (acceleration != 'cpu' &&
                    !_alignmentCpuFallback &&
                    !memoryCpuAlignment),
          )
        : File(file).lengthSync() * 3;
  }

  int get residentBytes => residentModelId == null
      ? 0
      : modelBytes(
          residentModelId!,
          gpu: !runtime.backend.toLowerCase().startsWith('cpu'),
        );

  Future<T> _retryWorker<T>(Future<T> Function() work) async {
    try {
      return await work();
    } catch (error) {
      checkCancelled();
      if (!isQwenWorkerUnavailable(error)) rethrow;
      await release();
      return work();
    }
  }

  Future<void> _load(String id, String kind) async {
    checkCancelled();
    if (residentModelId == id &&
        runtime.hasLoadedModel &&
        _loadedThreads == threads) {
      return;
    }
    final directory = directories[id];
    if (directory == null) throw StateError('共享增强模型尚未准备完成：$id');
    var backend = 'cpu';
    if (kind == 'aligner' &&
        acceleration != 'cpu' &&
        !_alignmentCpuFallback &&
        !memoryCpuAlignment) {
      _alignmentBackend = 'gpu';
      backend = await runtime.preferredBackend();
    }
    if (kind == 'aligner') _alignmentBackend = backend;
    residentModelId = null;
    await runtime.load(
      kind: kind,
      model: p.join(
        directory,
        kind == 'lid'
            ? 'ecapa-lid-107-f16.gguf'
            : 'qwen3-forced-aligner-0.6b-f16.gguf',
      ),
      threads: threads,
      backend: backend,
    );
    residentModelId = id;
    _loadedThreads = threads;
    checkCancelled();
  }

  Float32List _audio(SubtitleItem cue, Float32List audio) {
    final start = (cue.startTime.inMicroseconds * 16000 ~/ 1000000).clamp(
      0,
      audio.length,
    );
    final end = (cue.endTime.inMicroseconds * 16000 ~/ 1000000).clamp(
      start,
      audio.length,
    );
    return Float32List.sublistView(audio, start, end);
  }

  int _speechSamples(Float32List audio) {
    final energy = <double>[];
    double peak = 0;
    for (var at = 0; at + 320 <= audio.length; at += 320) {
      double value = 0;
      for (var i = at; i < at + 320; i++) {
        value += audio[i] * audio[i];
      }
      energy.add(value / 320);
      peak = math.max(peak, value / 320);
    }
    final threshold = math.max(1e-8, peak * .001);
    return energy.where((value) => value > threshold).length * 320;
  }

  Float32List _languageAudio(
    List<SubtitleItem> cues,
    int index,
    Float32List audio,
  ) {
    var samples = _audio(cues[index], audio);
    if (_speechSamples(samples) >= 24000) return samples;
    var start = index, end = index;
    for (var i = 0; i < 2; i++) {
      if (start > 0 &&
          cues[start].startTime - cues[start - 1].endTime <=
              const Duration(milliseconds: 900)) {
        start--;
      }
      if (end + 1 < cues.length &&
          cues[end + 1].startTime - cues[end].endTime <=
              const Duration(milliseconds: 900)) {
        end++;
      }
    }
    // Do not infer a short cue from a window with conflicting known languages.
    final labels = <String>{};
    final pieces = <Float32List>[];
    var total = 0;
    for (var i = start; i <= end; i++) {
      final decision = decideAsrLanguage(
        text: cues[i].text,
        recognized: cues[i].asrInfo.language,
      );
      if (decision.known) labels.add(decision.language);
      final piece = _audio(cues[i], audio);
      if (total + piece.length > 6 * 16000) continue;
      pieces.add(piece);
      total += piece.length;
    }
    if (labels.length > 1 || total <= samples.length) return samples;
    samples = Float32List(total);
    var at = 0;
    for (final piece in pieces) {
      samples.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return samples;
  }

  Future<List<SubtitleItem>> resolveLanguages(
    List<SubtitleItem> cues,
    Float32List audio,
    String selected, {
    bool allowAudioModel = true,
  }) async {
    final result = <SubtitleItem>[];
    for (var i = 0; i < cues.length; i++) {
      checkCancelled();
      final cue = cues[i];
      var decision = decideAsrLanguage(
        text: cue.text,
        selected: selected,
        recognized: cue.asrInfo.language,
      );
      if (!decision.known) {
        final short = _speechSamples(_audio(cue, audio)) < 24000;
        String neighbor = '';
        if (short) {
          final labels = <String>{};
          if (result.isNotEmpty &&
              cue.startTime - result.last.endTime <=
                  const Duration(milliseconds: 900)) {
            final label = normalizeAsrLanguage(result.last.asrInfo.language);
            if (label.isNotEmpty && label != 'und') labels.add(label);
          }
          if (i + 1 < cues.length &&
              cues[i + 1].startTime - cue.endTime <=
                  const Duration(milliseconds: 900)) {
            final next = decideAsrLanguage(
              text: cues[i + 1].text,
              selected: selected,
              recognized: cues[i + 1].asrInfo.language,
            );
            if (next.known) labels.add(next.language);
          }
          if (labels.length == 1) neighbor = labels.single;
        }
        decision = decideAsrLanguage(
          text: cue.text,
          selected: selected,
          recognized: cue.asrInfo.language,
          neighboring: neighbor,
          shortSpeech: short,
        );
        if (allowAudioModel &&
            !decision.known &&
            !_languageFailed &&
            directories.containsKey(AsrEnhancementOptions.languageId)) {
          try {
            var samples = _languageAudio(cues, i, audio);
            if (_speechSamples(samples) < 24000) {
              samples = Float32List(0);
            }
            if (samples.isEmpty) {
              // No adequate neighbor audio: retain the uncertain decision.
            } else {
              if (samples.length > 6 * 16000) {
                samples = Float32List.sublistView(samples, 0, 6 * 16000);
              }
              final response = await _retryWorker(() async {
                await _load(AsrEnhancementOptions.languageId, 'lid');
                return runtime.audioRequest(
                  'identify',
                  samples,
                  checkCancelled,
                );
              });
              decision = decideAsrLanguage(
                text: cue.text,
                selected: selected,
                recognized: cue.asrInfo.language,
                identified: response['language'] as String? ?? '',
                confidence: (response['confidence'] as num?)?.toDouble(),
              );
            }
          } catch (_) {
            checkCancelled();
            _languageFailed = true;
            await release();
          }
        }
      }
      result.add(
        cue.copyWith(
          asrInfo: cue.asrInfo.copyWith(
            language: decision.known ? decision.language : 'und',
            notes: [
              ...cue.asrInfo.notes,
              '语言判定：${decision.source}${decision.confidence == null ? '' : ' · ${(decision.confidence! * 100).round()}%'}',
            ],
            reviewReason: decision.known
                ? cue.asrInfo.reviewReason
                : review
                ? '语言信息不足，保留原有时间'
                : '',
          ),
        ),
      );
    }
    return result;
  }

  Future<List<AsrTextUnit>> units(String text, String language) async {
    final key = '$language\u0000$text';
    if (_units[key] case final cached?) return cached;
    final result = <AsrTextUnit>[];
    if (language == 'ja' || language == 'ko') {
      final response = await _retryWorker(
        () => runtime.request({
          'op': 'tokenize',
          'text': text,
          'language': language,
        }),
      );
      checkCancelled();
      for (final raw in response['units'] as List) {
        final unit = Map<String, dynamic>.from(raw as Map);
        result.add(
          AsrTextUnit(
            unit['text'] as String,
            (unit['start'] as num).toInt(),
            (unit['end'] as num).toInt(),
          ),
        );
      }
    } else {
      final expression = RegExp(
        language == 'zh' || language == 'yue'
            ? r"[\u3400-\u9fff]|[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"
            : r"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*",
        unicode: true,
      );
      for (final match in expression.allMatches(text)) {
        result.add(AsrTextUnit(match[0]!, match.start, match.end));
      }
    }
    final boundaries = <int>{0};
    var offset = 0;
    for (final glyph in text.characters) {
      offset += glyph.length;
      boundaries.add(offset);
    }
    var previous = 0;
    for (final unit in result) {
      if (unit.text.isEmpty ||
          unit.start < previous ||
          unit.end <= unit.start ||
          !boundaries.contains(unit.start) ||
          !boundaries.contains(unit.end)) {
        throw StateError('分词返回了无效的原文范围');
      }
      previous = unit.end;
    }
    if (_units.length > 128) _units.clear();
    return _units[key] = result;
  }

  Future<List<SubtitleTimedSpan>?> align(
    SubtitleItem cue,
    Float32List audio,
  ) async {
    final words = await units(cue.text, cue.asrInfo.language);
    final samples = _audio(cue, audio);
    if (words.isEmpty || samples.isEmpty || samples.length > 25 * 16000) {
      return null;
    }
    Future<Map<String, dynamic>> run() async {
      await _load(AsrEnhancementOptions.alignmentQwenId, 'aligner');
      final response = await runtime.audioRequest(
        'align',
        samples,
        checkCancelled,
        fields: {
          'words': [for (final unit in words) unit.text],
        },
      );
      if (!runtime.backend.toLowerCase().startsWith('cpu') &&
          (response['gpuOperators'] as num? ?? 0) <= 0) {
        throw StateError('共享对齐未在 GPU 执行有效算子');
      }
      return response;
    }

    Map<String, dynamic> response;
    try {
      response = await run();
    } catch (error) {
      checkCancelled();
      if (_alignmentBackend == 'cpu' && !isQwenWorkerUnavailable(error)) {
        rethrow;
      }
      _alignmentCpuFallback = true;
      await release();
      response = await run();
    }
    return validatedQwenAlignment(
      cue,
      words,
      response['times'] as List,
      samples.length,
      samples,
    );
  }

  Future<List<SubtitleItem>> attachBoundaries(List<SubtitleItem> cues) async {
    final result = <SubtitleItem>[];
    for (final cue in cues) {
      if (cue.asrInfo.language != 'ja' && cue.asrInfo.language != 'ko') {
        result.add(cue);
        continue;
      }
      try {
        final words = await units(cue.text, cue.asrInfo.language);
        result.add(
          cue.copyWith(
            asrInfo: cue.asrInfo.copyWith(
              wordBoundaries: {
                for (final word in words) ...[word.start, word.end],
              }.toList()..sort(),
            ),
          ),
        );
      } catch (_) {
        checkCancelled();
        result.add(
          cue.copyWith(
            asrInfo: cue.asrInfo.copyWith(
              notes: [...cue.asrInfo.notes, '日韩分词组件不可用，保留原有字幕边界'],
            ),
          ),
        );
      }
    }
    return result;
  }

  Future<void> release() async {
    residentModelId = null;
    _loadedThreads = null;
    await runtime.release();
  }

  Future<void> close() async {
    residentModelId = null;
    _loadedThreads = null;
    await runtime.close();
  }
}

/// Coalesce zero-duration timestamp bins with adjacent units, never estimate
/// an internal word boundary by text length. Reject bad coordinates as a whole.
List<SubtitleTimedSpan>? validatedQwenAlignment(
  SubtitleItem cue,
  List<AsrTextUnit> units,
  List times,
  int samples, [
  Float32List? audio,
]) {
  if (units.length != times.length || units.isEmpty) return null;
  final durationUs = samples * 1000000 ~/ 16000;
  final result = <SubtitleTimedSpan>[];
  int? pendingStart;
  var previousStart = -1, previousEnd = -1;
  for (var i = 0; i < units.length; i++) {
    final raw = times[i];
    if (raw is! Map || raw['startMs'] is! num || raw['endMs'] is! num) {
      return null;
    }
    final start = (raw['startMs'] as num).toDouble() * 1000;
    final end = (raw['endMs'] as num).toDouble() * 1000;
    if (!start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end < start ||
        end > durationUs + 80000 ||
        start < previousStart ||
        start < previousEnd ||
        end < previousEnd ||
        start > durationUs) {
      return null;
    }
    previousStart = start.round();
    previousEnd = end.round();
    pendingStart ??= i;
    final boundedEnd = math.min(end.round(), durationUs);
    final begin = (times[pendingStart] as Map)['startMs'] as num;
    final beginUs = (begin * 1000).round();
    if (boundedEnd <= beginUs) continue;
    result.add(
      SubtitleTimedSpan(
        textStart: units[pendingStart].start,
        textEnd: units[i].end,
        startTime: cue.startTime + Duration(microseconds: beginUs),
        endTime: cue.startTime + Duration(microseconds: boundedEnd),
        role: 'aligned',
      ),
    );
    pendingStart = null;
  }
  if (pendingStart != null) {
    if (result.isEmpty) return null;
    final last = result.removeLast();
    result.add(
      SubtitleTimedSpan(
        textStart: last.textStart,
        textEnd: units.last.end,
        startTime: last.startTime,
        endTime: last.endTime,
        role: 'aligned',
      ),
    );
  }
  if (audio != null && result.isNotEmpty) {
    double peakEnergy = 0;
    final energies = <double>[];
    for (var at = 0; at + 320 <= audio.length; at += 320) {
      double energy = 0;
      for (var j = at; j < at + 320; j++) {
        energy += audio[j] * audio[j];
      }
      energy /= 320;
      energies.add(energy);
      peakEnergy = math.max(peakEnergy, energy);
    }
    // A word crossing >= 0.9 seconds of near-silence is unreliable. The
    // threshold is relative to this utterance, preserving quiet recordings.
    final threshold = math.max(1e-8, peakEnergy * .0009);
    for (final span in result) {
      final begin = ((span.startTime - cue.startTime).inMicroseconds ~/ 20000)
          .clamp(0, energies.length);
      final end = ((span.endTime - cue.startTime).inMicroseconds ~/ 20000)
          .clamp(begin, energies.length);
      var silent = 0;
      for (var i = begin; i < end; i++) {
        silent = energies[i] < threshold ? silent + 1 : 0;
        if (silent >= 45) return null;
      }
    }
  }
  return result.isEmpty ? null : result;
}
