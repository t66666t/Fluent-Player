import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../../models/subtitle_model.dart';
import 'asr_enhancement_options.dart';
import 'asr_enhancement_processing.dart';
import 'asr_onnx_session.dart';
import 'ctc_forced_alignment.dart';
import 'subtitle_segmentation.dart';
import 'asr_text_processing.dart';
import 'qwen_asr_runtime.dart';

typedef AsrPhaseProgress =
    void Function(String phase, double fraction, String message);

Future<String> probeAsrEnhancement(
  String engine,
  Map<String, String> directories,
  Float32List samples, {
  int threads = 2,
  String? libraryDirectory,
  String? qwenWorkerExecutable,
}) {
  final rootToken = RootIsolateToken.instance;
  return Isolate.run(() async {
    if (rootToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    }
    if (engine == 'qwen3-alignment' || engine == 'ecapa-language-id') {
      final runtime = QwenAsrRuntime(executable: qwenWorkerExecutable);
      final aligner = engine == 'qwen3-alignment';
      final id = aligner
          ? AsrEnhancementOptions.alignmentQwenId
          : AsrEnhancementOptions.languageId;
      try {
        await runtime.load(
          kind: aligner ? 'aligner' : 'lid',
          model: p.join(
            directories[id]!,
            aligner
                ? 'qwen3-forced-aligner-0.6b-f16.gguf'
                : 'ecapa-lid-107-f16.gguf',
          ),
          threads: threads,
        );
        final response = await runtime.audioRequest(
          aligner ? 'align' : 'identify',
          Float32List.sublistView(
            samples,
            0,
            math.min(samples.length, 6 * 16000),
          ),
          () {},
          fields: aligner
              ? {
                  // speech_probe_zh.wav opens with 欢迎.
                  'words': ['欢', '迎'],
                }
              : const {},
        );
        if (aligner) {
          if ((response['times'] as List).length != 2) {
            throw StateError('共享对齐器未返回时间');
          }
          return '共享强制对齐真实推理通过';
        }
        final confidence = (response['confidence'] as num).toDouble();
        if (!confidence.isFinite || confidence < 0 || confidence > 1) {
          throw StateError('语言识别概率无效');
        }
        return '音频语言识别：${response['language']} · ${(confidence * 100).round()}%';
      } finally {
        await runtime.close();
      }
    }
    sherpa.initBindings(libraryDirectory);
    final helper = AsrNativeEnhancer(
      options: const AsrEnhancementOptions(),
      directories: directories,
      threads: threads,
      checkCancelled: () {},
      progress: (_, _, _) {},
    );
    try {
      if (engine == 'denoiser') {
        final result = await helper.denoise(samples);
        if (result.length != samples.length) throw StateError('降噪采样坐标校验失败');
        return '16 kHz 降噪通过 · ${result.length} 个采样点';
      }
      if (engine == 'punctuation') {
        final model = sherpa.OfflinePunctuation(
          config: sherpa.OfflinePunctuationConfig(
            model: sherpa.OfflinePunctuationModelConfig(
              ctTransformer: helper._file(
                AsrEnhancementOptions.punctuationId,
                'model.int8.onnx',
              ),
              numThreads: math.min(threads, 2),
              provider: 'cpu',
            ),
          ),
        );
        try {
          const text = '你好欢迎使用本地语音识别这是一段测试语音';
          final result = model.addPunct(text);
          if (asrTextAgreement(text, result) < .999) {
            throw StateError('标点模型改写了测试原文');
          }
          return result;
        } finally {
          model.free();
        }
      }
      if (engine.startsWith('ctc-alignment-')) {
        helper.usedOrt = true;
        final id = engine.endsWith('-zh')
            ? AsrEnhancementOptions.alignmentChineseId
            : AsrEnhancementOptions.alignmentEnglishId;
        final session = openAsrOnnxSession(
          helper._file(id, 'model.int8.onnx'),
          threads,
        );
        try {
          final data = normalizeAlignmentAudio(
            Float32List.fromList(samples.take(32000).toList()),
          );
          final tensors = <String, OrtValue>{
            'input_values': OrtValueTensor.createTensorWithDataList(data, [
              1,
              data.length,
            ]),
            if (session.inputNames.contains('attention_mask'))
              'attention_mask': OrtValueTensor.createTensorWithDataList(
                Int64List.fromList(List.filled(data.length, 1)),
                [1, data.length],
              ),
          };
          final run = OrtRunOptions();
          List<OrtValue?> outputs = [];
          try {
            outputs = session.run(run, tensors);
            final batch = outputs.first?.value as List;
            if ((batch.single as List).isEmpty) {
              throw StateError('CTC 声学模型未返回帧');
            }
            return 'CTC 声学推理通过 · ${(batch.single as List).length} 帧';
          } finally {
            for (final v in outputs) {
              v?.release();
            }
            for (final v in tensors.values) {
              v.release();
            }
            run.release();
          }
        } finally {
          session.release();
        }
      }
      throw StateError('未知增强引擎：$engine');
    } finally {
      await helper.dispose();
      if (helper.usedOrt) OrtEnv.instance.release();
    }
  });
}

