import 'dart:math' as math;
import 'package:characters/characters.dart';
import '../../models/subtitle_model.dart';
import '../../models/subtitle_asr_info.dart';
import 'cloud_asr_types.dart';

class _Word {
  const _Word(this.text, this.start, this.end, {this.speaker, this.language});
  final String text;
  final Duration? start, end;
  final String? speaker, language;
}

Map<String, dynamic> cloudObject(dynamic value) {
  if (value is! Map) throw const CloudAsrException('云端返回了无法解析的数据结构');
  return Map<String, dynamic>.from(value);
}

Iterable<Map<String, dynamic>> _objects(
  dynamic value, {
  bool required = false,
}) sync* {
  if (value == null && !required) return;
  if (value is! List) throw const CloudAsrException('服务返回的字幕结构已改变，原结果已保留');
  for (final item in value) {
    if (item is! Map) throw const CloudAsrException('服务返回的字幕结构已改变，原结果已保留');
    yield Map<String, dynamic>.from(item);
  }
}

Duration _time(
  dynamic value, {
  bool milliseconds = false,
  bool google = false,
}) {
  double? number;
  if (google) {
    if (value is String) {
      final match = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(value);
      if (match != null) number = double.tryParse(match[1]!);
    }
  } else if (value is num) {
    number = value.toDouble();
  }
  if (number == null || !number.isFinite || number < 0) {
    throw const CloudAsrException('接口返回了无效时间轴，请检查模型的字幕支持');
  }
  return Duration(
    microseconds: (number * (milliseconds ? 1000 : 1000000)).round(),
  );
}

