import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Exercise the local Windows implementation selected by dependency_overrides.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/src/webview_environment/webview_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const manager = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_manager',
  );
  const surface = MethodChannel('com.pichillilorenzo/custom_platform_view_11');
  const events = MethodChannel(
    'com.pichillilorenzo/custom_platform_view_11_events',
  );
  final calls = <MethodCall>[];
  test('each native environment disposes through its own channel', () async {
    const environments = MethodChannel(
      'com.pichillilorenzo/flutter_webview_environment',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? created, disposed;
    messenger.setMockMethodCallHandler(environments, (call) async {
      created = call.arguments['id'] as String;
      messenger.setMockMethodCallHandler(
        MethodChannel(
          'com.pichillilorenzo/flutter_webview_environment_$created',
        ),
        (call) async {
          disposed = created;
          return null;
        },
      );
      return null;
    });
    try {
      final environment = await WindowsWebViewEnvironment.static().create();
      await environment.dispose();
      expect(disposed, created);
      expect(disposed, isNotNull);
    } finally {
      messenger.setMockMethodCallHandler(environments, null);
      if (created != null) {
        messenger.setMockMethodCallHandler(
          MethodChannel(
            'com.pichillilorenzo/flutter_webview_environment_$created',
          ),
          null,
        );
      }
    }
  });
  late FocusNode addressFocus;
  setUp(() {
    addressFocus = FocusNode();
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, (call) async {
      if (call.method == 'createInAppWebView') return 11;
      return null;
    });
    messenger.setMockMethodCallHandler(surface, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() {
    addressFocus.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, null);
    messenger.setMockMethodCallHandler(surface, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Widget host({Size size = const Size(400, 300), double? scale = 1}) =>
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: addressFocus),
              SizedBox(
                width: size.width,
                height: size.height,
                child: CustomPlatformView(scaleFactor: scale),
              ),
            ],
          ),
        ),
      );

  testWidgets('blank mouse clicks do not resize a stable native surface', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    calls.clear();
    for (var i = 0; i < 5; i++) {
      await tester.tap(
        find.byType(CustomPlatformView),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(calls.where((call) => call.method == 'setSize'), isEmpty);
    expect(calls.where((call) => call.method == 'setPosition'), hasLength(5));
    expect(
      calls.where((call) => call.method == 'setPointerButton'),
      hasLength(10),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'a click without hover sends its current position before the button',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      calls.clear();
      final rect = tester.getRect(find.byType(CustomPlatformView));
      final gesture = await tester.startGesture(
        rect.topLeft + const Offset(70, 90),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final down = calls.indexWhere(
        (call) =>
            call.method == 'setPointerButton' &&
            call.arguments['isDown'] == true,
      );
      final cursor = calls.indexWhere((call) => call.method == 'setCursorPos');
      expect(cursor, greaterThanOrEqualTo(0));
      expect(cursor, lessThan(down));
      expect(calls[cursor].arguments, [70.0, 90.0]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('native click never steals a later address focus', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    addressFocus.requestFocus();
    await tester.pump();
    await tester.tap(
      find.byType(CustomPlatformView),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(addressFocus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'touch contacts cancel independently without becoming page taps',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      calls.clear();
      final rect = tester.getRect(find.byType(CustomPlatformView));
      final first = await tester.startGesture(
        rect.topLeft + const Offset(60, 80),
        pointer: 7,
      );
      final second = await tester.startGesture(
        rect.topLeft + const Offset(160, 80),
        pointer: 8,
      );
      await first.moveBy(const Offset(0, 25));
      await first.cancel();
      await second.up();
      await tester.pumpAndSettle();
      final updates = calls
          .where((call) => call.method == 'setPointerUpdate')
          .map((call) => call.arguments as List<dynamic>)
          .toList();
      expect(updates.map((args) => args[0]).toSet(), hasLength(2));
      final canceled = updates.singleWhere((args) => args[6] == true);
      expect(canceled[0], updates.first[0]);
      expect(canceled[1], 4); // Native Up with POINTER_FLAG_CANCELED.
      expect(updates.last[6], false);
      expect(updates.last[0], isNot(canceled[0]));
      expect(calls.where((call) => call.method == 'setPointerButton'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('mouse hover and right-click work immediately after touch', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(CustomPlatformView));
    await tester.tapAt(rect.topLeft + const Offset(60, 80));
    calls.clear();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: rect.topLeft + const Offset(70, 80));
    await mouse.moveTo(rect.topLeft + const Offset(90, 100));
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'setCursorPos').last.arguments,
      [90.0, 100.0],
    );
    await mouse.removePointer();
    calls.clear();
    final right = await tester.startGesture(
      rect.topLeft + const Offset(100, 110),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    await tester.pumpAndSettle();
    final buttons = calls.where((call) => call.method == 'setPointerButton');
    expect(buttons.map((call) => call.arguments['button']), [2, 2]);
    expect(buttons.map((call) => call.arguments['isDown']), [true, false]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('real size and display scale changes still update the surface', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    calls.clear();
    await tester.pumpWidget(host(size: const Size(480, 360)));
    await tester.pumpAndSettle();
    expect(
      calls
          .where((call) => call.method == 'setSize')
          .map((call) => call.arguments),
      [
        [480.0, 360.0, 1.0],
      ],
    );
    calls.clear();
    await tester.pumpWidget(host(size: const Size(480, 360), scale: 2));
    await tester.pumpAndSettle();
    expect(
      calls
          .where((call) => call.method == 'setSize')
          .map((call) => call.arguments),
      [
        [480.0, 360.0, 2.0],
      ],
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'monitor DPI changes update a surface with unchanged logical size',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(host(scale: null));
      await tester.pumpAndSettle();
      calls.clear();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1600, 1200);
      await tester.pumpAndSettle();
      expect(
        calls
            .where((call) => call.method == 'setSize')
            .map((call) => call.arguments),
        [
          [400.0, 300.0, 2.0],
        ],
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
