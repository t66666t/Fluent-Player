import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/local_asr_progress.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'local_asr_progress_test.dart' show sample;

class _LocalTask extends TranscriptionManager {
  @override
  String get currentVideoPath => 'audio.wav';
  @override
  TranscriptionStatus get status => TranscriptionStatus.transcribing;
  @override
  double get progress => .5;
  @override
  String get statusMessage => '正在精校时间轴 · 3 / 8 段';
  @override
  LocalAsrProgress get localAsrProgress => sample();
  @override
  bool isVideoRunning(String videoPath, {String? videoId}) => true;
}

void main() {
  for (final width in [320.0, 420.0]) {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets('local task panel fits $width $brightness at large text', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final manager = _LocalTask();
        addTearDown(manager.dispose);
        const previews = bool.fromEnvironment('ASR_PROGRESS_PREVIEW');
        if (previews) {
          final font = FontLoader(
            'ProgressPreview',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
          final icons = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await tester.runAsync(font.load);
          await tester.runAsync(icons.load);
        }
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: brightness,
              useMaterial3: true,
              fontFamily: previews ? 'ProgressPreview' : null,
            ),
            home: RepaintBoundary(
              key: const ValueKey('asr-progress-preview'),
              child: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: const TextScaler.linear(1.3),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ChangeNotifierProvider<TranscriptionManager>.value(
                      value: manager,
                      child: AiTranscriptionPanel(
                        videoPath: 'audio.wav',
                        onCompleted: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('识别 05:00 / 10:00'), findsOneWidget);
        expect(find.text('增强 04:00 / 10:00'), findsOneWidget);
        expect(find.text('总进度 50%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (previews) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('asr-progress-preview')),
          );
          await tester.runAsync(() async {
            final bitmap = await boundary.toImage();
            try {
              final bytes = await bitmap.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '.artifacts/model-center/progress-${width.round()}-${brightness.name}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              bitmap.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
