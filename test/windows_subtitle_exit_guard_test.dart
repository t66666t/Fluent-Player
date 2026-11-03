import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/windows_subtitle_exit_guard.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/deferred_subtitle_edits.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'normal close waits for subtitle save and coalesces repeated close',
    (tester) async {
      await WindowsSubtitleExitGuard.install();
      expect(calls.single.method, 'setPreventClose');
      expect(calls.single.arguments, {'isPreventClose': true});
      final guard = windowManager.listeners
          .whereType<WindowsSubtitleExitGuard>()
          .single;
      final editor = DeferredSubtitleEdits();
      final gate = Completer<void>();
      var saved = false;
      editor.schedule(
        [
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: Duration.zero,
          ),
        ],
        (_) async {
          await gate.future;
          saved = true;
        },
      );
      guard.onWindowClose();
      guard.onWindowClose();
      await tester.pump();
      expect(saved, isFalse);
      expect(calls.where((call) => call.method == 'destroy'), isEmpty);
      gate.complete();
      await tester.pump();
      expect(saved, isTrue);
      expect(calls.where((call) => call.method == 'destroy'), hasLength(1));
    },
  );

  testWidgets('failed save keeps the window open and a later close retries', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: const Scaffold(body: Text('editor')),
      ),
    );
    await WindowsSubtitleExitGuard.install();
    final guard = windowManager.listeners
        .whereType<WindowsSubtitleExitGuard>()
        .single;
    final editor = DeferredSubtitleEdits();
    var failing = true;
    editor.schedule(
      [
        SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: Duration.zero,
        ),
      ],
      (_) async {
        if (failing) throw const FileSystemException('injected save failure');
      },
    );
    guard.onWindowClose();
    await tester.pump();
    expect(tester.takeException(), isA<FileSystemException>());
    expect(calls.where((call) => call.method == 'destroy'), isEmpty);
    expect(editor.hasPending, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('字幕保存失败'), findsOneWidget);
    failing = false;
    guard.onWindowClose();
    await tester.pump();
    expect(calls.where((call) => call.method == 'destroy'), hasLength(1));
    expect(editor.hasPending, isFalse);
    await AppToast.dismiss(immediate: true);
    await tester.pump();
  });
}
