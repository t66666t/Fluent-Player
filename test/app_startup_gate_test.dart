import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player_app/platform/linux_file_picker.dart';
import 'package:video_player_app/main.dart';

void main() {
  testWidgets('recovery exposes chooser errors and a manual path fallback', (
    tester,
  ) async {
    const channel = MethodChannel('recovery-chooser-test');
    FilePicker? original;
    try {
      original = FilePicker.platform;
    } catch (_) {
      // The unit-test engine does not register a desktop FilePicker instance.
    }
    FilePicker.platform = LinuxFilePicker(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'chooser_unavailable'),
        );
    addTearDown(() {
      if (original != null) FilePicker.platform = original;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await tester.pumpWidget(
      AppStartupGate(
        initialize: () async => throw StateError('missing data drive'),
        onReadyFirstFrame: () {},
        child: const Text('not ready'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择原目录'));
    await tester.tap(find.text('选择原目录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法打开目录选择窗口'), findsOneWidget);
    expect(find.widgetWithText(TextField, '原数据目录的完整路径'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('startup work waits until the lightweight first frame', (
    tester,
  ) async {
    final initialization = Completer<void>();
    var initializationCalls = 0;
    var readyFrameCalls = 0;

    await tester.pumpWidget(
      AppStartupGate(
        initialize: () {
          initializationCalls++;
          return initialization.future;
        },
        onReadyFirstFrame: () => readyFrameCalls++,
        child: const MaterialApp(home: Text('home-ready')),
      ),
    );

    expect(find.byKey(const ValueKey<String>('startup-cover')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在准备媒体库…'), findsNothing);
    expect(find.text('home-ready'), findsNothing);
    expect(initializationCalls, 1);
    expect(readyFrameCalls, 0);

    initialization.complete();
    await tester.pump();

    expect(find.text('home-ready'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('startup-cover')), findsNothing);
    expect(initializationCalls, 1);
    expect(readyFrameCalls, 1);
  });

  testWidgets('native-ready startup goes directly to the home first frame', (
    tester,
  ) async {
    var initializationCalls = 0;
    var readyFrameCalls = 0;

    await tester.pumpWidget(
      AppStartupGate(
        initiallyReady: true,
        initialize: () async {
          initializationCalls++;
        },
        onReadyFirstFrame: () => readyFrameCalls++,
        child: const MaterialApp(home: Text('home-first-frame')),
      ),
    );

    expect(find.text('home-first-frame'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('startup-cover')), findsNothing);
    expect(initializationCalls, 0);
    expect(readyFrameCalls, 1);

    await tester.pump();
    expect(readyFrameCalls, 1);
  });
  testWidgets(
    'storage initialization failure never mounts library writers and can retry',
    (tester) async {
      var available = false;
      var readyCalls = 0;
      await tester.pumpWidget(
        AppStartupGate(
          initialize: () async {
            if (!available) throw StateError('data drive offline');
          },
          onReadyFirstFrame: () => readyCalls++,
          child: const MaterialApp(home: Text('library-writers-mounted')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('需要恢复数据目录'), findsOneWidget);
      expect(find.text('library-writers-mounted'), findsNothing);
      expect(readyCalls, 0);
      expect(tester.takeException(), isNull);
      available = true;
      await tester.tap(find.text('重新读取'));
      await tester.pumpAndSettle();
      expect(find.text('library-writers-mounted'), findsOneWidget);
      expect(readyCalls, 1);
    },
  );
}
