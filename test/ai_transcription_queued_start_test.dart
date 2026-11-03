import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';

class _Center extends ModelCenterService {
  final capture = Completer<ModelJobSpec>();
  @override
  bool get started => true;
  @override
  Future<ModelJobSpec> captureTranscription() => capture.future;
}

void main() {
  for (final translate in [false, true]) {
    testWidgets(
      'the media panel can first-start an imported task: translate=$translate',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 1200);
        addTearDown(tester.view.reset);
        final center = _Center();
        final manager = TranscriptionManager(modelCenter: center);
        addTearDown(() async {
          manager.pauseAllTasks();
          if (!center.capture.isCompleted) {
            center.capture.complete(
              const ModelJobSpec(profile: ModelCenterService.legacyProfile),
            );
          }
          await tester.runAsync(() async {
            for (var i = 0; i < 100 && manager.isQueueRunning; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          });
          manager.dispose();
          center.dispose();
        });
        await manager.startTranscription('old.m4a', videoId: 'old');
        await manager.startTranscription('selected.m4a', videoId: 'selected');
        expect(
          manager.isVideoAwaitingFirstStart(
            'selected.m4a',
            videoId: 'selected',
          ),
          isTrue,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 420,
                  child: ChangeNotifierProvider<TranscriptionManager>.value(
                    value: manager,
                    child: AiTranscriptionPanel(
                      videoPath: 'selected.m4a',
                      videoId: 'selected',
                      onCompleted: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ai-transcription-resume-card')),
          findsNothing,
        );
        final action = find.byKey(
          ValueKey(
            translate
                ? 'ai-transcription-translate-action'
                : 'ai-transcription-action',
          ),
        );
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();
        expect(manager.currentVideoId, 'selected');
        expect(
          manager.translateEnabledForVideo('selected.m4a', videoId: 'selected'),
          translate,
        );
        expect(manager.getQueueSnapshot().map((task) => task.mediaKey), [
          'id:selected',
          'id:old',
        ]);
        expect(
          manager.isVideoAwaitingFirstStart(
            'selected.m4a',
            videoId: 'selected',
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
        manager.pauseAllTasks();
        center.capture.complete(
          const ModelJobSpec(profile: ModelCenterService.legacyProfile),
        );
        await tester.pumpAndSettle();
        expect(manager.isQueueRunning, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
