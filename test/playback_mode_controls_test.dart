import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/desktop_media_icons.dart';
import 'package:video_player_app/widgets/playback_mode_button.dart';
import 'package:video_player_app/widgets/playback_mode_icon.dart';

void main() {
  testWidgets('Windows mode pixels match the in-app icon painter', (
    tester,
  ) async {
    final icons = await tester.runAsync(desktopPlaybackModeIcons);
    expect(icons!.keys, PlaybackMode.values.map((mode) => mode.name));
    for (final mode in PlaybackMode.values) {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: CustomPaint(
                size: const Size.square(32),
                painter: PlaybackModeIconPainter(
                  mode: mode,
                  color: const Color(0xffe6e6e6),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final rgba = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      });
      // The shared glyph color is gray, so RGBA and BGRA channels are identical.
      expect(icons[mode.name], orderedEquals(rgba!), reason: mode.label);
      expect(rgba.where((byte) => byte > 0), isNotEmpty);
    }
  });

  PlaylistManager queue({bool empty = false}) =>
      PlaylistManager(
        queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
      )..setPlaylist([
        if (!empty)
          for (var i = 0; i < 5; i++)
            VideoItem(
              id: '$i',
              path: '/$i.mp4',
              title: '$i',
              durationMs: 60000,
              lastUpdated: 0,
            ),
      ]);

  Widget host(PlaylistManager queue, {bool reduceMotion = false}) =>
      ChangeNotifierProvider<PlaylistManager>.value(
        value: queue,
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: const Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlaybackModeButton(
                    key: ValueKey('mini'),
                    size: Size.square(34),
                    iconSize: 22,
                  ),
                  PlaybackModeButton(
                    key: ValueKey('landscape'),
                    size: Size.square(36),
                    iconSize: 20,
                  ),
                  PlaybackModeButton(
                    key: ValueKey('portrait'),
                    size: Size(30, 36),
                    iconSize: 17,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets(
    'all mode controls share one queue without moving its current item',
    (tester) async {
      final manager = queue();
      final selected = manager.currentItem;
      await tester.pumpWidget(host(manager));
      final buttons = [
        'mini',
        'landscape',
        'portrait',
      ].map((name) => find.byKey(ValueKey(name))).toList();
      final rects = buttons.map(tester.getRect).toList();
      for (var i = 0; i < buttons.length; i++) {
        await tester.tap(buttons[i]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        expect(manager.playbackMode, PlaybackMode.values[(i + 1) % 3]);
        expect(manager.currentItem, same(selected));
        expect(buttons.map(tester.getRect), rects);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.value == manager.playbackMode.label,
          ),
          findsNWidgets(3),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard and rapid taps keep every entry point synchronized', (
    tester,
  ) async {
    final manager = queue();
    await tester.pumpWidget(host(manager));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(manager.playbackMode, PlaybackMode.shuffle);
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const ValueKey('portrait')));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(manager.playbackMode, PlaybackMode.shuffle);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.value == '随机播放',
      ),
      findsNWidgets(3),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion updates immediately and empty queues disable controls',
    (tester) async {
      final manager = queue();
      await tester.pumpWidget(host(manager, reduceMotion: true));
      await tester.tap(find.byKey(const ValueKey('mini')));
      await tester.pump();
      expect(manager.playbackMode, PlaybackMode.shuffle);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.value == '随机播放',
        ),
        findsNWidgets(3),
      );
      await tester.pumpWidget(host(queue(empty: true)));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == '播放模式' &&
              widget.properties.enabled == false,
        ),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
