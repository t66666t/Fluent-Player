import 'dart:convert';

import '../../models/video_item.dart';
import 'ai_chat_copy.dart';
import 'ai_chat_models.dart';
import 'ai_video_context.dart';

enum AiConversationExportFormat {
  markdown('Markdown', 'md'),
  text('纯文本', 'txt'),
  json('JSON', 'json');

  const AiConversationExportFormat(this.label, this.extension);
  final String label;
  final String extension;
}

/// A portable, user-facing document. Never serializes connection settings,
/// local paths, drafts or raw request/response envelopes from the chat store.
class AiConversationExport {
  AiConversationExport({
    required this.video,
    required Iterable<AiConversation> conversations,
    this.videoContext,
    this.includeTranscripts = false,
    this.includeReasoning = false,
  }) : conversations = List.unmodifiable(
         conversations.where((record) => record.videoId == video.id),
       );

  final VideoItem video;
  final List<AiConversation> conversations;
  final AiVideoContext? videoContext;
  final bool includeTranscripts;
  final bool includeReasoning;

  Set<String> _trackIds(AiConversation conversation) =>
      conversation.selectedTrackIds ??
      (videoContext?.videoId != video.id
          ? <String>{}
          : recommendAiSubtitleTracks(videoContext!));

  List<AiSubtitleTrack> get tracks {
    if (!includeTranscripts || videoContext?.videoId != video.id) return [];
    final ids = conversations.expand(_trackIds).toSet();
    return videoContext!.tracks
        .where(
          (track) => ids.contains(track.id) || track.aliases.any(ids.contains),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> get data {
    final context = videoContext?.videoId == video.id ? videoContext : null;
    final metadata = context?.metadata ?? const <String, dynamic>{};
    final selectedIds = conversations.expand(_trackIds).toSet();
    final foundIds = tracks
        .expand((track) => [track.id, ...track.aliases])
        .toSet();
    final source = _publicSource(metadata['source']);
    return {
      'format': 'fluent-player-conversation',
      'version': 1,
      'media': {
        'id': video.id,
        'title': video.title,
        'mediaType': video.type.name,
        'durationMs': video.durationMs,
        'source': ?source,
        'chapters': [
          for (final chapter in video.chapters)
            {
              'title': chapter.title,
              'startMs': chapter.startMs,
              'endMs': chapter.endMs,
            },
        ],
      },
      'conversations': [
        for (final record in conversations)
          {
            'id': record.id,
            'title': record.title,
            'createdAt': record.createdAt.toIso8601String(),
            'updatedAt': record.updatedAt.toIso8601String(),
            'parentConversationId': record.parentConversationId,
            'parentMessageId': record.parentMessageId,
            'selectedTrackIds': _trackIds(record).toList(),
            'messages': [
              for (final message in record.messages)
                {
                  'id': message.id,
                  'role': message.role,
                  'content': message.content,
                  'createdAt': message.createdAt.toIso8601String(),
                  'status': message.status,
                  if (message.error != null) 'error': message.error,
                  if (includeReasoning && message.reasoning.isNotEmpty)
                    'reasoning': message.reasoning,
                },
            ],
          },
      ],
      if (includeTranscripts)
        'transcripts': {
          'note': '以下为导出时当前可用的所选文稿，历史每轮使用的资料可能不同；未对缺失段落作推测。',
          'missingTrackIds': selectedIds.difference(foundIds).toList(),
          'tracks': [
            for (final track in tracks)
              {
                'id': track.id,
                'label': track.label,
                'source': track.sourceDescription,
                if (track.error != null) 'error': track.error,
                'cueCount': track.cues.length,
                'cues': [
                  for (final cue in track.cues)
                    {
                      'startMs': cue.startTime.inMilliseconds,
                      'endMs': cue.endTime.inMilliseconds,
                      'text': cue.text,
                    },
                ],
              },
          ],
        },
    };
  }

  String render([
    AiConversationExportFormat format = AiConversationExportFormat.markdown,
  ]) {
    if (format == AiConversationExportFormat.json) {
      return const JsonEncoder.withIndent('  ').convert(data);
    }
    final markdown = format == AiConversationExportFormat.markdown;
    final output = StringBuffer();
    void heading(String value, int level) =>
        output.writeln('${markdown ? '${'#' * level} ' : ''}$value\n');
    heading(
      conversations.length == 1
          ? conversations.first.title
          : '${video.title} · 全部对话',
      1,
    );
    output.writeln(
      '${AiChatMediaCopy.of(video).exportHeading}${video.title}\n',
    );
    output.writeln('时长：${_timestamp(video.durationMs)}\n');
    final source = (data['media'] as Map)['source'];
    if (source != null) output.writeln('来源：$source\n');
    for (final record in conversations) {
      if (conversations.length > 1) heading(record.title, 2);
      output.writeln('对话 ID：${record.id}\n');
      if (record.parentConversationId != null) {
        output.writeln(
          '分支来源：${record.parentConversationId} · 消息 ${record.parentMessageId ?? '未记录'}\n',
        );
      }
      for (final message in record.messages) {
        final role = switch (message.role) {
          'user' => '你',
          'assistant' => 'AI',
          _ => message.role,
        };
        heading(role, conversations.length > 1 ? 3 : 2);
        output.writeln('${message.content}\n');
        if (includeReasoning && message.reasoning.isNotEmpty) {
          heading('思考内容', conversations.length > 1 ? 4 : 3);
          output.writeln('${message.reasoning}\n');
        }
        if (message.status != 'complete') {
          output.writeln('状态：${message.status}\n');
        }
        if (message.error != null) output.writeln('错误：${message.error}\n');
      }
    }
    if (includeTranscripts) {
      heading('随附文稿', 2);
      final transcriptData = data['transcripts'] as Map;
      output.writeln('${transcriptData['note']}\n');
      final missing = transcriptData['missingTrackIds'] as List;
      if (missing.isNotEmpty) output.writeln('未能读取的资料：${missing.join('、')}\n');
      if (tracks.isEmpty) output.writeln('没有可附加的所选文稿。\n');
      for (final track in tracks) {
        heading(track.label, 3);
        output.writeln(
          '来源：${track.sourceDescription} · ${track.cues.length} 段\n',
        );
        if (track.error != null) output.writeln('资料提示：${track.error}\n');
        for (final cue in track.cues) {
          output.writeln(
            '[${_timestamp(cue.startTime.inMilliseconds)}–${_timestamp(cue.endTime.inMilliseconds)}] ${cue.text}\n',
          );
        }
      }
    }
    return output.toString();
  }

  String fileName(AiConversationExportFormat format) {
    final title = conversations.length == 1
        ? conversations.first.title
        : '${video.title} 全部对话';
    final clean = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .trim();
    final stem = String.fromCharCodes(
      clean.runes.take(80),
    ).replaceAll(RegExp(r'[. ]+$'), '');
    return '对话-${stem.isEmpty ? '导出' : stem}.${format.extension}';
  }

  static String? _publicSource(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  static String _timestamp(int milliseconds) {
    final value = milliseconds < 0 ? 0 : milliseconds;
    final hours = value ~/ 3600000;
    final minutes = (value ~/ 60000 % 60).toString().padLeft(2, '0');
    final seconds = (value ~/ 1000 % 60).toString().padLeft(2, '0');
    final fraction = (value % 1000).toString().padLeft(3, '0');
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds.$fraction';
  }
}
