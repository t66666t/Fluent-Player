import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';
import 'package:video_player_app/widgets/ocr_video_quality_field.dart';

const _qualities = [
  CacheQuality(id: '80', label: '1080P 高清', height: 1080),
  CacheQuality(id: '64', label: '720P 高清', height: 720),
  CacheQuality(id: '16', label: '360P 流畅', height: 360),
  CacheQuality(id: '120', label: '4K', height: 2160, available: false),
];

class _Library extends ChangeNotifier implements LibraryService {
  List<CacheQuality> choices = _qualities;
  final estimatedQualities = <String?>[];
  bool needsDownload = true;
  Object? discoveryError;

  @override
  Future<List<CacheQuality>> onlineVideoMaterializationQualities(
    String videoId,
  ) async {
    if (discoveryError != null) throw discoveryError!;
    return choices;
  }

  @override
  VideoItem? getVideo(String id) => null;

  @override
  Future<MediaMaterializationEstimate> estimateOnlineMediaMaterialization(
    String videoId,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    String? qualityId,
  }) async {
    estimatedQualities.add(qualityId);
    final choice = choices.firstWhere((q) => q.id == qualityId);
    return MediaMaterializationEstimate(
      estimatedBytes: needsDownload ? 400000 : 0,
      qualityId: int.tryParse(choice.id),
      width: null,
      height: choice.height,
      qualityLabel: choice.label,
      alreadyAvailable: !needsDownload,
      requiresVideoDownload: needsDownload,
      requiresAudioDownload: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Manager extends OcrSubtitleManager {
  _Manager(LibraryService library) : super(library: library);
  OcrSubtitleJob? started;
  bool legacyResume = false;
  Completer<void>? startGate;
  final capturedQualities = <String?>[];
  @override
  Future<void> initialize() async {}
  @override
  bool canResumeConfiguration({
    required String videoId,
    required List<OcrSubtitleTrack> tracks,
    required Duration start,
    required Duration end,
    required bool mirrorHorizontal,
    required bool mirrorVertical,
    String? videoQualityId,
  }) => legacyResume && videoQualityId == null;
  @override
  List<OcrSubtitleTrack> tracksForVideo(String id) => const [
    OcrSubtitleTrack(
      number: 1,
      region: NormalizedOcrRegion.subtitleDefault(),
      language: OcrSubtitleLanguage.chinese,
      modelId: 'ppocr-v6-small',
    ),
  ];
  @override
  Future<bool> isTrackModelInstalled(OcrSubtitleTrack track) async => true;
  @override
  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    List<OcrSubtitleTrack>? tracks,
    String? videoId,
  }) async => const Duration(minutes: 1);
  @override
  Future<void> start(OcrSubtitleJob request) async {
    started = request;
    await startGate?.future;
  }

  @override
  Future<String> captureFrame({
    required String videoId,
    required String videoPath,
    required Duration position,
    bool mirrorHorizontal = false,
    bool mirrorVertical = false,
    int? maxWidth,
    bool fastPreview = false,
    String? videoQualityId,
    void Function(MediaMaterializationProgress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    capturedQualities.add(videoQualityId);
    throw StateError('frame probe completed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const previews = bool.fromEnvironment('OCR_QUALITY_PREVIEWS');
  setUpAll(() async {
    if (previews) {
      await (FontLoader(
            'Noto Sans SC',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
  });
  late _Library library;
  late _Manager manager;
  late MediaMaterializationService materialization;
  setUp(() {
    library = _Library();
    manager = _Manager(library);
    materialization = MediaMaterializationService(BilibiliApiService());
  });
  tearDown(() {
    manager.dispose();
    materialization.dispose();
    library.dispose();
  });

  Future<void> openPanel(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double? width,
    VideoItem? item,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
          ChangeNotifierProvider<MediaMaterializationService>.value(
            value: materialization,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: previews ? 'Noto Sans SC' : null,
            ),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('quality-preview'),
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: width,
                  child: OcrSubtitlePanel(
                    videoItem:
                        item ??
                        VideoItem(
                          id: 'online',
                          path: 'bilibili://stream/BVtest/1',
                          title: 'Online',
                          durationMs: 600000,
                          lastUpdated: 0,
                          sourceRef: const MediaSourceRef(
                            kind: MediaSourceKind.bilibiliStream,
                            value: 'BVtest',
                            bvid: 'BVtest',
                            cid: 1,
                          ),
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
    await tester.pumpAndSettle();
  }

  Future<void> selectLow(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('ocr-video-quality')));
    await tester.pumpAndSettle();
    expect(find.text('4K'), findsNothing);
    await tester.tap(find.text('360P 流畅').last);
    await tester.pumpAndSettle();
  }

  testWidgets('chosen quality reaches confirmation and the frozen OCR job', (
    tester,
  ) async {
    await openPanel(tester);
    expect(find.text('1080P 高清'), findsOneWidget);
    await selectLow(tester);
    await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
    await tester.pumpAndSettle();
    expect(find.textContaining('360P 流畅 视频轨'), findsOneWidget);
    await tester.tap(find.text('下载并继续'));
    await tester.pumpAndSettle();
    expect(library.estimatedQualities, ['16']);
    expect(manager.started?.videoQualityId, '16');
    expect(manager.started?.copyWith(progress: 0.5).videoQualityId, '16');
    expect(manager.videoQualityFor('online'), '16');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'region preview uses chosen quality and reuses cached material without a dialog',
    (tester) async {
      library.needsDownload = false;
      await openPanel(tester);
      await selectLow(tester);
      final select = find.text('精确框选字幕区域');
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('需要下载 OCR 视频素材'), findsNothing);
      expect(manager.capturedQualities, ['16']);
      expect(library.estimatedQualities, ['16']);
      expect(manager.started, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material controls stay locked while the OCR request is starting',
    (tester) async {
      library.needsDownload = false;
      manager.startGate = Completer<void>();
      await openPanel(tester);
      await selectLow(tester);
      await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
      await tester.pump();
      final field = tester.widget<CapsuleDropdownButtonFormField<String>>(
        find.byKey(const ValueKey('ocr-video-quality')),
      );
      expect(field.onChanged, isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('ocr-pinned-start')),
            )
            .onPressed,
        isNull,
      );
      expect(manager.started!.videoQualityId, '16');
      final language = tester
          .widget<CapsuleDropdownButtonFormField<OcrSubtitleLanguage>>(
            find.byKey(const ValueKey('ocr_language_0_chinese')),
          );
      expect(language.onChanged, isNull);
      expect(
        () => manager.started!.tracks.add(manager.started!.tracks.first),
        throwsUnsupportedError,
      );
      manager.startGate!.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CapsuleDropdownButtonFormField<String>>(
              find.byKey(const ValueKey('ocr-video-quality')),
            )
            .onChanged,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening an interrupted legacy task preserves its material identity',
    (tester) async {
      library.needsDownload = false;
      manager.legacyResume = true;
      await openPanel(tester);
      expect(find.text('继续 OCR 识别'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
      await tester.pumpAndSettle();
      expect(manager.started, isNotNull);
      expect(manager.started!.videoQualityId, isNull);
      await selectLow(tester);
      expect(find.text('开始 OCR 识别'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
      await tester.pumpAndSettle();
      expect(manager.started!.videoQualityId, '16');
    },
  );

  testWidgets(
    'discovery errors can be retried and never start a default 1080P job',
    (tester) async {
      library.discoveryError = StateError('需要重新登录');
      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
      await tester.pumpAndSettle();
      expect(manager.started, isNull);
      expect(library.estimatedQualities, isEmpty);
      library.discoveryError = null;
      await tester.tap(find.text('重新获取画质'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ocr-video-quality')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('video podcast displays its single original representation', (
    tester,
  ) async {
    library.choices = const [CacheQuality(id: 'original', label: '播客原视频')];
    await openPanel(
      tester,
      item: VideoItem(
        id: 'podcast',
        path: 'podcast:episode',
        title: 'Video podcast',
        durationMs: 600000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          kind: MediaSourceKind.podcastEpisode,
          value: 'episode',
          podcast: PodcastEpisodeRef(
            channelId: 'feed',
            feedUrl: 'https://example.org/feed.xml',
            episodeId: 'episode',
            mediaUrl: 'https://example.org/video.mp4',
          ),
        ),
      ),
    );
    expect(find.text('来源仅提供原视频，无法选择其他画质。'), findsOneWidget);
    final field = tester.widget<CapsuleDropdownButtonFormField<String>>(
      find.byKey(const ValueKey('ocr-video-quality')),
    );
    expect(field.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final layout in [
    (name: 'portrait', size: const Size(390, 844), width: 390.0),
    (name: 'landscape', size: const Size(568, 320), width: 261.0),
  ]) {
    testWidgets('quality field and pinned action fit ${layout.name}', (
      tester,
    ) async {
      await openPanel(tester, size: layout.size, width: layout.width);
      final field = find.byKey(const ValueKey('ocr-video-quality'));
      final start = find.byKey(const ValueKey('ocr-pinned-start'));
      expect(
        tester.getRect(field).left,
        greaterThanOrEqualTo(layout.size.width - layout.width),
      );
      expect(tester.getRect(field).right, lessThanOrEqualTo(layout.size.width));
      expect(
        tester.getRect(start).bottom,
        lessThanOrEqualTo(layout.size.height),
      );
      expect(tester.takeException(), isNull);
      if (previews) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('quality-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('.artifacts/ocr-video-quality/${layout.name}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  test('initial quality respects saved choices and source resolution', () {
    final available = _qualities.where((q) => q.available).toList();
    expect(defaultOcrVideoQuality(available).id, '80');
    expect(defaultOcrVideoQuality(available, preferredId: '16').id, '16');
    expect(defaultOcrVideoQuality(available, preferredId: '120').id, '80');
    expect(
      defaultOcrVideoQuality([
        const CacheQuality(id: 'original', label: '原画'),
        ...available,
      ], preferOriginal: true).id,
      'original',
    );
  });
}
