import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_keep_awake_action.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';

class _PanelManager extends OcrSubtitleManager {
  _PanelManager() : super(library: LibraryService());
  OcrSubtitleJob? currentJob;

  @override
  OcrSubtitleJob? get job => currentJob;
  @override
  bool get isRunning => currentJob?.isRunning ?? false;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> isModelInstalled(OcrSubtitleLanguage language) async => true;
  @override
  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    List<OcrSubtitleTrack>? tracks,
    String? videoId,
  }) async => const Duration(minutes: 1);

  void publish(OcrSubtitleJob job) {
    currentJob = job;
    processingKeepAwake.updateJob(job);
    notifyListeners();
  }
}

const _actionKey = ValueKey('ocr-processing-keep-awake');
const _boundaryKey = ValueKey('ocr-keep-awake-panel-boundary');
const _screenshots = String.fromEnvironment('OCR_UI_SCREENSHOTS');

Future<void> _showPanel(
  WidgetTester tester,
  _PanelManager manager,
  MediaMaterializationService materialization, {
  required double width,
  required double scale,
}) => tester.pumpWidget(
  MultiProvider(
    providers: [
      ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
      ChangeNotifierProvider<MediaMaterializationService>.value(
        value: materialization,
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: _screenshots.isEmpty ? null : 'OCR Keep Awake CJK',
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: width,
            child: RepaintBoundary(
              key: _boundaryKey,
              child: OcrSubtitlePanel(
                videoItem: VideoItem(
                  id: 'video',
                  path: 'video.mp4',
                  title: 'Video',
                  durationMs: 600000,
                  lastUpdated: 0,
                ),
                duration: const Duration(minutes: 10),
                currentPosition: () => Duration.zero,
                pauseForRegionSelection: () async => false,
                restorePlayback: (_) async {},
                onBack: () {},
                onCompleted: (_) async {},
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  if (_screenshots.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(_screenshots).create(recursive: true);
    await File(
      '$_screenshots/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_screenshots.isEmpty || !Platform.isWindows) return;
    for (final (family, path) in [
      ('OCR Keep Awake CJK', 'C:/Windows/Fonts/msyh.ttc'),
      (
        'MaterialIcons',
        'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      await (FontLoader(family)..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          ))
          .load();
    }
  });

  late _PanelManager manager;
  late MediaMaterializationService materialization;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    manager = _PanelManager();
    materialization = MediaMaterializationService(BilibiliApiService());
  });
  tearDown(() {
    manager.dispose();
    materialization.dispose();
  });

  for (final (name, viewport, width, scale) in [
    ('small-landscape', const Size(568, 320), 261.0, 1.0),
    ('small-portrait', const Size(320, 720), 320.0, 1.0),
    ('phone', const Size(390, 844), 390.0, 1.0),
    ('tablet', const Size(1024, 768), 389.0, 1.0),
    ('desktop', const Size(1440, 900), 420.0, 1.0),
    ('large-font', const Size(568, 320), 261.0, 2.0),
    ('large-font-portrait', const Size(320, 720), 320.0, 2.0),
    ('narrow-desktop-sidebar', const Size(1440, 900), 248.0, 1.3),
  ]) {
    testWidgets('OCR checkbox fits and remains operable on $name', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _showPanel(
        tester,
        manager,
        materialization,
        width: width,
        scale: scale,
      );
      await tester.pump();
      final action = find.byKey(_actionKey);
      expect(action, findsOneWidget);
      final bounds = tester.getRect(action);
      final panel = tester.getRect(find.byKey(_boundaryKey));
      final title = tester.getRect(find.text('OCR 字幕'));
      expect(bounds.right, lessThanOrEqualTo(panel.right));
      expect(bounds.left, greaterThanOrEqualTo(title.right));
      expect(bounds.top, greaterThanOrEqualTo(panel.top));
      expect(bounds.bottom, lessThanOrEqualTo(panel.top + 50));
      expect(title.width, greaterThan(60));
      expect(tester.takeException(), isNull);
      expect(tester.widget<OcrKeepAwakeAction>(action).checked, isTrue);
      expect(manager.processingKeepAwake.isActive, isFalse);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(tester.widget<OcrKeepAwakeAction>(action).checked, isFalse);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(tester.widget<OcrKeepAwakeAction>(action).checked, isTrue);
      expect(tester.widget<OcrKeepAwakeAction>(action).active, isFalse);
      expect(manager.processingKeepAwake.isActive, isFalse);
      expect(tester.takeException(), isNull);
      await _capture(tester, name);
    });
  }

  testWidgets(
    'checkbox announces state and follows processing independently of panel',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _showPanel(
          tester,
          manager,
          materialization,
          width: 360,
          scale: 1,
        );
        await tester.pump();
        final checkbox = find.bySemanticsLabel('处理时不息屏');
        expect(checkbox, findsOneWidget);
        expect(
          tester.getSemantics(checkbox).flagsCollection.isChecked,
          ui.CheckedState.isTrue,
        );
        await tester.tap(find.byKey(_actionKey));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(checkbox).flagsCollection.isChecked,
          ui.CheckedState.isFalse,
        );
        await tester.tap(find.byKey(_actionKey));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(checkbox).flagsCollection.isChecked,
          ui.CheckedState.isTrue,
        );
        expect(tester.getSemantics(checkbox).value, contains('等待'));
        manager.publish(
          OcrSubtitleJob(
            videoId: 'video',
            videoPath: 'video.mp4',
            tracks: manager.tracksForVideo('video'),
            start: Duration.zero,
            end: const Duration(minutes: 10),
            status: OcrSubtitleJobStatus.recognizing,
            progress: .4,
            statusMessage: '正在抽取并识别字幕帧',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<OcrKeepAwakeAction>(find.byKey(_actionKey)).active,
          isTrue,
        );
        expect(tester.getSemantics(checkbox).value, contains('正在保持亮屏'));
        await _capture(tester, 'processing');
        await tester.tap(find.byKey(_actionKey));
        await tester.pumpAndSettle();
        expect(manager.processingKeepAwake.isActive, isFalse);
        await tester.tap(find.byKey(_actionKey));
        await tester.pumpAndSettle();
        expect(manager.processingKeepAwake.isActive, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          AppWakelockCoordinator.isReasonActive(
            AppWakelockCoordinator.ocrProcessingReason,
          ),
          isTrue,
          reason:
              'closing the panel must not interrupt an ongoing task request',
        );
        manager.publish(
          manager.job!.copyWith(status: OcrSubtitleJobStatus.completed),
        );
        expect(manager.processingKeepAwake.isActive, isFalse);
        expect(
          AppWakelockCoordinator.isReasonActive(
            AppWakelockCoordinator.ocrProcessingReason,
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
