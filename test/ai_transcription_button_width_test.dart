import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';
import 'package:video_player_app/widgets/model_center_button.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/transcription_task_configuration.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';

/// AI 转录面板的操作按钮：所有状态文案参与定宽，切换状态时图标和文字不跳。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'translation mode owns its recognition stage before translation starts',
    (tester) async {
      final manager = _StoppableManager(true)..translationStage = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<TranscriptionManager>.value(
              value: manager,
              child: AiTranscriptionPanel(
                videoPath: 'podcast.mp3',
                videoId: 'episode',
                onCompleted: (_) {},
              ),
            ),
          ),
        ),
      );
      final transcription = tester.widget<ElevatedButton>(
        find.byKey(const ValueKey('ai-transcription-action')),
      );
      expect(transcription.onPressed, isNull);
      expect(find.text('转录中 · 点击暂停'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('ai-transcription-translate-action')),
      );
      await tester.pump();
      expect(manager.stopCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
    },
  );

  for (final (size, width) in [
    (const Size(320, 568), 320.0),
    (const Size(390, 844), 390.0),
    (const Size(844, 390), 310.0),
    (const Size(1440, 900), 420.0),
  ]) {
    for (final translate in [false, true]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets(
          'stopped mode $translate fits $size, panel $width, text $scale',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            if (const bool.fromEnvironment('AI_TASK_PREVIEWS')) {
              await tester.runAsync(() async {
                for (final font in {
                  'MiSans': 'assets/fonts/MiSans-Regular.otf',
                  'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
                }.entries) {
                  await (FontLoader(
                    font.key,
                  )..addFont(rootBundle.load(font.value))).load();
                }
              });
            }
            final center = _EditableCenter();
            final manager = _StoppableManager(translate, center: center)
              ..finishStopping();
            final capture = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: Brightness.dark,
                  fontFamily: 'MiSans',
                  useMaterial3: true,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: RepaintBoundary(
                        key: capture,
                        child:
                            ChangeNotifierProvider<TranscriptionManager>.value(
                              value: manager,
                              child: AiTranscriptionPanel(
                                videoPath: 'podcast.mp3',
                                videoId: 'episode',
                                onCompleted: (_) {},
                              ),
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('ai-transcription-settings-changed')),
              findsNothing,
            );
            center.changeLanguage('en');
            await tester.pumpAndSettle();
            final card = find.byKey(
              const ValueKey('ai-transcription-resume-card'),
            );
            await tester.scrollUntilVisible(
              card,
              80,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              find.text(translate ? '转录并翻译 · 已停止' : '转录 · 已停止'),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('ai-transcription-settings-changed')),
              findsOneWidget,
            );
            final resume = find.byKey(
              ValueKey(
                translate
                    ? 'ai-transcription-translate-action'
                    : 'ai-transcription-action',
              ),
            );
            final restart = find.byKey(
              const ValueKey('ai-transcription-restart'),
            );
            final primary = tester.getRect(resume),
                secondary = tester.getRect(restart);
            expect(primary.overlaps(secondary), isFalse);
            expect(primary.width, greaterThan(120));
            expect(primary.right, lessThanOrEqualTo(width));
            expect(secondary.right, lessThanOrEqualTo(width));

            if (const bool.fromEnvironment('AI_TASK_PREVIEWS')) {
              final boundary =
                  capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 1.5);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/ai_task_previews/task-${size.width}-$width-$translate-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            final saved = find.byKey(
              const ValueKey('ai-transcription-saved-configuration'),
            );
            await tester.ensureVisible(saved);
            await tester.tap(saved);
            await tester.pumpAndSettle();
            expect(find.text('上次任务配置'), findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.textContaining('测试语音接口'),
              ),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('关闭'));
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox.shrink());
            manager.dispose();
            center.dispose();
          },
        );
      }
    }
  }

  testWidgets(
    'language edits update the hint but continuing never captures latest translation settings',
    (tester) async {
      final center = _EditableCenter();
      final settings = SubtitleTranslateSettings(
        modelCenter: center,
        readApiSettings: () async => const AiSubtitleApiSettings(),
      );
      await settings.ensureLoaded();
      final manager = _StoppableManager(true, center: center)
        ..savedTranslation = TranscriptTranslateChoice.current(settings)
        ..finishStopping();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<TranscriptionManager>.value(
                  value: manager,
                ),
                ChangeNotifierProvider<SubtitleTranslateSettings>.value(
                  value: settings,
                ),
              ],
              child: AiTranscriptionPanel(
                videoPath: 'podcast.mp3',
                videoId: 'episode',
                onCompleted: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-transcription-settings-changed')),
        findsNothing,
      );
      await settings.setDirection(TranscriptTranslateDirection.toEnglish);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-transcription-settings-changed')),
        findsOneWidget,
      );
      // An incomplete new AI configuration must not prevent resuming the saved task.
      await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      await tester.pumpAndSettle();
      final resume = find.byKey(
        const ValueKey('ai-transcription-translate-action'),
      );
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pump();
      expect(manager.resumedId, 'episode');
      expect(manager.restartCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
      settings.dispose();
      center.dispose();
    },
  );

  for (final translating in [false, true]) {
    testWidgets(
      'running ${translating ? 'translation' : 'transcription'} button stops only this media and can resume',
      (tester) async {
        final manager = _StoppableManager(translating);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
                child: AiTranscriptionPanel(
                  videoPath: 'podcast.mp3',
                  videoId: 'episode',
                  onCompleted: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final button = find.byKey(
          ValueKey(
            translating
                ? 'ai-transcription-translate-action'
                : 'ai-transcription-action',
          ),
        );
        await tester.tap(button);
        await tester.pump();
        expect(manager.stoppedPath, 'podcast.mp3');
        expect(manager.stoppedId, 'episode');
        expect(find.text('正在暂停...'), findsOneWidget);
        await tester.tap(button, warnIfMissed: false);
        expect(manager.stopCalls, 1);
        manager.finishStopping();
        await tester.pump();
        expect(find.text('继续上次任务'), findsOneWidget);
        expect(find.text('沿用上次配置'), findsOneWidget);
        expect(find.text('使用当前配置'), findsOneWidget);
        final other = find.byKey(
          ValueKey(
            translating
                ? 'ai-transcription-action'
                : 'ai-transcription-translate-action',
          ),
        );
        await tester.scrollUntilVisible(
          other,
          80,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(other, warnIfMissed: false);
        expect(manager.resumedId, isNull);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        expect(manager.resumedId, 'episode');
        expect(manager.paused, isFalse);
        expect(manager.resumedTranslation, translating);
        await tester.pumpWidget(const SizedBox());
        manager.dispose();
      },
    );
  }

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    for (final translate in [false, true]) {
      for (final phase in ['running', 'queued', 'paused', 'failed']) {
        testWidgets('cancel $translate $phase beside its action at $size', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final manager = _StoppableManager(translate)
            ..running = phase == 'running'
            ..queued = phase == 'queued'
            ..paused = phase == 'paused'
            ..failed = phase == 'failed';
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: size.width < 400 ? size.width : 420,
                    child: ChangeNotifierProvider<TranscriptionManager>.value(
                      value: manager,
                      child: AiTranscriptionPanel(
                        videoPath: 'podcast.mp3',
                        videoId: 'episode',
                        onCompleted: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final cancel = find.byKey(const ValueKey('ai-transcription-cancel'));
          final action = find.byKey(
            ValueKey(
              translate
                  ? 'ai-transcription-translate-action'
                  : 'ai-transcription-action',
            ),
          );
          await tester.ensureVisible(cancel);
          await tester.pump(const Duration(milliseconds: 300));
          final mainRect = tester.getRect(action);
          final cancelRect = tester.getRect(cancel);
          expect(cancelRect.left, greaterThan(mainRect.right));
          expect(cancelRect.center.dy, closeTo(mainRect.center.dy, 1));
          expect(
            cancelRect.right,
            lessThanOrEqualTo(size.width < 400 ? size.width : 420),
          );
          expect(find.byTooltip('取消任务'), findsOneWidget);
          await tester.tap(cancel);
          await tester.pump();
          expect(manager.cancelCalls, 1);
          expect(manager.cancelledPath, 'podcast.mp3');
          expect(manager.cancelledId, 'episode');
          expect(find.text('正在取消...'), findsOneWidget);
          expect(tester.widget<IconButton>(cancel).onPressed, isNull);
          manager.finishCancelling();
          await tester.pump();
          expect(cancel, findsNothing);
          expect(find.text('开始语音转录'), findsOneWidget);
          expect(find.text('转录并翻译'), findsOneWidget);
          expect(manager.stopCalls, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          manager.dispose();
        });
      }
    }
  }

  if (const bool.fromEnvironment('AI_TASK_PREVIEWS')) {
    for (final (name, size, width) in [
      ('small', const Size(320, 568), 320.0),
      ('large', const Size(1440, 900), 420.0),
    ]) {
      testWidgets('render cancel button preview $name', (tester) async {
        final height = size.height;
        tester.view.physicalSize = Size(width * 2 + 16, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          for (final font in {
            'MiSans': 'assets/fonts/MiSans-Regular.otf',
            'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load();
          }
        });
        final managers = [_PreviewManager(false), _PreviewManager(true)];
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'MiSans',
              useMaterial3: true,
            ),
            home: Scaffold(
              backgroundColor: const Color(0xFF101010),
              body: RepaintBoundary(
                key: capture,
                child: Row(
                  children: [
                    for (var i = 0; i < managers.length; i++) ...[
                      if (i > 0) const SizedBox(width: 16),
                      SizedBox(
                        width: width,
                        child: MediaQuery(
                          data: MediaQueryData(size: size),
                          child:
                              ChangeNotifierProvider<
                                TranscriptionManager
                              >.value(
                                value: managers[i],
                                child: AiTranscriptionPanel(
                                  videoPath: 'podcast.mp3',
                                  videoId: 'episode',
                                  onCompleted: (_) {},
                                ),
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/ai_task_previews/cancel-$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        for (final manager in managers) {
          manager.dispose();
        }
      });
    }
  }

  for (final translate in [false, true]) {
    testWidgets(
      'failed task retries its existing progress (translate=$translate)',
      (tester) async {
        final manager = _StoppableManager(translate)
          ..running = false
          ..failed = true;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
                child: AiTranscriptionPanel(
                  videoPath: 'podcast.mp3',
                  videoId: 'episode',
                  onCompleted: (_) {},
                ),
              ),
            ),
          ),
        );
        expect(find.text('继续上次任务'), findsOneWidget);
        expect(
          find.text(translate ? '转录并翻译 · 处理失败' : '转录 · 处理失败'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-transcription-restart')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(
            ValueKey(
              translate
                  ? 'ai-transcription-translate-action'
                  : 'ai-transcription-action',
            ),
          ),
        );
        await tester.pump();
        expect(manager.retryCalls, 1);
        expect(manager.resumedTranslation, translate);
        expect(manager.restartCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        manager.dispose();
      },
    );
  }

  for (final translate in [false, true]) {
    testWidgets(
      'paused restart confirms before discarding progress (translate=$translate)',
      (tester) async {
        final manager = _StoppableManager(translate)..finishStopping();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
                child: AiTranscriptionPanel(
                  videoPath: 'podcast.mp3',
                  videoId: 'episode',
                  onCompleted: (_) {},
                ),
              ),
            ),
          ),
        );
        final restart = find.byKey(const ValueKey('ai-transcription-restart'));
        await tester.tap(restart);
        await tester.pumpAndSettle();
        expect(manager.restartCalls, 0);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(manager.paused, isTrue);
        await tester.tap(restart);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('transcription-restart-confirm')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(manager.restartCalls, 1);
        expect(manager.resumedTranslation, translate);
        expect(manager.resumedId, isNull);
        expect(manager.paused, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        manager.dispose();
      },
    );
  }

  testWidgets(
    'completed transcription keeps its actions without a success block',
    (tester) async {
      final manager = _CompletedManager();
      var applied = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<TranscriptionManager>.value(
              value: manager,
              child: AiTranscriptionPanel(
                videoPath: 'podcast.mp3',
                videoId: 'episode',
                onCompleted: (_) => applied++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(applied, 1);
      expect(find.text('处理完成'), findsNothing);
      expect(find.text('AI 字幕生成完成'), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-transcription-action')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
    },
  );

  testWidgets('转录按钮用固定宽度标签，并覆盖全部状态文案', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<TranscriptionManager>.value(
            value: TranscriptionManager(),
            child: SizedBox(
              width: 420,
              height: 640,
              child: AiTranscriptionPanel(
                videoPath: 'fake/video.mp4',
                onCompleted: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final button = find.ancestor(
      of: find.text('开始语音转录'),
      matching: find.byType(ElevatedButton),
    );
    expect(button, findsOneWidget);
    final label = tester.widget<StableWidthLabel>(
      find.descendant(of: button, matching: find.byType(StableWidthLabel)),
    );
    expect(
      label.variants,
      containsAll(<String>['开始语音转录', '加入队列', '已加入队列', '转录中...', '重新转录']),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('转录并翻译'), findsOneWidget);
    expect(find.byTooltip('翻译设置'), findsOneWidget);
    expect(find.byType(ModelCenterButton), findsOneWidget);
    expect(
      find.byKey(const ValueKey('translation-direction-summary')).hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('智能互译：中→英 / 其他→中'), findsOneWidget);
    expect(find.text('必应翻译'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

class _StoppableManager extends TranscriptionManager {
  factory _StoppableManager(bool translating, {ModelCenterService? center}) =>
      _StoppableManager._(translating, center ?? ModelCenterService());
  _StoppableManager._(this.translating, this.center)
    : savedModel = center.transcriptionConfiguration,
      savedTranslation = translating
          ? const TranscriptTranslateChoice.automatic()
          : const TranscriptTranslateChoice.off(),
      super(modelCenter: center);
  final ModelCenterService center;
  final ModelJobSpec savedModel;
  TranscriptTranslateChoice savedTranslation;
  final bool translating;
  bool translationStage = true;
  @override
  bool translateEnabledForVideo(String path, {String? videoId}) => translating;
  @override
  TranscriptionTaskConfiguration? configurationForVideo(
    String path, {
    String? videoId,
  }) => TranscriptionTaskConfiguration(
    transcription: savedModel,
    punctuation: SubtitlePunctuation.defaultValue,
    translation: savedTranslation,
  );
  bool running = true, stopping = false, paused = false, failed = false;
  bool queued = false, cancelling = false;
  int cancelCalls = 0;
  String? cancelledPath, cancelledId;
  final _cancelFinished = Completer<void>();
  int stopCalls = 0;
  String? stoppedPath, stoppedId, resumedId;
  bool? resumedTranslation;
  int restartCalls = 0;
  int retryCalls = 0;
  @override
  bool get isProcessing => running;
  @override
  String? get currentVideoPath => running ? 'podcast.mp3' : null;
  @override
  String? get currentVideoId => running ? 'episode' : null;
  @override
  TranscriptionStatus get status =>
      running ? TranscriptionStatus.transcribing : TranscriptionStatus.idle;
  @override
  bool isVideoRunning(String path, {String? videoId}) =>
      running && path == 'podcast.mp3' && videoId == 'episode';
  @override
  bool isVideoTranslating(String path, {String? videoId}) =>
      translating && translationStage && running;
  @override
  bool isVideoQueued(String path, {String? videoId}) => paused || queued;
  @override
  bool isVideoPaused(String path, {String? videoId}) => paused;
  @override
  bool isVideoFailed(String path, {String? videoId}) => failed;
  @override
  bool isVideoStopping(String path, {String? videoId}) => stopping;
  @override
  bool isVideoCancelling(String path, {String? videoId}) => cancelling;
  @override
  Future<bool> cancelVideo(String path, {String? videoId}) async {
    cancelCalls++;
    cancelledPath = path;
    cancelledId = videoId;
    cancelling = true;
    notifyListeners();
    await _cancelFinished.future;
    running = stopping = paused = failed = queued = cancelling = false;
    notifyListeners();
    return true;
  }

  void finishCancelling() => _cancelFinished.complete();
  @override
  bool pauseVideo(String path, {String? videoId}) {
    stopCalls++;
    stoppedPath = path;
    stoppedId = videoId;
    stopping = true;
    notifyListeners();
    return true;
  }

  void finishStopping() {
    running = stopping = false;
    paused = true;
    notifyListeners();
  }

  @override
  void resumeVideo(
    String path, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) {
    resumedId = videoId;
    expect(
      translateChoice,
      isNull,
      reason: 'Continue must not replace the saved configuration',
    );
    resumedTranslation = translateChoice?.enabled ?? translating;
    paused = false;
    running = true;
    notifyListeners();
  }

  @override
  bool restartVideo(
    String path, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) {
    restartCalls++;
    expect(path, 'podcast.mp3');
    expect(videoId, 'episode');
    resumedTranslation = translateChoice?.enabled ?? translating;
    paused = false;
    failed = false;
    running = true;
    notifyListeners();
    return true;
  }

  @override
  bool retryVideo(
    String path, {
    String? videoId,
    TranscriptTranslateChoice? translateChoice,
  }) {
    retryCalls++;
    expect(translateChoice, isNull);
    expect(path, 'podcast.mp3');
    expect(videoId, 'episode');
    resumedTranslation = translateChoice?.enabled ?? translating;
    failed = false;
    running = true;
    notifyListeners();
    return true;
  }
}

class _PreviewManager extends _StoppableManager {
  _PreviewManager(bool translate) : super._(translate, ModelCenterService());

  @override
  TranscriptionStatus get status => translating
      ? TranscriptionStatus.translating
      : TranscriptionStatus.transcribing;
  @override
  String get statusMessage => translating ? '正在翻译当前字幕批次' : '正在识别音频，字幕将持续生成';
  @override
  double get progress => 0.37;
  @override
  TranscriptionAudioProgress get localAudioProgress =>
      const TranscriptionAudioProgress(
        completed: Duration(minutes: 3, seconds: 24),
        total: Duration(minutes: 12),
      );
}

class _EditableCenter extends ModelCenterService {
  _EditableCenter() {
    loaded = true;
    // This fixture edits an actual language hint. The public service is
    // automatic-only and must not pretend a stale global language affects it.
    const profile = ModelServiceProfile(
      id: 'editable-api',
      name: '测试语音接口',
      kind: TranscriptionServiceKind.openai,
      endpoint: 'http://localhost:1234/v1/audio/transcriptions',
      model: 'fixture-asr',
    );
    profiles[profile.id] = profile;
    asrProfileId = profile.id;
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<void> save() async {}
  void changeLanguage(String value) {
    selectedLanguage = value;
    notifyListeners();
  }
}

class _CompletedManager extends TranscriptionManager {
  bool _delivered = false;
  @override
  TranscriptionStatus get status => TranscriptionStatus.completed;
  @override
  String? getGeneratedSrtPathForVideo(String path, {String? videoId}) =>
      'generated.srt';
  @override
  bool consumeResultNotificationForVideo(String path, {String? videoId}) {
    if (_delivered) return false;
    _delivered = true;
    return true;
  }
}
