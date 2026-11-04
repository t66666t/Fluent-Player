import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

class _CountingPosition extends ValueNotifier<Duration> {
  _CountingPosition(super.value);

  int reads = 0;
  bool get listening => hasListeners;

  @override
  Duration get value {
    reads++;
    return super.value;
  }
}

Future<String> _document(
  WidgetTester tester, {
  String prefix = 'comment',
  int count = 160,
  bool futureEntry = false,
}) async {
  late Directory directory;
  late String path;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('danmaku_visibility_');
    final file = File('${directory.path}/comments.ass');
    path = file.path;
    await file.writeAsString('''
[Script Info]
PlayResX: 800
PlayResY: 600
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
${List.generate(count, (i) => r'Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\move(800,'
        '$i,-200,$i)}$prefix $i').join('\n')}
${futureEntry ? r'Dialogue: 0,0:00:20.00,0:01:00.00,Medium,,0,0,0,,{\pos(400,300)}new entry after hidden interval' : ''}
''');
  });
  addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
  return path;
}

Widget _overlay(
  String path,
  _CountingPosition position, {
  double fontScale = 1,
}) => DanmakuOverlay(
  path: path,
  position: position,
  displayArea: 1,
  opacity: 1,
  fontScale: fontScale,
  speed: 1,
  fontFamily: null,
  fontWeight: 600,
  outlineType: DanmakuOutlineType.standard,
  playerHeight: 600,
);

Future<void> _warm(WidgetTester tester) async {
  for (var i = 0; i < 35; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

CustomPainter _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(DanmakuOverlay),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter!;

Future<List<int>> _pixels(WidgetTester tester, CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(800, 600));
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(800, 600));
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final pixels = data!.buffer.asUint8List().toList();
  image!.dispose();
  picture.dispose();
  return pixels;
}

