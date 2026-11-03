import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../utils/app_data_paths.dart';
import 'ai_chat_settings.dart';
import 'ai_chat_transport.dart';
import 'ai_video_context.dart';
import 'ai_transcript_pipeline.dart';

class AiPreparedTranscript {
  const AiPreparedTranscript(this.text, this.segments, this.reused, this.usage);
  final String text;
  final int segments, reused;
  final Map<String, dynamic> usage;
}

/// Every selected text cue participates, including oversized single cues.
/// Failed/cancelled/truncated generations are never cached as complete work.
class AiTranscriptPreparation {
  AiTranscriptPreparation({
    required this.transport,
    this.root,
    this.maxConcurrency = 2,
  });
  final AiChatTransport transport;
  final Directory? root;
  final int maxConcurrency;
  final Map<String, String> _memory = {};
  static bool isSummaryTask(String question) =>
      RegExp(
        r'总结|概括|概述|梗概|summary|summari[sz]e|overview',
        caseSensitive: false,
      ).hasMatch(question) &&
      !RegExp(
        r'深[度入]|推导|证明|计算|批判|评估|推理|分析原因|prove|calculate|critique|in.depth',
        caseSensitive: false,
      ).hasMatch(question);
  static bool exhaustive(String question) => RegExp(
    r'所有|全部|逐[一条段]|完整[列整]|有哪些|列出|有没有|是否[提讲说]|all\b|every\b|exhaustive|ever mention',
    caseSensitive: false,
  ).hasMatch(question);
  static bool needsWholeVideo(String question) {
    if (exhaustive(question)) return true;
    final local = RegExp(
      r'当前|这[一段里]|附近|\d+:\d+|current|this part',
      caseSensitive: false,
    ).hasMatch(question);
    final whole = RegExp(
      r'全片|全视频|整个|whole video',
      caseSensitive: false,
    ).hasMatch(question);
    return (!local || whole) &&
        RegExp(
          r'总结|概括|概述|全片|全视频|整个|主要内容|梗概|summary|summari[sz]e|overview|whole video',
          caseSensitive: false,
        ).hasMatch(question);
  }

  String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
  Future<Directory> _directory() async => Directory(
    p.join(
      (root ?? await resolveAppDataDirectory()).path,
      'ai_transcript_cache',
    ),
  );

  Future<String?> _read(String key) async {
    if (_memory.containsKey(key)) return _memory[key];
    try {
      final data = jsonDecode(
        await File(
          p.join((await _directory()).path, '$key.json'),
        ).readAsString(),
      );
      if (data is Map &&
          data['key'] == key &&
          data['text'] is String &&
          (data['text'] as String).isNotEmpty &&
          _hash(data['text']) == data['checksum']) {
        return _memory[key] = data['text'];
      }
    } catch (_) {
      /* A missing/damaged cache is regenerated, not trusted. */
    }
    return null;
  }

  Future<void> _write(String key, String text) async {
    _memory[key] = text;
    try {
      final dir = await _directory();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, '$key.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'key': key, 'text': text, 'checksum': _hash(text)}),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {
      /* Disk failure must not invalidate an already completed read. */
    }
  }

  Future<AiPreparedTranscript> prepare({
    required AiVideoContext video,
    required Set<String> selectedTrackIds,
    required AiChatSettings settings,
    required String question,
    required int targetTokens,
    required AiChatCancellation cancellation,
    required void Function(int done, int total, int reused) onProgress,
    void Function(Map<String, dynamic> usage)? onUsage,
    void Function(String status)? onRecovery,
    bool? exhaustiveTask,
  }) async {
    final result =
        await AiTranscriptPipeline(
          transport: transport,
          readRecord: _read,
          writeRecord: _write,
          maxConcurrency: maxConcurrency,
        ).prepare(
          video: video,
          selectedTrackIds: selectedTrackIds,
          settings: settings,
          question: question,
          targetTokens: targetTokens,
          exhaustive: exhaustiveTask ?? exhaustive(question),
          cancellation: cancellation,
          onProgress: onProgress,
          onUsage: onUsage,
          onRecovery: onRecovery,
        );
    return AiPreparedTranscript(
      result.text,
      result.segments,
      result.reused,
      result.usage,
    );
  }
}