class AsrNativeEnhancer {
  AsrNativeEnhancer({
    required this.options,
    required this.directories,
    required this.threads,
    required this.checkCancelled,
    required this.progress,
    this.language = 'auto',
    this.recognitionEngine = '',
    this.naturalPunctuationContext = false,
    this.retainModels = false,
    this.beforeAlignment,
    this.textProcessingVersion,
    this.qwenWorkerExecutable,
    this.qwenAcceleration = 'cpu',
  });
  final AsrEnhancementOptions options;
  final Map<String, String> directories;
  final int threads;
  final String language;
  final String recognitionEngine;
  final bool naturalPunctuationContext;
  bool retainModels;
  final Future<void> Function()? beforeAlignment;
  final int? textProcessingVersion;
  final String? qwenWorkerExecutable;
  final String qwenAcceleration;
  late final AsrTextProcessor _text = AsrTextProcessor(
    directories: directories,
    threads: threads,
    checkCancelled: checkCancelled,
    runtime: QwenAsrRuntime(executable: qwenWorkerExecutable),
    acceleration: qwenAcceleration,
    review: options.review,
  );
  sherpa.OfflineSpeechDenoiser? _denoiser;
  sherpa.OfflinePunctuation? _punctuationModel;
  _AlignmentResources? _alignmentCache;
  final void Function() checkCancelled;
  final AsrPhaseProgress progress;
  bool usedOrt = false;
  set qwenThreads(int value) => _text.threads = value.clamp(1, 12);
  void useCpuAlignmentForMemory() => _text.memoryCpuAlignment = true;
  bool needsQwenAlignment(
    List<SubtitleItem> cues, {
    bool languagesResolved = false,
  }) =>
      options.enabled &&
      options.alignment &&
      cues.any(
        (cue) =>
            (options.alwaysAlign || !hasUsableAsrTiming(cue)) &&
            asrAlignmentModelCandidates(
              cue,
              language,
              availableModels: directories.keys,
              recognitionEngine: recognitionEngine,
              textProcessingVersion: textProcessingVersion,
              languagesResolved: languagesResolved,
            ).contains(AsrEnhancementOptions.alignmentQwenId),
      );
  int get residentAlignmentBytes =>
      (_alignmentCache == null
          ? 0
          : asrAlignmentWorkingSetBytes(
              _alignmentCache!.id,
              File(_file(_alignmentCache!.id, 'model.int8.onnx')).lengthSync(),
              textProcessingVersion: textProcessingVersion,
              recognitionEngine: recognitionEngine,
            )) +
      (usesAsrTextProcessing(textProcessingVersion)
          ? _text.residentBytes +
                (_text.runtime.isOpen
                    ? AsrTextProcessor.textWorkingSetBytes
                    : 0)
          : 0);
  String? get residentAlignmentId =>
      _alignmentCache?.id ??
      (usesAsrTextProcessing(textProcessingVersion)
          ? _text.residentModelId
          : null);
  int get textAllocationBytes =>
      usesAsrTextProcessing(textProcessingVersion) && options.enabled
      ? AsrTextProcessor.textWorkingSetBytes +
            _text.modelBytes(AsrEnhancementOptions.languageId)
      : 0;
  int get residentPunctuationBytes => _punctuationModel == null
      ? 0
      : File(
              _file(AsrEnhancementOptions.punctuationId, 'model.int8.onnx'),
            ).lengthSync() *
            3;
  int punctuationAllocationBytes(
    List<SubtitleItem> cues, {
    bool languagesResolved = false,
  }) =>
      !options.enabled ||
          !options.punctuation ||
          _punctuationModel != null ||
          !directories.containsKey(AsrEnhancementOptions.punctuationId) ||
          !_punctuationInput(cues).any(
            (cue) =>
                _needsPunctuation(cue) ||
                !languagesResolved &&
                    usesAsrTextProcessing(textProcessingVersion) &&
                    _alignmentLanguage(cue).isEmpty &&
                    !RegExp(r'[。！？.!?]').hasMatch(cue.text) ||
                _mayAlign(cue) && !RegExp(r'[。！？.!?]').hasMatch(cue.text),
          )
      ? 0
      : File(
              _file(AsrEnhancementOptions.punctuationId, 'model.int8.onnx'),
            ).lengthSync() *
            3;
  int get denoiseAllocationBytes =>
      !options.enabled || !options.denoise || _denoiser != null
      ? 0
      : File(
              _file(AsrEnhancementOptions.denoiserId, 'model.onnx'),
            ).lengthSync() *
            3;
  int alignmentAllocationBytes(
    List<SubtitleItem> cues, {
    bool languagesResolved = false,
  }) {
    if (!options.enabled || !options.alignment) return 0;
    var bytes = 0;
    for (final cue in cues) {
      if (!options.alwaysAlign && hasUsableAsrTiming(cue)) continue;
      for (final id in asrAlignmentModelCandidates(
        cue,
        language,
        availableModels: directories.keys,
        recognitionEngine: recognitionEngine,
        textProcessingVersion: textProcessingVersion,
        languagesResolved: languagesResolved,
      )) {
        if (id == AsrEnhancementOptions.alignmentQwenId) {
          if (_text.residentModelId != id) {
            bytes = math.max(bytes, _text.modelBytes(id));
          }
        } else if (_alignmentCache?.id != id && directories[id] != null) {
          bytes = math.max(
            bytes,
            asrAlignmentWorkingSetBytes(
              id,
              File(_file(id, 'model.int8.onnx')).lengthSync(),
              textProcessingVersion: textProcessingVersion,
              recognitionEngine: recognitionEngine,
            ),
          );
        }
      }
    }
    return bytes;
  }

