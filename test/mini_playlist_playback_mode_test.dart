import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_actions.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/playback_queue_sort_controls.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

import 'test_artifacts.dart';

PlaylistManager _queue([int count = 3]) =>
    PlaylistManager(queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true))
      ..setPlaylist([
        for (var i = 0; i < count; i++)
          VideoItem(
            id: 'media-$i',
            path: '/$i.mp3',
            title: '媒体 $i',
            type: MediaType.audio,
            durationMs: 120000,
            lastUpdated: 0,
          ),
      ]);

Widget _host(
  PlaylistManager queue, {
  required double width,
  required bool mode,
  double scale = 1,
  GlobalKey? boundary,
}) => ChangeNotifierProvider<PlaylistManager>.value(
  value: queue,
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans SC'),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 540,
          child: RepaintBoundary(
            key: boundary,
            child: ListenableBuilder(
              listenable: queue,
              builder: (context, _) => PlaylistBottomSheet(
                showPlaybackModeButton: mode,
                playlist: queue.playbackQueue,
                currentItemId: queue.anchoredItemId,
                onItemTap: (_) {},
                onOrderChanged: (ids) => reorderPlaybackQueue(queue, ids),
                onReverse: () => reversePlaybackQueue(queue),
                onResetOrder: () => resetPlaybackQueueOrder(queue),
                hasCustomOrder: queue.hasCustomOrder,
                isShuffle: queue.playbackMode == PlaybackMode.shuffle,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final spec in [
    (screen: const Size(280, 700), width: 280.0, scale: 1.0, count: 3),
    (screen: const Size(320, 700), width: 320.0, scale: 1.0, count: 123),
    (screen: const Size(390, 844), width: 390.0, scale: 1.0, count: 3),
    (screen: const Size(768, 1024), width: 560.0, scale: 1.0, count: 3),
    (screen: const Size(1440, 900), width: 560.0, scale: 1.0, count: 3),
    (screen: const Size(1440, 900), width: 320.0, scale: 1.0, count: 3),
    (screen: const Size(320, 700), width: 320.0, scale: 2.0, count: 3),
    (screen: const Size(390, 844), width: 390.0, scale: 2.0, count: 3),
  ]) {
    testWidgets(
      'mini playlist mode stays inline ${spec.screen.width}/${spec.width} x${spec.scale}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = spec.screen;
        addTearDown(tester.view.reset);
        final queue = _queue(spec.count);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          _host(queue, width: spec.width, mode: false, scale: spec.scale),
        );
        await tester.pumpAndSettle();
        final oldHeader = tester.getRect(find.byType(PlaybackQueueHeader));
        final oldList = tester.getRect(find.byType(PlaybackQueueListView));
        final oldSort = tester.getRect(find.byType(PlaybackQueueSortControls));
        await tester.pumpWidget(
          _host(
            queue,
            width: spec.width,
            mode: true,
            scale: spec.scale,
            boundary: boundary,
          ),
        );
        await tester.pumpAndSettle();
        final mode = find.byKey(const ValueKey('mini-playlist-playback-mode'));
        expect(mode.hitTestable(), findsOneWidget);
        final rect = tester.getRect(mode);
        final reverse = tester.getRect(
          find.byKey(const ValueKey('queue-sort-reverse')),
        );
        expect(rect.size, const Size(48, 48));
        expect(rect.right + 4, closeTo(reverse.left, 0.01));
        expect(rect.center.dy, closeTo(reverse.center.dy, 0.01));
        expect(
          tester.getRect(find.byType(PlaybackQueueHeader)).height,
          closeTo(oldHeader.height, 0.01),
        );
        expect(
          tester.getRect(find.byType(PlaybackQueueListView)).top,
          closeTo(oldList.top, 0.01),
        );
        expect(tester.getRect(find.byType(PlaybackQueueSortControls)), oldSort);
        expect(tester.takeException(), isNull);
        for (final expected in [
          PlaybackMode.shuffle,
          PlaybackMode.repeatOne,
          PlaybackMode.sequential,
        ]) {
          await tester.tap(mode);
          await tester.pumpAndSettle();
          expect(queue.playbackMode, expected);
          expect(queue.anchoredItemId, 'media-0');
          expect(tester.getRect(mode), rect);
          expect(
            tester.getRect(find.byType(PlaybackQueueSortControls)),
            oldSort,
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.label == '播放模式' &&
                  widget.properties.value == expected.label,
            ),
            findsOneWidget,
          );
        }
        if (spec.scale == 1 &&
            (spec.screen.width == 390 ||
                spec.screen.width == 768 ||
                spec.screen.width == 1440 && spec.width == 560)) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await testArtifact(
              'mini-playlist-mode-${spec.screen.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('empty mini playlists disable the mode button', (tester) async {
    final queue = _queue(0);
    await tester.pumpWidget(_host(queue, width: 320, mode: true));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mini-playlist-playback-mode')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '播放模式' &&
            widget.properties.enabled == false,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mini-playlist-playback-mode')));
    await tester.pumpAndSettle();
    expect(queue.playbackMode, PlaybackMode.sequential);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the real mini card opens the mode control and shares its state',
    (tester) async {
      final queue = _queue();
      final playback = MediaPlaybackService.forTesting();
      playback.publishRestoredSessionPreview(
        queue.playlist.first,
        const Duration(seconds: 12),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaylistManager>.value(value: queue),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlaybackCard(isVisible: true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PlaylistBottomSheet>(find.byType(PlaylistBottomSheet))
            .showPlaybackModeButton,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('mini-playlist-playback-mode')),
      );
      await tester.pumpAndSettle();
      expect(queue.playbackMode, PlaybackMode.shuffle);
      Navigator.of(tester.element(find.byType(PlaylistBottomSheet))).pop();
      await tester.pumpAndSettle();
      final miniMode = find.byKey(const ValueKey('mini-playback-mode'));
      final semantics = find.descendant(
        of: miniMode,
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '播放模式',
        ),
      );
      expect(tester.widget<Semantics>(semantics).properties.value, '随机播放');
      await tester.tap(miniMode);
      await tester.pumpAndSettle();
      expect(queue.playbackMode, PlaybackMode.repeatOne);
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pumpAndSettle();
      final playlistMode = find.descendant(
        of: find.byKey(const ValueKey('mini-playlist-playback-mode')),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '播放模式',
        ),
      );
      expect(tester.widget<Semantics>(playlistMode).properties.value, '单集循环');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
