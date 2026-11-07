import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_processing.dart';
import 'package:video_player_app/features/model_center/cohere_asr_runtime.dart';
import 'package:video_player_app/features/model_center/local_asr_model_adapter.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'support/cohere_candidate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'overlong VAD speech is bounded at an acoustic pause without losing samples',
    () {
      final audio = Float32List(20 * 16000)..fillRange(0, 20 * 16000, .25);
      audio.fillRange(7 * 16000, 7 * 16000 + 640, 0);
      final pieces = splitCohereSpeechRanges([
        (start: 0, end: audio.length),
      ], audio);
      expect(pieces.first.end, inInclusiveRange(7 * 16000, 7 * 16000 + 640));
      expect(pieces.first.start, 0);
      expect(pieces.last.end, audio.length);
      for (var i = 0; i < pieces.length; i++) {
        expect(pieces[i].end - pieces[i].start, lessThanOrEqualTo(120000));
        if (i > 0) expect(pieces[i].start, pieces[i - 1].end);
      }
    },
  );
  test(
    'Cohere has a dedicated loader and disclosed Japanese alignment bundle',
    () async {
      final center = ModelCenterService()
        ..catalog = [...await loadModelCatalog(), cohereComparisonCandidate()];
      try {
        final model = center.artifact('cohere-transcribe-03-2026-q8')!;
        final adapter = localAsrAdapter(model.engine);
        expect(adapter.architecture, LocalAsrArchitecture.cohereAsr);
        expect(adapter.supportsHotwords, isFalse);
        expect(
          () => localOfflineAsrConfiguration(
            engine: model.engine,
            directory: '',
            language: 'ja',
            threads: 2,
          ),
          throwsArgumentError,
        );
        center.selectedLanguage = 'ja';
        expect(
          center.asrDownloadComponents(model).map((m) => m.id),
          containsAll([
            model.id,
            AsrEnhancementOptions.denoiserId,
            AsrEnhancementOptions.alignmentQwenId,
          ]),
        );
        expect(
          center.asrEnhancementArtifacts(model).map((m) => m.id),
          isNot(contains(AsrEnhancementOptions.alignmentChineseId)),
        );
        final cue = SubtitleItem(
          index: 0,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
          text: '日本語',
          asrInfo: const SubtitleAsrInfo(language: 'ja'),
        );
        expect(
          asrAlignmentModelId(
            cue,
            'auto',
            recognitionEngine: model.engine,
            textProcessingVersion: 2,
          ),
          AsrEnhancementOptions.alignmentQwenId,
        );
      } finally {
        center.dispose();
      }
    },
  );
  test(
    'Parakeet Japanese uses native timing and only prepares forced alignment on request',
    () async {
      final center = ModelCenterService()
        ..catalog = [...await loadModelCatalog(), cohereComparisonCandidate()];
      try {
        final model = center.artifact('parakeet-ja-0.6b-q8')!;
        center.profiles['japanese'] = ModelServiceProfile(
          id: 'japanese',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        );
        center.asrProfileId = 'japanese';
        center.selectedLanguage = 'en';
        final spec = center.transcriptionConfiguration;
        expect(center.effectiveAsrLanguage, 'ja');
        expect(center.selectedLanguage, 'en');
        expect(spec.profile.language, 'ja');
        expect(spec.enhancementModels, isEmpty);
        expect(spec.asrEnhancements!.denoise, isFalse);
        expect(center.asrDownloadComponents(model).map((m) => m.id), [
          model.id,
          asrVadModelId,
        ]);
        expect(spec.asrTokenTiming, 'parakeet-ja-ctc-80ms-gap-recovery-v1');
        expect(
          localAsrProbeAsset(model.engine, model.languages),
          endsWith('speech_probe_ja.wav'),
        );
        center.asrEnhancements = const AsrEnhancementOptions(alwaysAlign: true);
        expect(center.transcriptionConfiguration.enhancementModels.keys, [
          AsrEnhancementOptions.alignmentQwenId,
        ]);
        center.asrEnhancements = const AsrEnhancementOptions(denoise: false);
        center.updateAsrEnhancements(
          center.currentAsrEnhancements.copyWith(denoise: true),
        );
        expect(center.currentAsrEnhancements.denoise, isTrue);
        expect(
          center.asrEnhancements.denoise,
          isFalse,
          reason:
              'The new model must not alter other models\' denoising preference',
        );
        expect(
          spec.asrEnhancements!.denoise,
          isFalse,
          reason: 'An already captured task keeps its audio settings',
        );
        expect(center.transcriptionConfiguration.enhancementModels.keys, [
          AsrEnhancementOptions.denoiserId,
        ]);
      } finally {
        center.dispose();
      }
    },
  );
  test(
    'Japanese preset freezes Japanese without changing the saved language preference',
    () async {
      final center = ModelCenterService()
        ..catalog = [...await loadModelCatalog(), cohereComparisonCandidate()];
      try {
        final model = center.artifact('cohere-transcribe-03-2026-q8')!;
        center.profiles['test'] = ModelServiceProfile(
          id: 'test',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        );
        center.asrProfileId = 'test';
        for (final preference in ['auto', 'en', 'ja']) {
          center.selectedLanguage = preference;
          center.asrEnhancements = const AsrEnhancementOptions();
          final spec = center.transcriptionConfiguration;
          expect(spec.profile.language, 'ja');
          expect(center.selectedLanguage, preference);
          expect(spec.enhancementModels.keys, [
            AsrEnhancementOptions.denoiserId,
            AsrEnhancementOptions.alignmentQwenId,
          ]);
          expect(
            center.asrEnhancementArtifacts(model).map((m) => m.id),
            spec.enhancementModels.keys,
          );
        }
        center.asrEnhancements = AsrEnhancementOptions.disabled;
        expect(center.transcriptionConfiguration.enhancementModels, isEmpty);
      } finally {
        center.dispose();
      }
    },
  );
}
