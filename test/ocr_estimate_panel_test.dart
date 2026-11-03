import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';

class _EstimateManager extends OcrSubtitleManager {
  _EstimateManager() : super(library: LibraryService());

  int modelChecks = 0;
  final List<(String?, Duration, Duration)> requests = [];
  final List<Completer<Duration>> pending = [];
  bool delayEstimates = false;
  bool measured = true;
  OcrSubtitleJob? currentJob;

  @override
  OcrSubtitleJob? get job => currentJob;
  @override
  Future<void> initialize() async {}
  @override
  bool hasDurationMeasurements(String videoId, List<OcrSubtitleTrack> tracks) =>
      measured;
  @override
  Future<bool> isModelInstalled(OcrSubtitleLanguage language) async {
    modelChecks++;
    return true;
  }

  @override
  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    List<OcrSubtitleTrack>? tracks,
    String? videoId,
  }) {
    requests.add((videoId, start, end));
    if (delayEstimates) {
      final completer = Completer<Duration>();
      pending.add(completer);
      return completer.future;
    }
    return Future.value(
      Duration(milliseconds: (end - start).inMilliseconds ~/ 2),
    );
  }
}

class _RecordingTrackShape extends RoundedRectRangeSliderTrackShape {
  Rect? globalRect;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final rect = super.getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    globalRect = rect.shift(parentBox.localToGlobal(Offset.zero) - offset);
    return rect;
  }
}

