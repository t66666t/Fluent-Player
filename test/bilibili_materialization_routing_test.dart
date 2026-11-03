import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Bilibili local-file features route through materialization leases', () {
    final compose = File(
      'lib/services/video_compose_manager.dart',
    ).readAsStringSync();
    final ocr = File(
      'lib/services/ocr_subtitle_manager.dart',
    ).readAsStringSync();
    final transcription = File(
      'lib/services/transcription_manager.dart',
    ).readAsStringSync();

    expect(compose, contains('MediaMaterializationRequirement.completeMedia'));
    expect(compose, contains('request: effectiveRequest'));
    expect(ocr, contains('MediaMaterializationRequirement.videoFrames'));
    expect(ocr, contains('videoPath: materializedLease.requiredVideoPath'));
    expect(
      transcription,
      contains('MediaMaterializationRequirement.audioOnly'),
    );
    expect(
      transcription,
      contains('transcriptionMediaPath = materializedLease.requiredAudioPath'),
    );
  });

  test('OCR and compose pages expose materialization progress in place', () {
    final ocrPanel = File(
      'lib/widgets/ocr_subtitle_panel.dart',
    ).readAsStringSync();
    final composePanel = File(
      'lib/widgets/video_compose_panel.dart',
    ).readAsStringSync();
    final progressCard = File(
      'lib/widgets/media_materialization_progress_card.dart',
    ).readAsStringSync();

    expect(ocrPanel, contains('MediaMaterializationProgressCard'));
    expect(ocrPanel, contains('onProgress: online'));
    expect(composePanel, contains('MediaMaterializationProgressCard'));
    expect(composePanel, contains('materializationProgressForTask'));
    expect(progressCard, contains('value.totalBytes'));
    expect(progressCard, contains('value.bytesPerSecond'));
    expect(progressCard, contains('value.remaining'));
  });

  test(
    'non-applicable local-container operations guard online URI markers',
    () {
      final landscape = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      final portrait = File(
        'lib/screens/portrait_video_screen.dart',
      ).readAsStringSync();
      final subtitleSheet = File(
        'lib/widgets/subtitle_management_sheet.dart',
      ).readAsStringSync();

      expect(landscape, contains("path.startsWith('bilibili://stream/')"));
      expect(landscape, contains('在线视频不适用“修复原文件”'));
      expect(portrait, contains("path.startsWith('bilibili://stream/')"));
      expect(
        subtitleSheet,
        contains("widget.videoPath.startsWith('bilibili://stream/')"),
      );
    },
  );
}