void main() {
  testWidgets('opaque route releases visual clock and returns at current time', (
    tester,
  ) async {
    final path = await _document(tester, count: 1);
    final position = _CountingPosition(const Duration(seconds: 2));
    addTearDown(position.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: _overlay(path, position)),
    );
    await _warm(tester);
    expect(position.listening, isTrue);
    final initial = await _pixels(tester, _painter(tester));
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('music page')),
    );
    await tester.pumpAndSettle();
    expect(position.listening, isFalse);
    position.reads = 0;
    for (var i = 1; i <= 144; i++) {
      position.value = Duration(microseconds: 5000000 + i * 6944);
      await tester.pump(const Duration(microseconds: 6944));
    }
    expect(position.reads, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _warm(tester);
    expect(position.listening, isTrue);
    final resumed = await _pixels(tester, _painter(tester));
    expect(resumed, isNot(equals(initial)));
    // Rebuilding the same scene at the current time must produce the same
    // picture as the resumed atlas, rather than replaying the hidden interval.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: _overlay(path, position)));
    await _warm(tester);
    expect(await _pixels(tester, _painter(tester)), equals(resumed));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('transparent dialog keeps visible comments following playback', (
    tester,
  ) async {
    final path = await _document(tester);
    final position = _CountingPosition(const Duration(seconds: 2));
    addTearDown(position.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: _overlay(path, position)),
    );
    await _warm(tester);
    final before = await _pixels(tester, _painter(tester));
    showDialog<void>(
      context: tester.element(find.byType(DanmakuOverlay)),
      builder: (_) => const AlertDialog(content: Text('settings')),
    );
    await tester.pumpAndSettle();
    expect(position.listening, isTrue);
    position.value = const Duration(seconds: 5);
    await tester.pump();
    expect(await _pixels(tester, _painter(tester)), isNot(equals(before)));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reveal admits a new entry beyond the old prefetch runway', (
    tester,
  ) async {
    final path = await _document(tester, count: 0, futureEntry: true);
    final position = _CountingPosition(const Duration(seconds: 2));
    addTearDown(position.dispose);
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: visible,
              child: _overlay(path, position),
            );
          },
        ),
      ),
    );
    await _warm(tester);
    update(() => visible = false);
    await tester.pump();
    // This comment was outside the earlier ten-second upload runway. The
    // first resumed paint must allow its cold upload instead of permanently
    // rejecting it as an asset that missed its entrance.
    position.value = const Duration(seconds: 20);
    update(() => visible = true);
    await tester.pump();
    await _warm(tester);
    final resumed = await _pixels(tester, _painter(tester));
    expect(resumed.where((value) => value != 0), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: _overlay(path, position)));
    await _warm(tester);
    expect(await _pixels(tester, _painter(tester)), equals(resumed));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden app detaches immediately while inactive stays visible', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final path = await _document(tester);
    final position = _CountingPosition(const Duration(seconds: 2));
    addTearDown(position.dispose);
    await tester.pumpWidget(MaterialApp(home: _overlay(path, position)));
    await _warm(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(position.listening, isTrue);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      // No pump: a hidden app may not receive a frame to rebuild its painter.
      expect(position.listening, isFalse, reason: '$state');
      position.reads = 0;
      position.value = const Duration(seconds: 5);
      expect(position.reads, 0);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _warm(tester);
    expect(position.listening, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('source and style replaced while covered wait for reveal', (
    tester,
  ) async {
    final firstPath = await _document(tester, prefix: 'old');
    final nextPath = await _document(tester, prefix: 'new');
    final oldPosition = _CountingPosition(const Duration(seconds: 2));
    final nextPosition = _CountingPosition(const Duration(seconds: 6));
    addTearDown(oldPosition.dispose);
    addTearDown(nextPosition.dispose);
    final navigator = GlobalKey<NavigatorState>();
    late StateSetter update;
    var replacement = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _overlay(
              replacement ? nextPath : firstPath,
              replacement ? nextPosition : oldPosition,
              fontScale: replacement ? 1.4 : 1,
            );
          },
        ),
      ),
    );
    await _warm(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('covered')),
    );
    await tester.pumpAndSettle();
    update(() => replacement = true);
    await tester.pump();
    await _warm(tester);
    expect(oldPosition.listening, isFalse);
    expect(nextPosition.listening, isFalse);
    nextPosition.reads = 0;
    nextPosition.value = const Duration(seconds: 7);
    await tester.pump(const Duration(seconds: 2));
    expect(nextPosition.reads, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await _warm(tester);
    expect(nextPosition.listening, isTrue);
    final resumed = await _pixels(tester, _painter(tester));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(home: _overlay(nextPath, nextPosition, fontScale: 1.4)),
    );
    await _warm(tester);
    expect(await _pixels(tester, _painter(tester)), equals(resumed));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hiding during atlas rebuild does not restart hidden work', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final firstPath = await _document(tester, prefix: 'first upload');
    final nextPath = await _document(tester, prefix: 'replacement upload');
    final position = _CountingPosition(const Duration(seconds: 2));
    addTearDown(position.dispose);
    late StateSetter update;
    var path = firstPath;
    var fontScale = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return _overlay(path, position, fontScale: fontScale);
          },
        ),
      ),
    );
    await _warm(tester);
    update(() => fontScale = 1.8);
    // Start the style atlas and its asynchronous image upload, then hide
    // without giving the upload the runAsync warm-up used by the other tests.
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(position.listening, isFalse);
    position.reads = 0;
    update(() {
      path = nextPath;
      fontScale = 1.2;
    });
    position.value = const Duration(seconds: 6);
    await _warm(tester);
    expect(position.reads, 0);
    expect(position.listening, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _warm(tester);
    expect(position.listening, isTrue);
    final pixels = await _pixels(tester, _painter(tester));
    expect(pixels.where((value) => value != 0), isNotEmpty);
    // Disposal can also race a style upload; late results must not revive
    // callbacks or publish to the disposed state.
    update(() => fontScale = 1.6);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    position.reads = 0;
    await _warm(tester);
    expect(position.reads, 0);
    expect(position.listening, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlay mounted in a hidden app waits for its first reveal', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    final path = await _document(tester, count: 1);
    final position = _CountingPosition(const Duration(seconds: 3));
    addTearDown(position.dispose);
    await tester.pumpWidget(MaterialApp(home: _overlay(path, position)));
    await _warm(tester);
    expect(position.listening, isFalse);
    expect(position.reads, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await _warm(tester);
    expect(position.listening, isTrue);
    expect(_painter(tester), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