  Future<void> releaseAlignment() async {
    _alignmentCache?.close();
    _alignmentCache = null;
    if (usesAsrTextProcessing(textProcessingVersion)) await _text.release();
  }

  Future<void> dispose() async {
    _denoiser?.free();
    _denoiser = null;
    _punctuationModel?.free();
    _punctuationModel = null;
    await releaseAlignment();
  }

  String _file(String id, String filename) {
    final folder = directories[id];
    if (folder == null) throw StateError('增强权重尚未准备完成：$id');
    return p.join(folder, filename);
  }

  Future<Float32List> denoise(Float32List original) async {
    if (!options.enabled || !options.denoise || original.isEmpty) {
      return original;
    }
    progress('denoising', 0, '正在进行轻量降噪');
    final model = _denoiser ??= sherpa.OfflineSpeechDenoiser(
      sherpa.OfflineSpeechDenoiserConfig(
        model: sherpa.OfflineSpeechDenoiserModelConfig(
          gtcrn: sherpa.OfflineSpeechDenoiserGtcrnModelConfig(
            model: _file(AsrEnhancementOptions.denoiserId, 'model.onnx'),
          ),
          numThreads: math.min(threads, 2),
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    try {
      const window = 4 * 16000, overlap = 2560;
      final result = Float32List(original.length);
      for (var start = 0; start < original.length; start += window - overlap) {
        checkCancelled();
        final end = math.min(start + window, original.length);
        final input = Float32List.sublistView(original, start, end);
        // GTCRN emits complete 256-sample STFT hops. Flush the final hop with
        // zero context, then crop; never lose or stretch the original tail.
        final padded = Float32List(((input.length + 255) ~/ 256) * 256 + 512)
          ..setAll(0, input);
        final output = model.run(samples: padded, sampleRate: 16000);
        if (output.sampleRate != 16000 ||
            output.samples.length < input.length ||
            output.samples.length - input.length > 1024 ||
            output.samples.any((v) => !v.isFinite)) {
          throw StateError(
            '降噪模型没有保持 16 kHz 采样坐标：${output.sampleRate} Hz，${input.length} → ${output.samples.length} 点',
          );
        }
        for (var i = 0; i < input.length; i++) {
          final fade = start > 0 && i < overlap ? i / overlap : 1.0;
          result[start +
              i] = (result[start + i] * (1 - fade) + output.samples[i] * fade)
              .clamp(-1.0, 1.0);
        }
        progress(
          'denoising',
          end / original.length,
          '正在降噪 · ${(end / 16000).round()} 秒',
        );
        await Future<void>.delayed(Duration.zero);
        if (end == original.length) break;
      }
      return result;
    } finally {
      if (!retainModels) {
        model.free();
        _denoiser = null;
      }
    }
  }

  Future<List<SubtitleItem>> enhance(
    List<SubtitleItem> raw,
    Float32List audio, {
    bool languagesResolved = false,
    bool allowAlignment = true,
  }) async {
    if (!options.enabled || raw.isEmpty) return raw;
    var cues = raw;
    if (!languagesResolved) cues = await resolveLanguages(cues, audio);
    if (allowAlignment && options.alignment) cues = await _align(cues, audio);
    if (allowAlignment &&
        options.alignment &&
        usesAsrTextProcessing(textProcessingVersion)) {
      cues = await _alignQwen(cues, audio);
    }
    if (options.punctuation) cues = await _punctuate(cues);
    if (options.trimSilence) {
      progress('refining', 0, '正在修整字幕静音边界');
      cues = [for (final cue in cues) trimAsrSilence(cue, audio)];
      progress('refining', 1, '字幕边界修整完成');
    }
    if (usesAsrTextProcessing(textProcessingVersion)) {
      cues = await _text.attachBoundaries(cues);
    }
    if (!retainModels && usesAsrTextProcessing(textProcessingVersion)) {
      await _text.release();
    }
    return cues;
  }

  Future<List<SubtitleItem>> resolveLanguages(
    List<SubtitleItem> cues,
    Float32List audio, {
    bool allowAudioModel = true,
  }) async {
    if (!options.enabled || !usesAsrTextProcessing(textProcessingVersion)) {
      return cues;
    }
    final result = await _text.resolveLanguages(
      cues,
      audio,
      language,
      allowAudioModel: allowAudioModel,
    );
    // LID and the next alignment model are distinct stages. Do not retain a
    // language model while asking the governor to admit the alignment model.
    if (_text.residentModelId == AsrEnhancementOptions.languageId) {
      await _text.release();
    }
    return result;
  }

  Future<void> releaseUnusedModels(List<SubtitleItem> cues) async {
    final needsAlignment =
        options.enabled &&
        options.alignment &&
        cues.any(
          (cue) =>
              (options.alwaysAlign || !hasUsableAsrTiming(cue)) &&
              directories.containsKey(_alignmentId(cue)),
        );
    if (!needsAlignment) await releaseAlignment();
    if (!_punctuationInput(cues).any(_needsPunctuation)) {
      _punctuationModel?.free();
      _punctuationModel = null;
    }
  }

  int get resolvedTextAllocationBytes =>
      usesAsrTextProcessing(textProcessingVersion) && options.enabled
      ? AsrTextProcessor.textWorkingSetBytes
      : 0;

  int languageAllocationBytes(List<SubtitleItem> cues) =>
      usesAsrTextProcessing(textProcessingVersion) &&
          options.enabled &&
          cues.any(
            (cue) => !decideAsrLanguage(
              text: cue.text,
              selected: language,
              recognized: cue.asrInfo.language,
            ).known,
          )
      ? textAllocationBytes
      : 0;

  String _alignmentLanguage(SubtitleItem cue) => asrAlignmentLanguage(
    cue,
    language,
    textProcessingVersion: textProcessingVersion,
  );
  String _alignmentId(SubtitleItem cue) => asrAlignmentModelId(
    cue,
    language,
    recognitionEngine: recognitionEngine,
    textProcessingVersion: textProcessingVersion,
    availableModels: directories.keys,
  );
  Future<List<SubtitleItem>> _alignQwen(
    List<SubtitleItem> input,
    Float32List audio,
  ) async {
    final result = <SubtitleItem>[];
    for (final cue in input) {
      if (_alignmentId(cue) != AsrEnhancementOptions.alignmentQwenId ||
          !directories.containsKey(AsrEnhancementOptions.alignmentQwenId) ||
          !options.alwaysAlign && hasUsableAsrTiming(cue)) {
        result.add(cue);
        continue;
      }
      checkCancelled();
      _alignmentCache?.close();
      _alignmentCache = null;
      await beforeAlignment?.call();
      checkCancelled();
      progress(
        'aligning',
        result.length / math.max(1, input.length),
        '正在进行共享多语言时间精校',
      );
      try {
        final spans = await _text.align(cue, audio);
        if (spans == null) throw StateError('对齐时间没有通过边界校验');
        result.add(
          cue.copyWith(
            timedSpans: spans,
            asrInfo: cue.asrInfo.copyWith(
              notes: [...cue.asrInfo.notes, 'Qwen3 ForcedAligner 时间精校'],
            ),
          ),
        );
      } catch (error) {
        checkCancelled();
        result.add(
          cue.copyWith(
            asrInfo: cue.asrInfo.copyWith(
              reviewReason: options.review ? '多语言精校未通过，保留原始时间轴' : '',
              notes: [...cue.asrInfo.notes, '未采用共享对齐结果：$error'],
            ),
          ),
        );
      }
    }
    return guardAsrAlignmentBoundaries(input, result, review: options.review);
  }

  bool _mayAlign(SubtitleItem cue) {
    final id = _alignmentId(cue);
    return options.enabled &&
        options.alignment &&
        (options.alwaysAlign || !hasUsableAsrTiming(cue)) &&
        id != AsrEnhancementOptions.alignmentQwenId &&
        directories.containsKey(id);
  }

  Future<List<SubtitleItem>> _align(
    List<SubtitleItem> input,
    Float32List audio,
  ) async {
    final result = [...input];
    var done = 0;
    final candidates = input.where(_mayAlign).length;
    if (candidates > 0 && usesAsrTextProcessing(textProcessingVersion)) {
      await _text.release();
    }
    for (final lang in ['zh', 'en']) {
      final id = lang == 'zh'
          ? AsrEnhancementOptions.alignmentChineseId
          : AsrEnhancementOptions.alignmentEnglishId;
      final indexes = [
        for (var i = 0; i < input.length; i++)
          if (_alignmentLanguage(input[i]) == lang && _mayAlign(input[i])) i,
      ];
      if (indexes.isEmpty || !directories.containsKey(id)) continue;
      checkCancelled();
      await beforeAlignment?.call();
      checkCancelled();
      progress(
        'aligning',
        done / math.max(1, candidates),
        '${_alignmentCache?.id == id ? '正在复用' : '正在加载'}${lang == 'zh' ? '普通话' : '英语'}时间精校模型',
      );
      usedOrt = true;
      if (_alignmentCache != null && _alignmentCache!.id != id) {
        _alignmentCache!.close();
        _alignmentCache = null;
      }
      final vocabulary =
          _alignmentCache?.vocabulary ??
          Map<String, int>.from(
            jsonDecode(await File(_file(id, 'vocab.json')).readAsString())
                as Map,
          );
      final preprocessing =
          _alignmentCache?.preprocessing ??
          jsonDecode(
                await File(
                  _file(id, 'preprocessor_config.json'),
                ).readAsString(),
              )
              as Map;
      final session =
          _alignmentCache?.session ??
          openAsrOnnxSession(
            _file(id, 'model.int8.onnx'),
            math.min(threads, 2),
          );
      if (retainModels) {
        _alignmentCache ??= _AlignmentResources(
          id,
          session,
          vocabulary,
          preprocessing,
        );
      }
      try {
        for (final index in indexes) {
          checkCancelled();
          final cue = input[index];
          final pieces = segmentAsrSubtitles(
            [cue],
            const SubtitleSegmentationOptions(
              maxDurationMs: 6000,
              maxWidth: 160,
              splitOnPunctuation: false,
            ),
          );
          final alignedSpans = <SubtitleTimedSpan>[];
          var score = 0.0, cursor = 0, weighted = 0;
          var reason = '', hypothesis = '';
          for (final part in pieces) {
            checkCancelled();
            // Qwen emits complete VAD sentences without token times. The
            // prepared English CTC export can align a whole bounded sentence,
            // allowing real acoustic cuts without guessing times by length.
            final maxSeconds =
                textProcessingVersion == 2 &&
                    recognitionEngine == 'qwen3-asr' &&
                    lang == 'en'
                ? 16
                : 8;
            if (part.endTime - part.startTime > Duration(seconds: maxSeconds)) {
              reason = '片段超过 $maxSeconds 秒且没有安全的时间分界，保留原始时间轴';
              break;
            }
            final from = math.max(
              0,
              part.startTime.inMicroseconds * 16000 ~/ 1000000 - 1280,
            );
            final end = math.min(
              audio.length,
              part.endTime.inMicroseconds * 16000 ~/ 1000000 + 1280,
            );
            if (end - from < 400) {
              reason = '音频过短，保留原始时间轴';
              break;
            }
            final sample = Float32List.sublistView(audio, from, end);
            final values = preprocessing['do_normalize'] == false
                ? sample
                : normalizeAlignmentAudio(sample);
            final tensors = <String, OrtValue>{
              'input_values': OrtValueTensor.createTensorWithDataList(values, [
                1,
                values.length,
              ]),
              if (session.inputNames.contains('attention_mask'))
                'attention_mask': OrtValueTensor.createTensorWithDataList(
                  Int64List.fromList(List.filled(values.length, 1)),
                  [1, values.length],
                ),
            };
            final runOptions = OrtRunOptions();
            List<OrtValue?> outputs = [];
            CtcAlignment alignment;
            try {
              outputs = session.run(runOptions, tensors);
              final outputIndex = session.outputNames.indexWhere(
                (v) => v.contains('logits'),
              );
              final batch =
                  outputs[outputIndex < 0 ? 0 : outputIndex]?.value as List;
              final rows = (batch.single as List)
                  .map(
                    (row) => (row as List)
                        .map((v) => (v as num).toDouble())
                        .toList(),
                  )
                  .toList();
              alignment = alignCtcLogits(
                text: part.text,
                logits: rows,
                vocabulary: vocabulary,
                offset: Duration(
                  microseconds: (from * 1000000 / 16000).round(),
                ),
                audioDuration: Duration(
                  microseconds: ((end - from) * 1000000 / 16000).round(),
                ),
              );
            } finally {
              for (final tensor in tensors.values) {
                tensor.release();
              }
              for (final output in outputs) {
                output?.release();
              }
              runOptions.release();
            }
            hypothesis = '$hypothesis ${alignment.hypothesis}'.trim();
            if (!alignment.accepted ||
                asrTextAgreement(part.text, alignment.hypothesis) < .55) {
              reason = alignment.reason.isNotEmpty
                  ? alignment.reason
                  : '声学复核文字差异较大，保留原始时间轴';
              break;
            }
            final offset = cue.text.indexOf(part.text, cursor);
            if (offset < 0) {
              reason = '分段文字无法与原文对应';
              break;
            }
            cursor = offset + part.text.length;
            alignedSpans.addAll(
              alignment.spans.map(
                (s) => s.shifted(Duration.zero, textOffset: offset),
              ),
            );
            score += alignment.score * part.text.length;
            weighted += part.text.length;
            await Future<void>.delayed(Duration.zero);
          }
          final info = cue.asrInfo.copyWith(
            alignmentScore: weighted > 0 ? score / weighted : null,
            reviewReason: options.review ? reason : '',
            alternateText: options.review && reason.isNotEmpty
                ? hypothesis
                : '',
            notes: [
              ...cue.asrInfo.notes,
              if (reason.isEmpty) 'CTC 声学强制对齐' else '时间精校未替换原始时间轴',
            ],
          );
          if (reason.isEmpty && alignedSpans.isNotEmpty) {
            // Refinement is allowed inside the original audio window plus its
            // 80 ms context. Never clip aligned words back to old VAD times.
            result[index] = cue.copyWith(
              startTime: alignedSpans.first.startTime,
              endTime: alignedSpans.last.endTime,
              timedSpans: alignedSpans,
              asrInfo: info,
            );
          } else {
            result[index] = cue.copyWith(asrInfo: info);
          }
          done++;
          progress(
            'aligning',
            done / math.max(1, candidates),
            '正在精校时间轴 · $done / $candidates 段',
          );
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        if (!retainModels) session.release();
      }
    }
    return guardAsrAlignmentBoundaries(input, result, review: options.review);
  }

  List<SubtitleItem> _punctuationInput(List<SubtitleItem> input) =>
      naturalPunctuationContext
      ? joinAsrContinuations(
          input,
          SubtitleSegmentationOptions.natural,
        ).toList()
      : input;

  bool _needsPunctuation(SubtitleItem cue) =>
      canRestoreAsrPunctuation(
        cue,
        language,
        recognitionEngine,
        textProcessingVersion: textProcessingVersion,
      ) &&
      !RegExp(r'[。！？.!?]').hasMatch(cue.text);

  Future<List<SubtitleItem>> _punctuate(List<SubtitleItem> input) async {
    if (!directories.containsKey(AsrEnhancementOptions.punctuationId)) {
      return input;
    }
    // VAD pauses are not necessarily sentence ends. Restore context before a
    // short continuation can receive an artificial full stop.
    input = _punctuationInput(input);
    if (!input.any(_needsPunctuation)) {
      return input;
    }
    progress('punctuating', 0, '正在补充缺失标点');
    final model = _punctuationModel ??= sherpa.OfflinePunctuation(
      config: sherpa.OfflinePunctuationConfig(
        model: sherpa.OfflinePunctuationModelConfig(
          ctTransformer: _file(
            AsrEnhancementOptions.punctuationId,
            'model.int8.onnx',
          ),
          numThreads: math.min(threads, 2),
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    try {
      final result = <SubtitleItem>[];
      for (final cue in input) {
        checkCancelled();
        result.add(
          _needsPunctuation(cue)
              ? restoreAsrPunctuation(
                  cue,
                  model.addPunct(cue.text),
                  language: _alignmentLanguage(cue),
                )
              : cue,
        );
        progress(
          'punctuating',
          result.length / input.length,
          '正在整理标点 · ${result.length} / ${input.length} 段',
        );
        await Future<void>.delayed(Duration.zero);
      }
      return result;
    } finally {
      if (!retainModels) {
        model.free();
        _punctuationModel = null;
      }
    }
  }
}

class _AlignmentResources {
  _AlignmentResources(
    this.id,
    this.session,
    this.vocabulary,
    this.preprocessing,
  );
  final String id;
  final OrtSession session;
  final Map<String, int> vocabulary;
  final Map preprocessing;
  void close() => session.release();
}