Future<void> _showPanel(
  WidgetTester tester,
  _EstimateManager manager,
  MediaMaterializationService materialization, {
  String id = 'video',
  Duration duration = const Duration(minutes: 10),
  double width = 360,
  double textScale = 1,
  RangeSliderTrackShape? trackShape,
}) => tester.pumpWidget(
  MultiProvider(
    providers: [
      ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
      ChangeNotifierProvider<MediaMaterializationService>.value(
        value: materialization,
      ),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      theme: ThemeData(
        fontFamily: const String.fromEnvironment('OCR_UI_SCREENSHOTS').isEmpty
            ? null
            : 'OCR Progress CJK',
        sliderTheme: SliderThemeData(rangeTrackShape: trackShape),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: width,
            child: OcrSubtitlePanel(
              videoItem: VideoItem(
                id: id,
                path: '$id.mp4',
                title: id,
                durationMs: duration.inMilliseconds,
                lastUpdated: 0,
              ),
              duration: duration,
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
);

void main() {
  setUpAll(() async {
    if (const String.fromEnvironment('OCR_UI_SCREENSHOTS').isNotEmpty &&
        Platform.isWindows) {
      await (FontLoader('OCR Progress CJK')..addFont(
            Future.value(
              ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
              ),
            ),
          ))
          .load();
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  late _EstimateManager manager;
  late MediaMaterializationService materialization;
  setUp(() {
    manager = _EstimateManager();
    materialization = MediaMaterializationService(BilibiliApiService());
  });
  tearDown(() {
    manager.dispose();
    materialization.dispose();
  });

  testWidgets(
    'a long video can be dragged down to a short range and regrabbed',
    (tester) async {
      const duration = Duration(minutes: 37, seconds: 46);
      final trackShape = _RecordingTrackShape();
      await _showPanel(
        tester,
        manager,
        materialization,
        duration: duration,
        width: 261,
        trackShape: trackShape,
      );
      await tester.pump();
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(
        true,
      );
      await tester.pump();
      final slider = find.byType(RangeSlider);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final track = trackShape.globalRect!;
      Offset atSeconds(double seconds) => Offset(
        track.left + track.width * seconds / duration.inSeconds,
        track.center.dy,
      );

      var drag = await tester.startGesture(track.centerRight);
      await drag.moveTo(track.center);
      await tester.pump();
      await drag.moveTo(atSeconds(60));
      await tester.pump();
      await drag.up();
      await tester.pump();
      expect(tester.widget<RangeSlider>(slider).values.end, closeTo(60000, 1));

      // Reacquire the end handle while both touch targets overlap, then shrink.
      drag = await tester.startGesture(atSeconds(60));
      await drag.moveTo(Offset(track.left - 30, track.center.dy));
      await tester.pump();
      var values = tester.widget<RangeSlider>(slider).values;
      expect(values.end, greaterThan(values.start));
      await drag.moveTo(atSeconds(30));
      await tester.pump();
      await drag.up();
      await tester.pump();
      values = tester.widget<RangeSlider>(slider).values;
      expect(values.start, 0);
      expect(values.end, closeTo(30000, 1));
      expect(manager.requests.last.$2, Duration.zero);
      expect(manager.requests.last.$3.inMilliseconds, closeTo(30000, 1));

      // The start handle remains independently draggable in the same overlap.
      drag = await tester.startGesture(atSeconds(0));
      await drag.moveTo(Offset(track.left + 30, track.center.dy));
      await tester.pump();
      values = tester.widget<RangeSlider>(slider).values;
      expect(values.end, greaterThan(values.start));
      await drag.moveTo(atSeconds(10));
      await tester.pump();
      await drag.up();
      await tester.pump();
      values = tester.widget<RangeSlider>(slider).values;
      expect(values.start, closeTo(10000, 1));
      expect(values.end, closeTo(30000, 1));
      expect(manager.modelChecks, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('time text opens precise editing without toggling the range', (
    tester,
  ) async {
    await _showPanel(
      tester,
      manager,
      materialization,
      duration: const Duration(minutes: 37, seconds: 46),
      width: 261,
    );
    await tester.pump();
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(true);
    await tester.pump();
    final edit = find.byKey(const ValueKey('ocr-edit-time-range'));
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('00:00 — 37:46'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.byKey(const ValueKey('ocr-time-range-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ocr-range-start')),
      '12:00',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ocr-range-end')),
      '12:30',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('12:00 — 12:30'), findsOneWidget);
    expect(manager.requests.last, (
      'video',
      const Duration(minutes: 12),
      const Duration(minutes: 12, seconds: 30),
    ));
    expect(manager.modelChecks, 1);
    expect(tester.takeException(), isNull);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ocr-range-end')),
      '13:00',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('12:00 — 12:30'), findsOneWidget);
  });

  testWidgets('range editing is disabled while an OCR job is running', (
    tester,
  ) async {
    await _showPanel(tester, manager, materialization);
    await tester.pump();
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(true);
    await tester.pump();
    manager.currentJob = const OcrSubtitleJob(
      videoId: 'video',
      videoPath: 'video.mp4',
      tracks: [],
      start: Duration.zero,
      end: Duration(minutes: 10),
      status: OcrSubtitleJobStatus.recognizing,
    );
    manager.notifyListeners();
    await tester.pump();
    expect(
      tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('ocr-edit-time-range')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('range edits use the correct span without re-hashing models', (
    tester,
  ) async {
    await _showPanel(tester, manager, materialization);
    await tester.pump();
    expect(manager.modelChecks, 1);
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    toggle.onChanged!(true);
    await tester.pump();
    var slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(60000, 120000));
    slider.onChangeEnd!(const RangeValues(60000, 120000));
    await tester.pump();
    expect(manager.requests.last, (
      'video',
      const Duration(minutes: 1),
      const Duration(minutes: 2),
    ));
    expect(find.textContaining('预计耗时 00:30'), findsOneWidget);
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(
      false,
    );
    await tester.pump();
    expect(manager.requests.last, (
      'video',
      Duration.zero,
      const Duration(minutes: 10),
    ));
    expect(find.textContaining('预计耗时 05:00'), findsOneWidget);
    expect(manager.modelChecks, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late estimates cannot overwrite a newer range', (tester) async {
    manager.delayEstimates = true;
    await _showPanel(tester, manager, materialization);
    await tester.pump();
    expect(manager.pending, hasLength(1));
    tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(true);
    await tester.pump();
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(60000, 120000));
    slider.onChangeEnd!(const RangeValues(60000, 120000));
    await tester.pump();
    expect(manager.pending, hasLength(3));
    manager.pending.last.complete(const Duration(seconds: 30));
    await tester.pump();
    manager.pending.first.complete(const Duration(minutes: 5));
    manager.pending[1].complete(const Duration(minutes: 5));
    await tester.pump();
    expect(find.textContaining('预计耗时 00:30'), findsOneWidget);
    expect(find.textContaining('预计耗时 05:00'), findsNothing);
    expect(manager.modelChecks, 1);
  });

  testWidgets('changing videos refreshes the preflight estimate', (
    tester,
  ) async {
    await _showPanel(tester, manager, materialization);
    await tester.pump();
    await _showPanel(
      tester,
      manager,
      materialization,
      id: 'second',
      duration: const Duration(minutes: 2),
    );
    await tester.pump();
    expect(manager.requests.last, (
      'second',
      Duration.zero,
      const Duration(minutes: 2),
    ));
    expect(find.textContaining('预计耗时 01:00'), findsOneWidget);
  });

  testWidgets('unmeasured models do not display a fabricated preflight time', (
    tester,
  ) async {
    manager.measured = false;
    await _showPanel(tester, manager, materialization);
    await tester.pump();
    expect(find.textContaining('预计耗时 待首次识别校准'), findsOneWidget);
    expect(find.textContaining('预计耗时 05:00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow panel displays ETA and unknown download time', (
    tester,
  ) async {
    manager.currentJob = const OcrSubtitleJob(
      videoId: 'video',
      videoPath: 'video.mp4',
      tracks: [],
      start: Duration.zero,
      end: Duration(minutes: 10),
      status: OcrSubtitleJobStatus.recognizing,
      progress: 0.4,
      remaining: Duration(minutes: 2, seconds: 10),
    );
    await _showPanel(tester, manager, materialization, width: 261);
    await tester.pump();
    expect(find.textContaining('剩余约 02:10'), findsOneWidget);
    manager.currentJob = manager.currentJob!.copyWith(
      status: OcrSubtitleJobStatus.materializing,
      clearRemaining: true,
    );
    manager.notifyListeners();
    await tester.pump();
    expect(find.textContaining('时间估算中'), findsOneWidget);
    expect(find.textContaining('剩余约 02:10'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [
    (213.0, 1.0),
    (261.0, 1.0),
    (261.0, 2.0),
    (600.0, 1.4),
  ]) {
    testWidgets('region progress stays visible and stable at $width / $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      manager.currentJob = OcrSubtitleJob(
        videoId: 'video',
        videoPath: 'video.mp4',
        tracks: const [
          OcrSubtitleTrack(
            number: 1,
            language: OcrSubtitleLanguage.chinese,
            region: NormalizedOcrRegion.subtitleDefault(),
          ),
          OcrSubtitleTrack(
            number: 2,
            language: OcrSubtitleLanguage.english,
            region: NormalizedOcrRegion.subtitleDefault(),
          ),
        ],
        start: const Duration(minutes: 5),
        end: const Duration(minutes: 15),
        status: OcrSubtitleJobStatus.recognizing,
        progress: .4,
        remaining: const Duration(minutes: 2),
        recognitionProgress: OcrRecognitionProgress(
          total: const Duration(minutes: 10),
          completedByTrack: const {
            1: Duration(minutes: 5),
            2: Duration(minutes: 3),
          },
        ),
      );
      await _showPanel(
        tester,
        manager,
        materialization,
        width: width,
        textScale: scale,
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('05:00 / 10:00'), findsOneWidget);
      expect(find.text('03:00 / 10:00'), findsOneWidget);
      expect(find.textContaining('剩余约 02:00'), findsOneWidget);
      final footer = find.byKey(const ValueKey('ocr-pinned-task-action'));
      final cancel = find.byKey(const ValueKey('ocr-pinned-cancel'));
      final originalBounds = tester.getRect(footer);
      final controls = tester.widget(find.byType(ListView).first);
      manager.currentJob = manager.currentJob!.copyWith(
        progress: .45,
        remaining: const Duration(minutes: 1, seconds: 50),
        recognitionProgress: OcrRecognitionProgress(
          total: const Duration(minutes: 10),
          completedByTrack: const {
            1: Duration(minutes: 5),
            2: Duration(minutes: 4),
          },
        ),
      );
      manager.notifyListeners();
      await tester.pump();
      expect(find.text('45%'), findsOneWidget);
      expect(find.text('04:00 / 10:00'), findsOneWidget);
      expect(tester.getRect(footer), originalBounds);
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(320));
      expect(
        identical(tester.widget(find.byType(ListView).first), controls),
        isTrue,
        reason: 'progress must not rebuild the scrollable settings body',
      );
      expect(tester.takeException(), isNull);
      const screenshots = String.fromEnvironment('OCR_UI_SCREENSHOTS');
      if (screenshots.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('ocr-pinned-footer-boundary')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshots).create(recursive: true);
          await File(
            '$screenshots/progress-${width.toInt()}-$scale.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets(
    'model preparation has its own percentage and OCR begins at zero',
    (tester) async {
      manager.currentJob = const OcrSubtitleJob(
        videoId: 'video',
        videoPath: 'video.mp4',
        tracks: [],
        start: Duration.zero,
        end: Duration(minutes: 10),
        status: OcrSubtitleJobStatus.downloading,
        progress: 0,
        preparationProgress: .86,
        statusMessage: '正在下载 OCR 模型',
      );
      await _showPanel(tester, manager, materialization, width: 261);
      await tester.pump();
      expect(find.text('86%'), findsOneWidget);
      expect(manager.job!.progress, 0);
      manager.currentJob = manager.currentJob!.copyWith(
        status: OcrSubtitleJobStatus.recognizing,
        clearPreparationProgress: true,
      );
      manager.notifyListeners();
      await tester.pump();
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('86%'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
