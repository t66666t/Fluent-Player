import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/ocr_compute_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_compute_settings.dart';

class _Manager extends OcrSubtitleManager {
  _Manager() : super(library: LibraryService());
  int scans = 0;
  bool running = false;
  OcrComputePreferences value = const OcrComputePreferences();
  @override
  OcrComputePreferences get computePreferences => value;
  @override
  bool get isRunning => running;
  @override
  OcrSubtitleJob? get job => running
      ? OcrSubtitleJob(
          videoId: 'v',
          videoPath: 'v.mp4',
          tracks: const [],
          start: Duration.zero,
          end: const Duration(minutes: 1),
          compute: const OcrComputePreferences(mode: OcrComputeMode.cpu),
        )
      : null;
  @override
  String get activeBackend => '区域 1 · CPU（4 线程） · 已回退';
  @override
  Future<void> initialize() async {}
  @override
  Future<void> setComputePreferences(OcrComputePreferences next) async {
    if (running) return;
    value = next;
    notifyListeners();
  }

  @override
  Future<OcrComputeCapabilities> detectComputeDevices({
    bool refresh = false,
  }) async {
    scans++;
    return const OcrComputeCapabilities(
      platform: 'windows',
      isolated: true,
      providers: ['CPU', 'DirectML'],
      devices: [
        OcrComputeDevice(
          provider: 'DirectML',
          id: 1,
          key: 'card1',
          name: 'NVIDIA GeForce RTX with a very long device name',
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const screenshots = String.fromEnvironment('OCR_UI_SCREENSHOTS');
    if (screenshots.isNotEmpty && Platform.isWindows) {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (await font.exists()) {
        await (FontLoader('OCR UI CJK')..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            ))
            .load();
      }
      final icons = File(
        'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(await icons.readAsBytes())),
            ))
            .load();
      }
    }
  });
  testWidgets(
    'default does no hardware scan and hardware mode opens only available devices',
    (tester) async {
      final manager = _Manager();
      addTearDown(manager.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'OCR UI CJK',
            ),
          ),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: SingleChildScrollView(
                child: OcrComputeSettings(manager: manager),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(manager.scans, 0);
      expect(find.text('自动（推荐）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ocr-compute-accelerated')));
      await tester.pumpAndSettle();
      expect(manager.scans, 1);
      expect(find.text('加速设备'), findsOneWidget);
      expect(find.textContaining('CUDA'), findsNothing);
      await tester.tap(find.text('自动选择设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('NVIDIA GeForce').last);
      await tester.pumpAndSettle();
      expect(manager.value.provider, 'DirectML');
      expect(manager.value.deviceId, 1);
      expect(manager.value.deviceKey, 'card1');
      await tester.tap(find.byKey(const ValueKey('ocr-compute-details')));
      await tester.pumpAndSettle();
      expect(find.text('加速设备'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ocr-compute-details')));
      await tester.pumpAndSettle();
      expect(find.text('加速设备'), findsOneWidget);
      expect(manager.scans, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final width in [213.0, 261.0, 360.0, 600.0]) {
    testWidgets(
      'compute controls wrap at width $width with larger text and freeze during a task',
      (tester) async {
        final manager = _Manager();
        addTearDown(manager.dispose);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'OCR UI CJK',
              ),
            ),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: SingleChildScrollView(
                      child: RepaintBoundary(
                        key: boundaryKey,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: OcrComputeSettings(manager: manager),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ocr-compute-accelerated')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        const screenshots = String.fromEnvironment('OCR_UI_SCREENSHOTS');
        if (screenshots.isNotEmpty) {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(screenshots).create(recursive: true);
            await File(
              '$screenshots/compute-${width.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }
        manager.running = true;
        manager.notifyListeners();
        await tester.pumpAndSettle();
        final chip = tester.widget<ChoiceChip>(
          find.byKey(const ValueKey('ocr-compute-cpu')),
        );
        expect(chip.selected, isTrue);
        expect(chip.onSelected, isNull);
        expect(
          find.byKey(const ValueKey('ocr-compute-active')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
