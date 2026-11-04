import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_models_pane.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _QueueCenter extends ModelCenterService {
  _QueueCenter({required super.storage}) : super(secrets: _Secrets());
  final enqueued = <String>[];
  @override
  Future<void> enqueue(String id) async {
    enqueued.add(id);
    downloads[id] = ModelDownload(artifactId: id);
    notifyListeners();
  }

  void complete(String id) {
    downloads[id]!.phase = ModelDownloadPhase.installed;
    downloads[id]!.received = artifact(id)!.bytes;
    notifyListeners();
  }
}

class _PanelManager extends OcrSubtitleManager {
  _PanelManager({required super.modelManager, this.installedLegacy = false})
    : super(library: LibraryService());
  final bool installedLegacy;
  OcrSubtitleJob? started;
  @override
  Future<bool> isModelInstalled(OcrSubtitleLanguage language) =>
      installedLegacy ? Future.value(true) : super.isModelInstalled(language);
  @override
  Future<void> initialize() async {}
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
  Future<void> start(OcrSubtitleJob request) async => started = request;
}

class _JobManager extends OcrSubtitleManager {
  _JobManager({required super.modelManager}) : super(library: LibraryService());
  @override
  Future<void> initialize() async {}
}

const _track = OcrSubtitleTrack(
  number: 1,
  region: NormalizedOcrRegion.subtitleDefault(),
  language: OcrSubtitleLanguage.chinese,
  modelId: 'ppocr-v6-small',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _QueueCenter center;
  late OcrModelManager models;
  late AppStorageService previousStorage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ocr-model-flow-');
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory('${root.path}/support'),
        documents: Directory('${root.path}/documents'),
        defaultData: Directory('${root.path}/data'),
        executable: Directory('${root.path}/bin'),
      ),
    );
    await storage.initialize();
    previousStorage = AppStorageService.instance;
    AppStorageService.instance = storage;
    center = _QueueCenter(storage: storage);
    models = OcrModelManager(center: center, rootOverride: root);
    await models.initialize();
    await models.presets();
  });
  tearDown(() async {
    await center.shutdown();
    AppStorageService.instance = previousStorage;
    await root.delete(recursive: true);
  });

  Future<void> queued(int count) async {
    for (var i = 0; i < 100 && center.enqueued.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(center.enqueued, hasLength(count));
  }

  for (final (size, panelWidth, scale, installedLegacy) in [
    (const Size(320, 640), 320.0, 1.0, false),
    (const Size(568, 320), 261.0, 1.0, false),
    (const Size(1024, 768), 360.0, 1.0, false),
    (const Size(320, 640), 320.0, 2.0, false),
    (const Size(320, 640), 320.0, 1.0, true),
  ]) {
    testWidgets(
      'OCR model validation keeps layout and legacy reuse ($size x $scale, legacy $installedLegacy)',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final manager = _PanelManager(
          modelManager: models,
          installedLegacy: installedLegacy,
        );
        final materialization = MediaMaterializationService(
          BilibiliApiService(),
        );
        addTearDown(manager.dispose);
        addTearDown(materialization.dispose);
        manager.rememberTracks('model-validation', [
          _track.copyWith(modelId: ''),
          _track.copyWith(number: 2, modelId: ''),
        ]);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
              ChangeNotifierProvider<MediaMaterializationService>.value(
                value: materialization,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(),
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
                    width: panelWidth,
                    child: OcrSubtitlePanel(
                      videoItem: VideoItem(
                        id: 'model-validation',
                        path: 'local.mp4',
                        title: 'OCR',
                        durationMs: 60000,
                        lastUpdated: 0,
                      ),
                      duration: const Duration(minutes: 1),
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
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('ocr-model-choice-0_'));
        final secondField = find.byKey(const ValueKey('ocr-model-choice-1_'));
        final options = find.byKey(const PageStorageKey('ocr-options'));
        final scrollable = find
            .descendant(of: options, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        final firstY = tester.getTopLeft(field).dy + position.pixels;
        final secondY = tester.getTopLeft(secondField).dy + position.pixels;
        final fieldSize = tester.getSize(field);
        final footer = find.byKey(const ValueKey('ocr-pinned-task-action'));
        final footerRect = tester.getRect(footer);
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
        await tester.pumpAndSettle();
        if (installedLegacy) {
          expect(manager.started!.tracks.map((track) => track.modelId), [
            '',
            '',
          ]);
          expect(find.textContaining('未选模型'), findsNothing);
          expect(find.text('识别模型（必选）'), findsNothing);
          expect(tester.getRect(footer), footerRect);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          return;
        }
        expect(manager.started, isNull);
        expect(find.text('区域 1 未选模型'), findsOneWidget);
        expect(find.text('尚未开始识别'), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.getSize(field), fieldSize);
        expect(
          tester.getTopLeft(field).dy + position.pixels,
          closeTo(firstY, .01),
        );
        expect(
          tester.getTopLeft(secondField).dy + position.pixels,
          closeTo(secondY, .01),
        );
        expect(tester.getRect(footer), footerRect);
        final first = tester.widget<DropdownButtonFormField<String>>(field);
        expect(first.decoration.labelText, '识别模型（必选）');
        expect(first.decoration.errorText, isNull);
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.descendant(
                  of: field,
                  matching: find.byType(DropdownButton<String>),
                ),
              )
              .focusNode!
              .hasFocus,
          isTrue,
        );
        expect(tester.getRect(field).overlaps(tester.getRect(options)), isTrue);

        await tester.tap(field);
        await tester.pumpAndSettle();
        final model = find
            .byWidgetPredicate(
              (widget) =>
                  widget is DropdownMenuItem<String> &&
                  widget.value == 'ppocr-v6-small',
            )
            .last;
        await tester.ensureVisible(model);
        await tester.pumpAndSettle();
        await tester.tap(model);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.text('区域 2 未选模型'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ocr-model-choice-0_ppocr-v6-small')),
          findsOneWidget,
        );
        expect(manager.started, isNull);
        expect(tester.getRect(footer), footerRect);
        await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.descendant(
                  of: secondField,
                  matching: find.byType(DropdownButton<String>),
                ),
              )
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.tap(secondField);
        await tester.pumpAndSettle();
        final secondModel = find
            .byWidgetPredicate(
              (widget) =>
                  widget is DropdownMenuItem<String> &&
                  widget.value == 'ppocr-v6-small',
            )
            .last;
        await tester.ensureVisible(secondModel);
        await tester.pumpAndSettle();
        await tester.tap(secondModel);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.textContaining('未选模型'), findsNothing);
        expect(find.text('识别模型（必选）'), findsNothing);
        expect(tester.getRect(footer), footerRect);
        await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
        await tester.pumpAndSettle();
        expect(manager.started!.tracks.map((track) => track.modelId), [
          'ppocr-v6-small',
          'ppocr-v6-small',
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'model choices survive restart without replacing video or job tracks',
    () async {
      final manager = OcrSubtitleManager(
        library: LibraryService(),
        modelManager: models,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      expect(manager.tracksForVideo('new-video').single.modelId, isEmpty);
      final videoTrack = _track.copyWith(
        modelId: 'ppocr-v5-mobile',
        modelIdentity: 'video:pinned-revision',
        region: const NormalizedOcrRegion(
          left: .1,
          top: .8,
          right: .9,
          bottom: 1,
        ),
      );
      manager.rememberTracks('existing-video', [videoTrack]);
      await manager.rememberModelSelection(
        OcrSubtitleLanguage.chinese,
        'ppocr-v6-medium',
      );
      await manager.rememberModelSelection(
        OcrSubtitleLanguage.english,
        'ppocr-v5-en',
      );
      await manager.rememberModelSelection(
        OcrSubtitleLanguage.chinese,
        'ppocr-v6-small',
      );
      // Revisiting an older video's regions must not replace the latest choice.
      manager.rememberTracks('existing-video', [videoTrack]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ocrSubtitleActiveJobV1',
        jsonEncode({
          'videoId': 'job-video',
          'videoPath': 'job.mp4',
          'tracks': [videoTrack.toJson()],
          'status': 'interrupted',
          'startMs': 1000,
          'endMs': 5000,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      SharedPreferences.setMockInitialValues({
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      });
      final restored = OcrSubtitleManager(
        library: LibraryService(),
        modelManager: models,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      final defaultTrack = restored.tracksForVideo('new-video').single;
      expect(defaultTrack.modelId, 'ppocr-v6-small');
      expect(defaultTrack.modelIdentity, isEmpty);
      expect(defaultTrack.region.isSubtitleDefault, isTrue);
      expect(
        identical(defaultTrack, restored.tracksForVideo('new-video').single),
        isTrue,
      );
      expect(
        restored.rememberedModelIdFor(OcrSubtitleLanguage.english),
        'ppocr-v5-en',
      );
      expect(
        restored.rememberedModelIdFor(OcrSubtitleLanguage.japanese),
        isEmpty,
      );
      expect(
        restored.tracksForVideo('existing-video').single.toJson(),
        videoTrack.toJson(),
      );
      expect(
        restored.tracksForVideo('job-video').single.toJson(),
        videoTrack.toJson(),
      );
      expect(restored.job!.tracks.single.toJson(), videoTrack.toJson());
      expect(restored.job!.status, OcrSubtitleJobStatus.interrupted);
      expect(restored.job!.start, const Duration(seconds: 1));
      expect(restored.job!.end, const Duration(seconds: 5));
      expect(center.enqueued, isEmpty);

      await restored.rememberModelSelection(OcrSubtitleLanguage.chinese, '');
      final cleared = OcrSubtitleManager(
        library: LibraryService(),
        modelManager: models,
      );
      addTearDown(cleared.dispose);
      await cleared.initialize();
      expect(
        cleared.tracksForVideo('another-new-video').single.modelId,
        isEmpty,
      );
      expect(
        cleared.rememberedModelIdFor(OcrSubtitleLanguage.english),
        'ppocr-v5-en',
      );
      expect(
        cleared.tracksForVideo('existing-video').single.toJson(),
        videoTrack.toJson(),
      );
    },
  );

  test(
    'remembered model IDs migrate and reject incompatible entries',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ocrSubtitleModelSelectionsV1',
        jsonEncode({
          'chinese': 'ppocr-v6-tiny',
          'english': 'ppocr-v5-latin',
          'japanese': 'missing-model',
          'korean': 123,
          'latin': 'ppocr-v5-latin',
        }),
      );
      final manager = OcrSubtitleManager(
        library: LibraryService(),
        modelManager: models,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      expect(
        manager.tracksForVideo('new-video').single.modelId,
        'ppocr-v6-small',
      );
      expect(
        manager.rememberedModelIdFor(OcrSubtitleLanguage.english),
        isEmpty,
      );
      expect(
        manager.rememberedModelIdFor(OcrSubtitleLanguage.japanese),
        isEmpty,
      );
      expect(manager.rememberedModelIdFor(OcrSubtitleLanguage.korean), isEmpty);
      expect(
        manager.rememberedModelIdFor(OcrSubtitleLanguage.latin),
        'ppocr-v5-latin',
      );
      expect(jsonDecode(prefs.getString('ocrSubtitleModelSelectionsV1')!), {
        'chinese': 'ppocr-v6-small',
        'latin': 'ppocr-v5-latin',
      });
      expect(center.enqueued, isEmpty);
    },
  );

  for (final qualityId in [null, '16']) {
    test(
      'interrupted OCR restores material quality $qualityId without changing tracks',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'ocrSubtitleActiveJobV1',
          jsonEncode({
            'videoId': 'quality-job',
            'videoPath': 'bilibili://stream/BVtest/1',
            'tracks': [_track.toJson()],
            'status': 'materializing',
            'startMs': 1000,
            'endMs': 5000,
            'videoQualityId': ?qualityId,
          }),
        );
        final manager = OcrSubtitleManager(
          library: LibraryService(),
          modelManager: models,
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        expect(manager.job!.status, OcrSubtitleJobStatus.interrupted);
        expect(manager.job!.videoQualityId, qualityId);
        expect(manager.videoQualityFor('quality-job'), qualityId);
        expect(manager.job!.copyWith(progress: .5).videoQualityId, qualityId);
        expect(manager.job!.tracks.single.toJson(), _track.toJson());
      },
    );
  }

  test('corrupt model memory does not discard saved video tracks', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ocrSubtitleModelSelectionsV1', '{broken');
    await prefs.setString(
      'ocrSubtitleTracksV1',
      jsonEncode({
        'saved-video': [_track.toJson()],
      }),
    );
    final manager = OcrSubtitleManager(
      library: LibraryService(),
      modelManager: models,
    );
    addTearDown(manager.dispose);
    await manager.initialize();
    expect(
      manager.tracksForVideo('saved-video').single.toJson(),
      _track.toJson(),
    );
    expect(manager.tracksForVideo('new-video').single.modelId, isEmpty);
    expect(prefs.containsKey('ocrSubtitleModelSelectionsV1'), isFalse);
  });

  test(
    'retired Tiny selections migrate to Small without reusing its identity',
    () async {
      final retired = _track.copyWith(
        modelId: 'ppocr-v6-tiny',
        modelIdentity: 'tiny:pinned-old-revision',
        region: const NormalizedOcrRegion(
          left: .1,
          top: .8,
          right: .9,
          bottom: 1,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ocrSubtitleTracksV1',
        jsonEncode({
          'retired-video': [retired.toJson()],
        }),
      );
      final manager = OcrSubtitleManager(
        library: LibraryService(),
        modelManager: models,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      final selected = manager.tracksForVideo('retired-video').single;
      expect(selected.modelId, 'ppocr-v6-small');
      expect(selected.modelIdentity, isEmpty);
      expect(selected.region.toJson(), retired.region.toJson());
      final saved = jsonDecode(prefs.getString('ocrSubtitleTracksV1')!) as Map;
      expect(
        (saved['retired-video'] as List).single['modelId'],
        'ppocr-v6-small',
      );
      final resolved = await models.resolveTrackIdentity(retired);
      expect(resolved.modelId, 'ppocr-v6-small');
      expect(resolved.modelIdentity, startsWith('ppocr-v6-small:'));
      expect(
        manager.hasDurationMeasurements('retired-video', [selected]),
        isFalse,
      );
      await expectLater(models.preset('ppocr-v6-tiny'), throwsStateError);
      expect(center.enqueued, isEmpty);
    },
  );

  test(
    'downloads missing shared components once and waits until every model is ready',
    () async {
      final tracks = [
        await models.freeze(
          _track.copyWith(
            language: OcrSubtitleLanguage.english,
            modelId: 'ppocr-v5-en',
          ),
          requireInstalled: false,
        ),
        await models.freeze(
          _track.copyWith(
            number: 2,
            language: OcrSubtitleLanguage.korean,
            modelId: 'ppocr-v5-korean',
          ),
          requireInstalled: false,
        ),
      ];
      final progress = <double>[];
      var completed = false;
      final preparation = models
          .prepareTracks(tracks, onProgress: (value, _) => progress.add(value))
          .then((_) => completed = true);
      await queued(3);
      expect(center.enqueued.toSet(), {
        'ocr-v6-tiny-det',
        'ocr-en-v5-mobile-rec',
        'ocr-korean-v5-mobile-rec',
      });
      center.complete('ocr-v6-tiny-det');
      center.complete('ocr-en-v5-mobile-rec');
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      center.complete('ocr-korean-v5-mobile-rec');
      await preparation;
      expect(progress.last, 1);
      expect(completed, isTrue);
      await models.prepareTracks(tracks);
      expect(center.enqueued, hasLength(3));
    },
  );

  test(
    'cancellation ends the OCR wait promptly and preserves shared downloads',
    () async {
      final cancel = Completer<void>();
      final preparation = models.prepareTracks([
        _track,
      ], cancelSignal: cancel.future);
      final assertion = expectLater(
        preparation,
        throwsA(isA<OcrDownloadCancelled>()),
      );
      await queued(2);
      cancel.complete();
      await assertion.timeout(const Duration(seconds: 1));
      expect(
        center.downloads.values.every(
          (state) => state.phase == ModelDownloadPhase.queued,
        ),
        isTrue,
      );
      for (final id in center.enqueued) {
        center.complete(id);
      }
      await models.prepareTracks([_track]);
      expect(center.enqueued, hasLength(2));
    },
  );

  test(
    'download failures are reported and starting again resumes missing components',
    () async {
      final preparation = models.prepareTracks([_track]);
      final assertion = expectLater(preparation, throwsStateError);
      await queued(2);
      center.complete('ocr-v6-small-det');
      center.downloads['ocr-v6-small-rec']!
        ..phase = ModelDownloadPhase.failed
        ..message = '网络断开';
      center.notifyListeners();
      await assertion;
      final retry = models.prepareTracks([_track]);
      await queued(3);
      expect(center.enqueued.last, 'ocr-v6-small-rec');
      center.complete('ocr-v6-small-rec');
      await retry;
    },
  );

  for (final cancel in [true, false]) {
    test(
      'OCR ${cancel ? 'cancellation' : 'failure'} during download releases ready model leases',
      () async {
        final manager = _JobManager(modelManager: models);
        addTearDown(manager.dispose);
        await manager.setKeepScreenAwakeDuringProcessing(true);
        final task = manager.start(
          const OcrSubtitleJob(
            videoId: 'download-task',
            videoPath: 'local.mp4',
            tracks: [_track],
            start: Duration.zero,
            end: Duration(minutes: 1),
          ),
        );
        await queued(2);
        expect(manager.job!.status, OcrSubtitleJobStatus.downloading);
        expect(manager.processingKeepAwake.isActive, isTrue);
        expect(
          AppWakelockCoordinator.isReasonActive(
            AppWakelockCoordinator.ocrProcessingReason,
          ),
          isTrue,
        );
        center.complete('ocr-v6-small-det');
        await Future<void>.delayed(Duration.zero);
        expect(center.inUse('ocr-v6-small-det'), isTrue);
        if (cancel) {
          await manager.cancel();
        } else {
          center.downloads['ocr-v6-small-rec']!
            ..phase = ModelDownloadPhase.failed
            ..message = '网络断开';
          center.notifyListeners();
        }
        await task.timeout(const Duration(seconds: 1));
        expect(
          manager.job!.status,
          cancel ? OcrSubtitleJobStatus.cancelled : OcrSubtitleJobStatus.failed,
        );
        if (!cancel) expect(manager.job!.error, contains('网络断开'));
        expect(manager.processingKeepAwake.isActive, isFalse);
        expect(
          AppWakelockCoordinator.isReasonActive(
            AppWakelockCoordinator.ocrProcessingReason,
          ),
          isFalse,
        );
        expect(center.hasModelLeases, isFalse);
      },
    );
  }

  for (final (width, scale) in [(261.0, 1.3), (600.0, 1.0)]) {
    testWidgets(
      'region deletion preserves settings through model selection at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final manager = _PanelManager(modelManager: models);
        final materialization = MediaMaterializationService(
          BilibiliApiService(),
        );
        addTearDown(manager.dispose);
        addTearDown(materialization.dispose);
        await tester.runAsync(
          () => manager.rememberModelSelection(
            OcrSubtitleLanguage.english,
            'ppocr-v5-en',
          ),
        );
        final originalTracks = [
          _track.copyWith(modelId: ''),
          _track.copyWith(
            number: 2,
            region: const NormalizedOcrRegion(
              left: .1,
              top: .5,
              right: .9,
              bottom: .6,
            ),
            language: OcrSubtitleLanguage.english,
            modelId: 'ppocr-v5-en',
            modelIdentity: 'english-model-identity',
          ),
          _track.copyWith(
            number: 3,
            region: const NormalizedOcrRegion(
              left: .1,
              top: .2,
              right: .9,
              bottom: .3,
            ),
            language: OcrSubtitleLanguage.korean,
            modelId: 'ppocr-v5-korean',
            modelIdentity: 'korean-model-identity',
          ),
        ];
        manager.rememberTracks('model-flow', originalTracks);
        await tester.pumpWidget(
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
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: OcrSubtitlePanel(
                  videoItem: VideoItem(
                    id: 'model-flow',
                    path: 'local.mp4',
                    title: 'OCR',
                    durationMs: 60000,
                    lastUpdated: 0,
                  ),
                  duration: const Duration(minutes: 1),
                  currentPosition: () => Duration.zero,
                  pauseForRegionSelection: () async => false,
                  restorePlayback: (_) async {},
                  onBack: () {},
                  onCompleted: (_) async {},
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        final deleteMiddle = find.byKey(const ValueKey('ocr-delete-region-1'));
        await tester.ensureVisible(deleteMiddle);
        await tester.pumpAndSettle();
        await tester.tap(deleteMiddle);
        await tester.pumpAndSettle();
        final remainingTracks = [
          originalTracks[0].toJson(),
          originalTracks[2].copyWith(number: 2).toJson(),
        ];
        expect(
          manager.tracksForVideo('model-flow').map((track) => track.toJson()),
          remainingTracks,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          (jsonDecode(prefs.getString('ocrSubtitleTracksV1')!)
              as Map)['model-flow'],
          remainingTracks,
        );
        manager.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ocr_language_1_korean')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ocr_language_2_korean')),
          findsNothing,
        );
        final selector = find.byKey(const ValueKey('ocr-model-choice-0_'));
        await tester.ensureVisible(selector);
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        const targetId = 'ppocr-v5-mobile';
        final menuInfo = find.byKey(
          const ValueKey('ocr-model-info-0-$targetId-menu'),
        );
        await tester.ensureVisible(menuInfo);
        await tester.pumpAndSettle();
        await tester.tap(menuInfo);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<OcrModelsPane>(find.byType(OcrModelsPane)).focusModelId,
          targetId,
        );
        final details = tester.widget<ExpansionTile>(
          find.byKey(const PageStorageKey('ocr-model-details-$targetId')),
        );
        expect(details.controller!.isExpanded, isTrue);
        final title = find.text('PP-OCRv5 Mobile');
        expect(tester.getTopLeft(title).dy, greaterThan(0));
        expect(tester.getBottomLeft(title).dy, lessThan(800));
        expect(center.enqueued, isEmpty);
        expect(manager.tracksForVideo('model-flow').first.modelId, isEmpty);

        final choose = find.descendant(
          of: find.byKey(const ValueKey('ocr-model-$targetId')),
          matching: find.widgetWithText(OutlinedButton, '选择此模型'),
        );
        await tester.ensureVisible(choose);
        await tester.pumpAndSettle();
        await tester.tap(choose);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(manager.tracksForVideo('model-flow').first.modelId, targetId);
        expect(
          manager.rememberedModelIdFor(OcrSubtitleLanguage.chinese),
          targetId,
        );
        expect(manager.tracksForVideo('next-video').single.modelId, targetId);
        expect(center.enqueued, isEmpty);

        final selectedInfo = find.byKey(
          const ValueKey('ocr-model-info-0-$targetId'),
        );
        await tester.ensureVisible(selectedInfo);
        await tester.pumpAndSettle();
        await tester.tap(selectedInfo);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<OcrModelsPane>(find.byType(OcrModelsPane)).focusModelId,
          targetId,
        );
        await tester.tap(find.byKey(const ValueKey('ocr-tab-recognition')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ocr-pinned-start')));
        await tester.pumpAndSettle();
        expect(manager.started!.tracks.first.modelId, targetId);
        expect(manager.started!.tracks[1].toJson(), remainingTracks[1]);
        expect(find.byType(OcrModelsPane), findsNothing);

        final selectedDropdown = find.byKey(
          const ValueKey('ocr-model-choice-0_$targetId'),
        );
        await tester.ensureVisible(selectedDropdown);
        await tester.pumpAndSettle();
        await tester.tap(selectedDropdown);
        await tester.pumpAndSettle();
        final medium = find
            .byWidgetPredicate(
              (widget) =>
                  widget is DropdownMenuItem<String> &&
                  widget.value == 'ppocr-v6-medium',
            )
            .last;
        await tester.ensureVisible(medium);
        await tester.pumpAndSettle();
        await tester.tap(medium);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(
          manager.rememberedModelIdFor(OcrSubtitleLanguage.chinese),
          'ppocr-v6-medium',
        );
        expect(
          manager.tracksForVideo('next-video').single.modelId,
          'ppocr-v6-medium',
        );

        for (final (from, to, expectedModel) in [
          (
            OcrSubtitleLanguage.chinese,
            OcrSubtitleLanguage.english,
            'ppocr-v5-en',
          ),
          (
            OcrSubtitleLanguage.english,
            OcrSubtitleLanguage.chinese,
            'ppocr-v6-medium',
          ),
        ]) {
          final language = find.byKey(ValueKey('ocr_language_0_${from.name}'));
          await tester.ensureVisible(language);
          await tester.pumpAndSettle();
          await tester.tap(language);
          await tester.pumpAndSettle();
          await tester.tap(find.text(to.label).last);
          await tester.pumpAndSettle();
          expect(
            manager.tracksForVideo('model-flow').first.modelId,
            expectedModel,
          );
          expect(
            find.byKey(ValueKey('ocr-model-choice-0_$expectedModel')),
            findsOneWidget,
          );
        }
        expect(center.enqueued, isEmpty);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      timeout: const Timeout(Duration(seconds: 35)),
    );
  }
}
