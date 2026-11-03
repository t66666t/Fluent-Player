import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_copy.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';

class _Store extends AiConversationStore {
  @override
  Future<List<AiConversation>> load(String videoId) async => const [];

  @override
  Future<void> save(AiConversation conversation) async {}

  @override
  Future<void> delete(String videoId, String id) async {}
}

class _Loader extends AiVideoContextLoader {
  @override
  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const [],
    List<SubtitleItem> secondarySubtitles = const [],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async => AiVideoContext(videoId: video.id, title: video.title);
}

VideoItem _item({
  required String id,
  required String title,
  MediaType type = MediaType.video,
  bool podcast = false,
}) => VideoItem(
  id: id,
  path: '$id.${type == MediaType.audio ? 'mp3' : 'mp4'}',
  title: title,
  durationMs: 60000,
  lastUpdated: 1,
  type: type,
  sourceRef: podcast
      ? MediaSourceRef(
          value: 'podcast:$id',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: id,
            feedUrl: 'https://example.com/feed.xml',
            mediaUrl: 'https://example.com/$id',
          ),
        )
      : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('noun follows podcast, then audio, then video', () {
    expect(AiChatMediaCopy.of(_item(id: 'v', title: '课')).noun, '视频');
    expect(
      AiChatMediaCopy.of(
        _item(id: 'a', title: '歌', type: MediaType.audio),
      ).noun,
      '音频',
    );
    expect(
      AiChatMediaCopy.of(_item(id: 'p', title: '节目', podcast: true)).noun,
      '播客',
    );
    expect(
      AiChatMediaCopy.of(
        _item(id: 'vp', title: '画面节目', type: MediaType.video, podcast: true),
      ).noun,
      '播客',
    );
  });

  testWidgets('empty chat copy matches the open media', (tester) async {
    debugAiChatDesktopAutofocus = false;
    addTearDown(() => debugAiChatDesktopAutofocus = true);
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final cases = [
      _item(id: 'video', title: '一节课'),
      _item(id: 'audio', title: '一首歌', type: MediaType.audio),
      _item(id: 'show', title: '一期节目', podcast: true),
      _item(id: 'picture-show', title: '一期画面节目', podcast: true),
    ];

    for (final item in cases) {
      final copy = AiChatMediaCopy.of(item);
      final controller = AiChatController(
        video: item,
        contextLoader: _Loader(),
        conversationStore: _Store(),
        initialSettings: const AiChatSettings(titlePrompt: ''),
      );
      addTearDown(controller.dispose);
      await tester.runAsync(controller.initialize);
      expect(
        controller.exportMarkdown(),
        contains('${copy.exportHeading}${item.title}'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPanel(videoItem: item, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(copy.askTitle), findsOneWidget);
      expect(find.text(copy.hint), findsOneWidget);
      expect(find.text(copy.summarize), findsOneWidget);
      expect(find.text(copy.hardConcept), findsOneWidget);
      expect(find.text(copy.completeNotes), findsOneWidget);
      await tester.ensureVisible(find.text(copy.completeNotes));
      await tester.tap(find.text(copy.completeNotes));
      await tester.pumpAndSettle();
      final draft = tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .controller!;
      expect(draft.text, copy.completeNotesPrompt);
      expect(draft.selection.baseOffset, copy.completeNotesPrompt.length);
      expect(controller.active?.messages ?? const [], isEmpty);
      expect(find.textContaining('${copy.sources} · '), findsOneWidget);
      for (final other in [
        '视频',
        '音频',
        '播客',
      ].where((noun) => noun != copy.noun)) {
        expect(find.text('询问这个$other…'), findsNothing);
        expect(find.text('询问$other内容'), findsNothing);
      }

      await tester.tap(find.byKey(const ValueKey('ai-chat-context')));
      await tester.pumpAndSettle();
      expect(find.text(copy.sources), findsOneWidget);
      expect(find.text(copy.noTranscript), findsOneWidget);
      expect(find.text(copy.info), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
