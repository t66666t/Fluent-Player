import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose_manager.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_preview_controller.dart';
import 'package:video_player_app/widgets/video_compose_panel.dart';

import 'support/compose_queue_fakes.dart';

class _Manager extends ChangeNotifier implements VideoComposeManager {
  @override
  Future<void> get ready async {}
  @override
  MediaMaterializationProgress? materializationProgressForTask(String taskId) =>
      null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  VideoComposeTaskState? task;
  @override
  Future<String?> getSourceResolutionLabel(String path) async => '1920×1080';
  @override
  VideoComposeTaskState? latestTaskForVideo(String id) =>
      task?.request.videoId == id ? task : null;
  @override
  VideoComposeTaskState? get runningTask => task;
  void tick(double progress) {
    task = task!.copyWith(progress: progress);
    notifyListeners();
  }
}

void main() {
  final settings = SettingsService();
  late _Manager manager;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    manager = _Manager();
    await manager.ready;
  });
  tearDown(() {
    manager.dispose();
    settings.resetForTest();
  });
  final previews = <VideoComposePreviewConfig>[];
  Future<void> show(
    WidgetTester tester, {
    String id = 'video',
    Map<String, String> options = const {},
    Future<Map<String, String>> Function()? prepare,
    bool active = true,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<VideoComposeManager>.value(value: manager),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: active,
              child: Offstage(
                offstage: !active,
                child: Center(
                  child: SizedBox(
                    width: 460,
                    child: VideoComposePanel(
                      key: const ValueKey('compose'),
                      videoItem: VideoItem(
                        id: id,
                        path: '$id.mp4',
                        title: id,
                        durationMs: 120000,
                        lastUpdated: 0,
                      ),
                      currentSelectedPaths: const [],
                      availableSubtitleMap: options,
                      prepareSubtitleOptions: prepare,
                      onPreviewChanged: previews.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final closing in [false, true]) {
    testWidgets(
      'a retained hidden form releases its root popup: closing=$closing',
      (tester) async {
        const options = {'a.srt': '字幕 A', 'b.srt': '字幕 B'};
        await show(tester, options: options);
        final form = tester.state(find.byType(VideoComposePanel));
        final primary = find.byKey(const ValueKey('primary_dropdown'));
        await tester.ensureVisible(primary);
        await tester.tap(primary);
        await tester.pumpAndSettle();
        expect(find.text('字幕 B'), findsOneWidget);
        if (closing) {
          await tester.tap(find.text('字幕 B'));
          await tester.pump();
        }
        await show(tester, options: options, active: false);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('主字幕渲染'), findsNothing);
        expect(
          find.text('字幕 B'),
          findsNothing,
          reason: 'A root overlay must not outlive its hidden owner.',
        );
        await show(tester, options: options);
        expect(tester.state(find.byType(VideoComposePanel)), same(form));
        await tester.ensureVisible(primary);
        await tester.tap(primary);
        await tester.pumpAndSettle();
        expect(find.text(closing ? '字幕 A' : '字幕 B').last, findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.all(),
    );
  }

  testWidgets(
    'navigation releases the popup and leaves the retained form usable',
    (tester) async {
      const options = {'a.srt': '字幕 A', 'b.srt': '字幕 B'};
      await show(tester, options: options);
      final primary = find.byKey(const ValueKey('primary_dropdown'));
      await tester.ensureVisible(primary);
      await tester.tap(primary);
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      var nextPageTaps = 0;
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: TextButton(
                onPressed: () => nextPageTaps++,
                child: const Text('Next page action'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('字幕 B'), findsNothing);
      await tester.tap(find.text('Next page action'));
      expect(nextPageTaps, 1);
      navigator.pop();
      await tester.pumpAndSettle();
      await tester.tap(primary);
      await tester.pumpAndSettle();
      await tester.tap(find.text('字幕 B').last);
      await tester.pumpAndSettle();
      expect(previews.last.primarySubtitlePath, 'b.srt');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('first frame is interactive while only subtitle actions wait', (
    tester,
  ) async {
    previews.clear();
    final ready = Completer<Map<String, String>>();
    await show(tester, prepare: () => ready.future);
    expect(find.text('视频合成'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compose-subtitle-preparation')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ElevatedButton>(find.byKey(const ValueKey('compose-enqueue')))
          .onPressed,
      isNull,
    );
    ready.complete({'embedded.srt': '内嵌字幕 1'});
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compose-subtitle-preparation')),
      findsNothing,
    );
    expect(previews.last.primarySubtitlePath, 'embedded.srt');
    expect(
      tester
          .widget<ElevatedButton>(find.byKey(const ValueKey('compose-enqueue')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('late metadata preserves an edited subtitle choice', (
    tester,
  ) async {
    previews.clear();
    final ready = Completer<Map<String, String>>();
    await show(
      tester,
      options: {'a.srt': '字幕 A', 'b.srt': '字幕 B'},
      prepare: () => ready.future,
    );
    final primary = find.byKey(const ValueKey('primary_dropdown'));
    await tester.ensureVisible(primary);
    await tester.tap(primary);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('字幕 B').last);
    await tester.pump(const Duration(milliseconds: 120));
    ready.complete({'a.srt': '字幕 A', 'b.srt': '字幕 B', 'new.srt': '新增字幕'});
    await tester.pump();
    await tester.pump();
    expect(previews.last.primarySubtitlePath, 'b.srt');
    expect(tester.takeException(), isNull);
  });

  testWidgets('old-media results cannot replace the new media options', (
    tester,
  ) async {
    previews.clear();
    final first = Completer<Map<String, String>>();
    final second = Completer<Map<String, String>>();
    await show(tester, prepare: () => first.future);
    await show(tester, id: 'second', prepare: () => second.future);
    first.complete({'old.srt': '旧字幕'});
    await tester.pump();
    expect(
      find.byKey(const ValueKey('compose-subtitle-preparation')),
      findsOneWidget,
    );
    second.complete({'second.srt': '新字幕'});
    await tester.pump();
    await tester.pump();
    expect(previews.last.primarySubtitlePath, 'second.srt');
    expect(find.text('旧字幕'), findsNothing);
  });

  testWidgets('preparation failures can retry without remounting the form', (
    tester,
  ) async {
    var attempts = 0;
    await show(
      tester,
      prepare: () async {
        if (++attempts == 1) throw StateError('fixture preparation failed');
        return {'ready.srt': '字幕'};
      },
    );
    await tester.pump();
    final state = tester.state(find.byType(VideoComposePanel));
    final retry = find.byKey(const ValueKey('compose-subtitle-retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(tester.state(find.byType(VideoComposePanel)), same(state));
    expect(retry, findsNothing);
  });

  testWidgets('progress ticks retain the subtitle selectors and form', (
    tester,
  ) async {
    manager.task = composeRecord(
      'video',
    ).copyWith(stage: VideoComposeStage.rendering, progress: .1);
    await show(tester, options: {'a.srt': '字幕 A'});
    final primary = find.byKey(const ValueKey('primary_dropdown'));
    final original = tester.widget(primary);
    for (var i = 1; i <= 120; i++) {
      manager.tick(i / 120);
      await tester.pump(const Duration(microseconds: 8333));
      expect(tester.widget(primary), same(original));
    }
    expect(tester.takeException(), isNull);
  });
}
