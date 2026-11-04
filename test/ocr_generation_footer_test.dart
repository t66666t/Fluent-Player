import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';
import 'package:video_player_app/widgets/music_lyric_selection_pane.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/subtitle_generation_footer.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

class _Library extends ChangeNotifier implements LibraryService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ocr extends OcrSubtitleManager {
  _Ocr(LibraryService library) : super(library: library);
  OcrSubtitleJob? current;
  List<SubtitleStreamUpdate> latest = [];
  @override
  OcrSubtitleJob? get job => current;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => latest;
  void changed({bool revisionOnly = false}) {
    if (revisionOnly) {
      subtitleFilesRevision.value++;
    } else {
      notifyListeners();
    }
  }
}

class _Asr extends TranscriptionManager {
  SubtitleStreamUpdate? latest;
  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      latest;
  @override
  bool isVideoRunning(String path, {String? videoId}) => true;
  @override
  bool isVideoStopping(String path, {String? videoId}) => false;
  @override
  TranscriptionAudioProgress get localAudioProgress =>
      const TranscriptionAudioProgress(
        completed: Duration(minutes: 9),
        total: Duration(minutes: 14),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const previews = bool.fromEnvironment('OCR_FOOTER_PREVIEWS');
  late _Library library;
  late _Ocr ocr;
  late _Asr asr;
  late MediaPlaybackService playback;
  late SubtitleCueBuffer chinese, english;
  final settings = SettingsService();
  const tracks = [
    OcrSubtitleTrack(
      number: 1,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.chinese,
      modelId: 'ppocr-v6-small',
    ),
    OcrSubtitleTrack(
      number: 2,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.english,
      modelId: 'ppocr-v6-small',
    ),
  ];
  OcrSubtitleJob job({
    OcrSubtitleJobStatus status = OcrSubtitleJobStatus.recognizing,
    Duration first = const Duration(minutes: 3, seconds: 24),
    Duration second = const Duration(minutes: 5),
    bool counters = true,
  }) => OcrSubtitleJob(
    videoId: 'media',
    videoPath: '/media.mp4',
    tracks: tracks,
    start: const Duration(minutes: 2),
    end: const Duration(minutes: 14),
    status: status,
    recognitionProgress: counters
        ? OcrRecognitionProgress(
            total: const Duration(minutes: 12),
            completedByTrack: {1: first, 2: second},
          )
        : null,
  );
  SubtitleStreamUpdate stream({
    SubtitleStreamPhase phase = SubtitleStreamPhase.generating,
    bool englishFirst = false,
  }) => SubtitleStreamUpdate(
    generationId: 'ocr-generation:0',
    mediaKey: 'ocr:generation:0',
    videoId: 'media',
    videoPath: '/media.mp4',
    revision: 1,
    primaryPath: '/ocr.zh.srt',
    secondaryPath: '/ocr.en.srt',
    primary: englishFirst ? SubtitleCueBuffer().snapshot : chinese.snapshot,
    secondary: english.snapshot,
    addedPrimary: const [],
    addedSecondary: const [],
    primaryBytes: 100,
    secondaryBytes: 100,
    processedThrough: const Duration(minutes: 5, seconds: 24),
    phase: phase,
  );

  setUpAll(() async {
    if (previews) {
      for (final entry in {
        'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
        'Inter': 'assets/fonts/Inter-ExtraBold.otf',
        'MiSans': 'assets/fonts/MiSans-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({'autoScrollSubtitles': false});
    settings.resetForTest();
    await settings.init();
    library = _Library();
    ocr = _Ocr(library)..current = job();
    asr = _Asr();
    playback = MediaPlaybackService.forTesting();
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'media',
        path: '/media.mp4',
        title: '字幕识别',
        durationMs: 840000,
        lastUpdated: 0,
      ),
    );
    List<SubtitleItem> cues(String text) => [
      for (var i = 0; i < 2; i++)
        SubtitleItem(
          index: i + 1,
          startTime: Duration(seconds: 120 + i * 5),
          endTime: Duration(seconds: 124 + i * 5),
          text: '$text ${i + 1}',
        ),
    ];
    chinese = SubtitleCueBuffer()..addAll(cues('这是正在识别的中文字幕'));
    english = SubtitleCueBuffer()..addAll(cues('This is the English subtitle'));
    ocr.latest = [stream()];
    playback.setSubtitleState(
      paths: ocr.latest.single.paths,
      primary: chinese.snapshot,
      secondary: english.snapshot,
    );
  });
  tearDown(() {
    playback.dispose();
    ocr.dispose();
    asr.dispose();
    library.dispose();
    settings.resetForTest();
  });
  Widget app(
    Widget body, {
    TargetPlatform platform = TargetPlatform.windows,
    bool withAsr = false,
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
      ChangeNotifierProvider<OcrSubtitleManager>.value(value: ocr),
      if (withAsr)
        ChangeNotifierProvider<TranscriptionManager>.value(value: asr),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        platform: platform,
        fontFamily: previews ? 'Noto Sans SC' : null,
      ),
      home: Scaffold(backgroundColor: const Color(0xFF282E3A), body: body),
    ),
  );
  Widget footer({bool showPrimary = true, bool showSecondary = true}) =>
      SubtitleGenerationFooter(
        primary: playback.subtitles,
        secondary: playback.secondarySubtitles,
        showPrimary: showPrimary,
        showSecondary: showSecondary,
      );
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!previews) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.artifacts/ocr-footer-20261027/ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('OCR updates only its footer using relative, slower-region time', (
    tester,
  ) async {
    var parentBuilds = 0;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            parentBuilds++;
            expect(SubtitleGenerationFooter.availableIn(context), isTrue);
            return Column(children: [const Text('已生成的字幕'), footer()]);
          },
        ),
      ),
    );
    expect(find.text('正在识别字幕 · 03:24 / 12:00'), findsOneWidget);
    final builds = parentBuilds;
    final rectangle = tester.getRect(find.byType(SubtitleGenerationFooter));
    final label = tester.widget<StableWidthLabel>(
      find.byType(StableWidthLabel),
    );
    ocr.current = job(
      first: const Duration(minutes: 3, seconds: 24, milliseconds: 900),
    );
    ocr.changed();
    await tester.pump();
    expect(
      tester.widget<StableWidthLabel>(find.byType(StableWidthLabel)),
      same(label),
    );
    ocr.current = job(first: const Duration(minutes: 4, seconds: 10));
    ocr.changed();
    await tester.pump();
    expect(find.text('正在识别字幕 · 04:10 / 12:00'), findsOneWidget);
    expect(parentBuilds, builds);
    expect(tester.getRect(find.byType(SubtitleGenerationFooter)), rectangle);
    // A restored stream can supply coverage before live regional counters exist.
    ocr.current = job(counters: false);
    ocr.changed();
    await tester.pump();
    expect(find.text('正在识别字幕 · 03:24 / 12:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ocr.changed();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'visible OCR wins over an unrelated live ASR, including English first',
    (tester) async {
      asr.latest = SubtitleStreamUpdate(
        generationId: 'asr',
        mediaKey: 'asr',
        videoId: 'media',
        videoPath: '/media.mp4',
        revision: 1,
        primaryPath: '/asr.srt',
        secondaryPath: null,
        primary: chinese.snapshot,
        secondary: SubtitleCueBuffer().snapshot,
        addedPrimary: const [],
        addedSecondary: const [],
        primaryBytes: 1,
        secondaryBytes: 0,
        processedThrough: const Duration(minutes: 9),
        phase: SubtitleStreamPhase.generating,
      );
      ocr.latest = [stream(englishFirst: true)];
      playback.setSubtitleState(
        paths: ocr.latest.single.paths,
        primary: const [],
        secondary: english.snapshot,
      );
      await tester.pumpWidget(app(footer(), withAsr: true));
      expect(find.text('正在识别字幕 · 03:24 / 12:00'), findsOneWidget);
      expect(find.textContaining('正在转录'), findsNothing);
      await tester.pumpWidget(app(footer(showSecondary: false), withAsr: true));
      expect(find.textContaining('正在识别字幕'), findsNothing);
      await tester.pumpWidget(app(footer(showPrimary: false), withAsr: true));
      expect(find.textContaining('正在识别字幕'), findsOneWidget);
      playback.setSubtitleState(
        paths: ['/manual.srt'],
        primary: english.snapshot,
        secondary: const [],
      );
      await tester.pump();
      expect(find.textContaining('正在识别字幕'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'OCR footer clears on stop, failure, completion and another media',
    (tester) async {
      await tester.pumpWidget(app(footer()));
      final rectangle = tester.getRect(find.byType(SubtitleGenerationFooter));
      for (final phase in [
        SubtitleStreamPhase.paused,
        SubtitleStreamPhase.failed,
        SubtitleStreamPhase.stopping,
        SubtitleStreamPhase.complete,
      ]) {
        ocr.latest = [stream(phase: phase)];
        ocr.changed(revisionOnly: true);
        await tester.pump();
        expect(find.textContaining('正在识别字幕'), findsNothing);
        expect(
          tester.getRect(find.byType(SubtitleGenerationFooter)),
          rectangle,
        );
      }
      ocr.latest = [stream()];
      for (final status in [
        OcrSubtitleJobStatus.cancelled,
        OcrSubtitleJobStatus.failed,
        OcrSubtitleJobStatus.interrupted,
        OcrSubtitleJobStatus.completed,
      ]) {
        ocr.current = job(status: status);
        ocr.changed();
        await tester.pump();
        expect(find.textContaining('正在识别字幕'), findsNothing);
      }
      ocr.current = job();
      playback.debugSeedCurrentItem(
        VideoItem(
          id: 'other',
          path: '/other.mp4',
          title: 'Other',
          durationMs: 10000,
          lastUpdated: 0,
        ),
      );
      ocr.changed();
      await tester.pump();
      expect(find.textContaining('正在识别字幕'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final mode in [0, 1, 2]) {
    testWidgets('OCR transcript uses the existing tail slot in mode $mode', (
      tester,
    ) async {
      await settings.updateSetting('subtitleViewMode', mode == 0 ? 0 : 1);
      await settings.updateSetting(
        'subtitleArticleParagraphModeEnabled',
        mode == 2,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        app(
          RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 380,
              height: 600,
              child: SubtitleSidebar(
                subtitles: chinese.snapshot,
                secondarySubtitles: english.snapshot,
                isCompact: true,
                isPortrait: true,
              ),
            ),
          ),
        ),
      );
      await frames(tester);
      expect(find.text('正在识别字幕 · 03:24 / 12:00'), findsOneWidget);
      final rect = tester.getRect(find.byType(SubtitleGenerationFooter));
      await capture(tester, key, 'transcript-$mode');
      ocr.current = job(first: const Duration(minutes: 4));
      ocr.changed();
      await tester.pump();
      expect(find.text('正在识别字幕 · 04:00 / 12:00'), findsOneWidget);
      expect(tester.getRect(find.byType(SubtitleGenerationFooter)), rect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.fuchsia,
  )) {
    testWidgets(
      'OCR music lyrics and selection share the footer on $platform',
      (tester) async {
        final mobile =
            platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS;
        await tester.binding.setSurfaceSize(
          mobile ? const Size(390, 844) : const Size(1000, 550),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final key = GlobalKey();
        await tester.pumpWidget(
          app(
            RepaintBoundary(
              key: key,
              child: MusicLyricRegion(
                mediaId: 'media',
                subtitles: chinese.snapshot,
                secondarySubtitles: english.snapshot,
                splitSubtitleByLine: false,
                preference: MusicLyricTrackDisplayMode.both,
                onPreferenceChanged: (_) {},
                isPlaying: false,
                applyEdgeFade: false,
              ),
            ),
            platform: platform,
          ),
        );
        await frames(tester);
        expect(find.text('正在识别字幕 · 03:24 / 12:00'), findsOneWidget);
        await capture(tester, key, 'music-${platform.name}');
        if (platform == TargetPlatform.android) {
          await tester.longPress(find.text('这是正在识别的中文字幕 1'));
          await frames(tester);
          expect(find.byType(MusicLyricSelectionPane), findsOneWidget);
          final controller = tester
              .widget<EditableText>(find.byType(EditableText))
              .controller;
          final selection = controller.selection, document = controller.text;
          ocr.current = job(first: const Duration(minutes: 4));
          ocr.changed();
          await tester.pump();
          expect(find.text('正在识别字幕 · 04:00 / 12:00'), findsOneWidget);
          expect(controller.selection, selection);
          expect(controller.text, document);
          ocr.latest = [stream(phase: SubtitleStreamPhase.complete)];
          ocr.changed(revisionOnly: true);
          await tester.pump();
          expect(find.textContaining('正在识别字幕'), findsNothing);
          expect(
            tester.getSize(find.byType(SubtitleGenerationFooter)).height,
            0,
          );
          expect(controller.selection, selection);
        } else {
          final rect = tester.getRect(find.byType(SubtitleGenerationFooter));
          ocr.latest = [stream(phase: SubtitleStreamPhase.complete)];
          ocr.changed(revisionOnly: true);
          await tester.pump();
          expect(find.textContaining('正在识别字幕'), findsNothing);
          expect(tester.getRect(find.byType(SubtitleGenerationFooter)), rect);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
