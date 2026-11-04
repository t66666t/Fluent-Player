import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/widgets/ambient_letterbox_layer.dart';

void main() {
  late VideoPlayerController controller;
  late int captures;

  setUp(() {
    captures = 0;
    controller = VideoPlayerController.asset('ambient-test')
      ..value = const VideoPlayerValue(
        duration: Duration(minutes: 1),
        isInitialized: true,
        isPlaying: true,
        size: Size(1920, 1080),
      );
  });

  tearDown(() async => controller.dispose());

  Future<Uint8List?> capture(int playerId) async {
    expectSync(playerId, 7);
    captures++;
    return null;
  }

  Widget host({
    bool visible = true,
    bool gap = true,
    Future<Uint8List?> Function(int)? captureFrame,
  }) => MaterialApp(
    home: TickerMode(
      enabled: visible,
      child: AmbientLetterboxLayer(
        enabled: true,
        mediaId: 'test-media',
        playerId: 7,
        controller: controller,
        scrubbing: false,
        transforming: false,
        seekHold: false,
        columnSize: const Size(800, 600),
        containedVideoSize: gap ? const Size(800, 450) : const Size(800, 600),
        userScale: 1,
        userRotation: 0,
        userOffset: Offset.zero,
        captureFrame: captureFrame ?? capture,
      ),
    ),
  );

  testWidgets('hidden app and covered route stop sampling and catch up once', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(host());
    expect(captures, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(captures, 2);

    // An unfocused window/notification shade can still show the player.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 1));
    expect(captures, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(captures, 4);

    await tester.pumpWidget(host(visible: false));
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 4);
    await tester.pumpWidget(host());
    expect(captures, 5);
    await tester.pump(const Duration(seconds: 1));
    expect(captures, 6);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paused video settles its matte then stops, and follows seeks', (
    tester,
  ) async {
    controller.value = controller.value.copyWith(isPlaying: false);
    await tester.pumpWidget(host());
    expect(captures, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 2);

    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 9),
    );
    await tester.pump();
    expect(captures, 3);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 4);

    controller.value = controller.value.copyWith(isPlaying: true);
    await tester.pump();
    expect(captures, 5);
    await tester.pump(const Duration(seconds: 1));
    expect(captures, 6);
    controller.value = controller.value.copyWith(isPlaying: false);
    await tester.pump();
    expect(captures, 7);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 8);
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 8);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'fully covered matte stops its timer and refreshes when revealed',
    (tester) async {
      await tester.pumpWidget(host(gap: false));
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 0);
      await tester.pumpWidget(host());
      expect(captures, 1);
      await tester.pumpWidget(host(gap: false));
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'paused visibility catch-up waits for an earlier capture safely',
    (tester) async {
      controller.value = controller.value.copyWith(isPlaying: false);
      final first = Completer<Uint8List?>();
      Future<Uint8List?> slowCapture(int playerId) {
        captures++;
        return captures == 1 ? first.future : Future.value(null);
      }

      await tester.pumpWidget(host(captureFrame: slowCapture));
      expect(captures, 1);
      await tester.pumpWidget(host(visible: false, captureFrame: slowCapture));
      await tester.pumpWidget(host(captureFrame: slowCapture));
      expect(captures, 1);
      first.complete(null);
      await tester.pump();
      expect(captures, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 3);
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'paused initialization catches up when the first frame is ready',
    (tester) async {
      controller.value = controller.value.copyWith(
        isInitialized: false,
        isPlaying: false,
      );
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 2);
      controller.value = controller.value.copyWith(isInitialized: true);
      await tester.pump();
      expect(captures, 3);
      await tester.pump(const Duration(seconds: 1));
      expect(captures, 4);
      await tester.pump(const Duration(seconds: 5));
      expect(captures, 4);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dispose drops a queued capture before native completion', (
    tester,
  ) async {
    controller.value = controller.value.copyWith(isPlaying: false);
    final first = Completer<Uint8List?>();
    Future<Uint8List?> slowCapture(int playerId) {
      captures++;
      return first.future;
    }

    await tester.pumpWidget(host(captureFrame: slowCapture));
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 9),
    );
    await tester.pump();
    expect(captures, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    first.complete(null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(captures, 1);
    expect(tester.takeException(), isNull);
  });
}