CloudAsrResult parseCloudAsrResult(
  CloudAsrProvider provider,
  dynamic payload, {
  String requestedModel = '',
}) {
  final data = cloudObject(payload);
  final words = <_Word>[];
  var model = requestedModel, verbatimSpacing = false;
  final languages = <String>{};
  var hasText = (data['text']?.toString().trim().isNotEmpty ?? false);
  switch (provider) {
    case CloudAsrProvider.elevenlabs:
      verbatimSpacing = true;
      for (final item in _objects(data['words'], required: true)) {
        final type = item['type'];
        if (type == 'audio_event') continue;
        final text = item['text']?.toString() ?? '';
        if (text.isEmpty) continue;
        if (type == 'spacing' || text.trim().isEmpty) {
          words.add(_Word(text, null, null));
          continue;
        }
        // Character arrays have explicit timings; never subdivide word timing.
        final characters = _objects(item['characters']).toList();
        for (final unit in characters.isEmpty ? [item] : characters) {
          words.add(
            _Word(
              unit['text']?.toString() ?? unit['character']?.toString() ?? '',
              _time(unit['start']),
              _time(unit['end']),
              speaker: item['speaker_id']?.toString(),
            ),
          );
        }
      }
      if (data['language_code'] is String) languages.add(data['language_code']);
    case CloudAsrProvider.soniox:
      verbatimSpacing = true;
      for (final item in _objects(data['tokens'], required: true)) {
        if (item['translation_status'] == 'translation') continue;
        final text = item['text']?.toString() ?? '';
        if (text.isEmpty || RegExp(r'^<[^>]+>$').hasMatch(text)) continue;
        if (text.trim().isEmpty) {
          words.add(_Word(text, null, null));
          continue;
        }
        hasText = true;
        final lang = item['language']?.toString();
        if (lang != null) languages.add(lang);
        words.add(
          _Word(
            text,
            _time(item['start_ms'], milliseconds: true),
            _time(item['end_ms'], milliseconds: true),
            speaker: item['speaker']?.toString(),
            language: lang,
          ),
        );
      }
    case CloudAsrProvider.assemblyai:
      model = data['speech_model_used']?.toString() ?? model;
      for (final item in _objects(data['words'], required: true)) {
        words.add(
          _Word(
            item['text']?.toString() ?? '',
            _time(item['start'], milliseconds: true),
            _time(item['end'], milliseconds: true),
            speaker: item['speaker']?.toString(),
          ),
        );
      }
      if (data['language_code'] is String) languages.add(data['language_code']);
    case CloudAsrProvider.deepgram:
      final results = cloudObject(data['results']);
      final channels = _objects(results['channels'], required: true).toList();
      if (channels.isEmpty) throw const CloudAsrException('Deepgram 未返回音频通道');
      for (final channel in channels) {
        final alternative = _objects(
          channel['alternatives'],
          required: true,
        ).firstOrNull;
        if (alternative == null) {
          throw const CloudAsrException('Deepgram 未返回转录结果');
        }
        hasText =
            hasText ||
            (alternative['transcript']?.toString().trim().isNotEmpty ?? false);
        if (channel['detected_language'] is String) {
          languages.add(channel['detected_language']);
        }
        for (final item in _objects(alternative['words'], required: true)) {
          words.add(
            _Word(
              (item['punctuated_word'] ?? item['word'])?.toString() ?? '',
              _time(item['start']),
              _time(item['end']),
              speaker: item['speaker']?.toString(),
              language: item['language']?.toString(),
            ),
          );
        }
      }
      final metadata = data['metadata'];
      if (metadata is Map && metadata['model_info'] is Map) {
        final info = _objects(
          (metadata['model_info'] as Map).values.toList(),
        ).firstOrNull;
        if (info != null) {
          model = '${info['name'] ?? model}:${info['version'] ?? ''}';
        }
      }
    case CloudAsrProvider.gemini:
      if (data['status'] != 'completed') {
        throw const CloudAsrException('Google 未返回已完成的转录结果，原响应已保留');
      }
      var structured = false;
      for (final step in _objects(data['steps'], required: true)) {
        for (final content in _objects(step['content'])) {
          structured = structured || content['annotations'] is List;
          hasText =
              hasText ||
              (content['text']?.toString().trim().isNotEmpty ?? false);
          for (final item in _objects(content['annotations'])) {
            if (item['type'] != 'word_info') continue;
            final lang = item['language_code']?.toString();
            if (lang != null) languages.add(lang);
            words.add(
              _Word(
                item['text']?.toString() ?? '',
                _time(item['start_offset'], google: true),
                _time(item['end_offset'], google: true),
                speaker: item['speaker']?.toString(),
              ),
            );
          }
        }
      }
      if (!structured && !hasText) {
        throw const CloudAsrException('Google 未返回字幕时间注释，原结果已保留');
      }
  }
  if (provider == CloudAsrProvider.soniox) {
    final joined = <_Word>[];
    for (final word in words) {
      final previous = joined.lastOrNull;
      if (previous?.end != null &&
          word.start != null &&
          previous!.speaker == word.speaker &&
          previous.language == word.language &&
          !RegExp(r'\s$').hasMatch(previous.text) &&
          !RegExp(r'^\s').hasMatch(word.text) &&
          !_cjkBoundary(previous.text, word.text) &&
          word.start! - previous.end! < const Duration(milliseconds: 300)) {
        joined[joined.length - 1] = _Word(
          previous.text + word.text,
          previous.start,
          word.end! > previous.end! ? word.end : previous.end,
          speaker: word.speaker,
          language: word.language,
        );
      } else {
        joined.add(word);
      }
    }
    words
      ..clear()
      ..addAll(joined);
  }
  final timed = words.where((w) => w.text.trim().isNotEmpty).toList();
  for (final word in timed) {
    if (word.language?.isNotEmpty == true) {
      languages.add(word.language!);
    }
    if (word.start == null || word.end == null || word.end! <= word.start!) {
      throw const CloudAsrException('接口缺少有效词级时间轴，未生成字幕');
    }
  }
  if (timed.isEmpty && hasText) {
    throw const CloudAsrException('模型仅返回文字，没有字幕时间轴；请更换模型或检查时间戳选项');
  }
  final cues = <SubtitleItem>[];
  var text = '', spans = <SubtitleTimedSpan>[];
  Duration? start, end;
  String? speaker;
  void flush() {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty && start != null && end != null) {
      final leading = text.length - text.trimLeft().length;
      final boundaries = <int>{0};
      var offset = 0;
      for (final character in trimmed.characters) {
        offset += character.length;
        boundaries.add(offset);
      }
      final valid = <SubtitleTimedSpan>[];
      for (final span in spans) {
        final from = math.max(0, span.textStart - leading);
        final to = math.min(trimmed.length, span.textEnd - leading);
        if (from >= to) continue;
        // Merge subword boundaries inside one Unicode grapheme.
        if (!boundaries.contains(from) && valid.isNotEmpty) {
          final previous = valid.removeLast();
          valid.add(
            SubtitleTimedSpan(
              textStart: previous.textStart,
              textEnd: to,
              startTime: previous.startTime,
              endTime: span.endTime,
              agentId: previous.agentId,
            ),
          );
        } else {
          valid.add(
            SubtitleTimedSpan(
              textStart: from,
              textEnd: to,
              startTime: span.startTime,
              endTime: span.endTime,
              agentId: span.agentId,
            ),
          );
        }
      }
      cues.add(
        SubtitleItem(
          index: cues.length + 1,
          startTime: start!,
          endTime: end!,
          text: trimmed,
          asrInfo: SubtitleAsrInfo(
            speaker: speaker ?? '',
            backend: provider.name,
            language: languages.length == 1 ? languages.single : '',
          ),
          timedSpans: valid
              .where(
                (s) =>
                    boundaries.contains(s.textStart) &&
                    boundaries.contains(s.textEnd),
              )
              .toList(),
        ),
      );
    }
    text = '';
    spans = [];
    start = null;
    end = null;
    speaker = null;
  }

  for (final word in words) {
    if (word.text.trim().isEmpty) {
      if (text.isNotEmpty) text += word.text;
      continue;
    }
    if (start != null &&
        (word.start! - start! > const Duration(seconds: 7) ||
            word.start! - end! > const Duration(milliseconds: 900) ||
            text.length + word.text.length > 64 ||
            word.speaker != speaker)) {
      flush();
    }
    if (!verbatimSpacing &&
        text.isNotEmpty &&
        !text.endsWith(' ') &&
        !_cjkBoundary(text, word.text)) {
      text += ' ';
    }
    final from = text.length;
    text += word.text;
    start ??= word.start;
    if (end == null || word.end! > end!) end = word.end;
    speaker = word.speaker;
    spans.add(
      SubtitleTimedSpan(
        textStart: from,
        textEnd: text.length,
        startTime: word.start!,
        endTime: word.end!,
        agentId: word.speaker,
      ),
    );
    if (RegExp(r'[。！？!?][”’"\x27]*\s*$').hasMatch(word.text) ||
        RegExp(r'\.\s*$').hasMatch(word.text) && text.length > 25) {
      flush();
    }
  }
  flush();
  return CloudAsrResult(cues, model: model, languages: languages.toList());
}

bool _cjkBoundary(String before, String after) =>
    RegExp(r'[\u2e80-\u9fff\uac00-\ud7af\u3040-\u30ff]$').hasMatch(before) ||
    RegExp(
      r'^[\u2e80-\u9fff\uac00-\ud7af\u3040-\u30ff，。！？、；：,.!?]',
    ).hasMatch(after);
