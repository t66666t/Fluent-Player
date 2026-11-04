import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_controller.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_panel.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_session.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';

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

class _HoldTransport extends AiChatTransport {
  final updates = StreamController<AiChatDelta>();
  final started = Completer<void>();

  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) {
    if (!started.isCompleted) started.complete();
    final bridge = StreamController<AiChatDelta>();
    final remove = cancellation.onCancel(() {
      if (!bridge.isClosed) unawaited(bridge.close());
    });
    updates.stream.listen(
      bridge.add,
      onError: bridge.addError,
      onDone: () {
        remove();
        if (!bridge.isClosed) unawaited(bridge.close());
      },
    );
    return bridge.stream;
  }
}

VideoItem _video() => VideoItem(
  id: 'session-video',
  path: 'test.mp4',
  title: '后台对话',
  durationMs: 1000,
  lastUpdated: 1,
);

Future<AiChatController> _controller({
  required Directory directory,
  required _Loader loader,
  required _HoldTransport transport,
}) async {
  final controller = AiChatController(
    video: _video(),
    contextLoader: loader,
    transport: transport,
    conversationStore: AiConversationStore(root: directory),
    initialSettings: const AiChatSettings(titlePrompt: ''),
  );
  await controller.initialize();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'trial preferences retain keys for active and inactive API profiles',
    () {
      final sessions = AiChatSessions();
      final controller = AiChatController(
        video: _video(),
        initialSettings: const AiChatSettings(),
      );
      controller.adoptSettings(
        const AiChatSettings(
          apiKey: 'active-secret',
          model: 'chosen-model',
          contextTokens: 64000,
          apiProfiles: {
            'deepseek': AiApiProfile(
              apiKey: 'active-secret',
              model: 'chosen-model',
            ),
            'openai': AiApiProfile(
              apiKey: 'inactive-secret',
              model: 'other-model',
            ),
          },
        ),
      );
      sessions.holdForTesting(controller);
      sessions.adoptPreferenceFields({
        'contextTokens': 32000,
        'temperature': .3,
      });
      expect(controller.settings.contextTokens, 32000);
      expect(controller.settings.model, 'chosen-model');
      expect(controller.settings.apiKey, 'active-secret');
      expect(
        controller.settings.apiProfiles['deepseek']!.apiKey,
        'active-secret',
      );
      expect(
        controller.settings.apiProfiles['openai']!.apiKey,
        'inactive-secret',
      );
      expect(controller.settings.apiProfiles['openai']!.model, 'other-model');
      sessions.shutdown();
    },
  );

  test('one video keeps a single session until shutdown', () {
    final sessions = AiChatSessions();
    final video = _video();
    final first = sessions.retain(
      video: video,
      createLoader: AiVideoContextLoader.new,
    );
    final again = sessions.retain(
      video: video,
      createLoader: AiVideoContextLoader.new,
    );
    expect(identical(first.controller, again.controller), isTrue);
    expect(identical(first.input, again.input), isTrue);
    sessions.shutdown();
    sessions.shutdown();
  });

  test('shutdown stops a reply that no longer has a view', () async {
    final directory = await Directory.systemTemp.createTemp('ai_session_stop_');
    final transport = _HoldTransport();
    final sessions = AiChatSessions();
    final controller = await _controller(
      directory: directory,
      loader: _Loader(),
      transport: transport,
    );
    sessions.holdForTesting(controller);
    final pending = controller.send('还在生成');
    await transport.started.future;
    sessions.shutdown();
    await pending;
    expect(controller.active!.messages.last.status, 'cancelled');
    if (!transport.updates.isClosed) await transport.updates.close();
    await directory.delete(recursive: true);
  });

  testWidgets('closing the panel does not cancel the reply', (tester) async {
    final directory = Directory.systemTemp.createTempSync('ai_session_view_');
    final transport = _HoldTransport();
    final sessions = AiChatSessions();
    late AiChatController controller;
    await tester.runAsync(() async {
      controller = await _controller(
        directory: directory,
        loader: _Loader(),
        transport: transport,
      );
    });
    sessions.holdForTesting(controller);
    addTearDown(() async {
      if (!transport.updates.isClosed) await transport.updates.close();
      sessions.shutdown();
      directory.deleteSync(recursive: true);
    });

    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.send('继续讲');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(controller.busy, isTrue);

    Widget page() => MaterialApp(
      home: Scaffold(
        body: AiChatPanel(videoItem: _video(), sessions: sessions),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pump();
    expect(find.text('继续讲'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(controller.busy, isTrue);

    await tester.runAsync(() async {
      transport.updates.add(
        const AiChatDelta(content: '后台写完了', finishReason: 'stop'),
      );
      await transport.updates.close();
      await pending;
    });
    expect(controller.active!.messages.last.status, 'complete');
    expect(controller.active!.messages.last.content, '后台写完了');

    await tester.pumpWidget(page());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('后台写完了'), findsOneWidget);
  });

  testWidgets('desktop entry and a new conversation focus the composer', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = Directory.systemTemp.createTempSync('ai_session_focus_');
    final transport = _HoldTransport();
    late AiChatController controller;
    await tester.runAsync(() async {
      controller = await _controller(
        directory: directory,
        loader: _Loader(),
        transport: transport,
      );
    });
    addTearDown(() async {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });

    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiChatPanel(videoItem: _video(), controller: controller),
        ),
      ),
    );
    await tester.pump();

    FocusNode composer() => tester
        .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
        .focusNode!;
    expect(composer().hasFocus, isTrue);

    await tester.tap(find.text('总结这个视频的核心内容和结论'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .controller!
          .text,
      '总结这个视频的核心内容和结论',
    );
    expect(composer().hasFocus, isTrue);

    composer().unfocus();
    await tester.pump();
    expect(composer().hasFocus, isFalse);

    final before = controller.conversations.length;
    await tester.runAsync(() => controller.createConversation());
    await tester.pump();
    await tester.pump();
    expect(controller.conversations.length, before + 1);
    expect(composer().hasFocus, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone does not open the keyboard just by showing the chat', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = Directory.systemTemp.createTempSync('ai_session_phone_');
    final transport = _HoldTransport();
    late AiChatController controller;
    await tester.runAsync(() async {
      controller = await _controller(
        directory: directory,
        loader: _Loader(),
        transport: transport,
      );
    });
    addTearDown(() async {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiChatPanel(videoItem: _video(), controller: controller),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
