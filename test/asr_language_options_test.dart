import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_language_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _FailingCenter extends ModelCenterService {
  @override
  Future<void> settingsChanged() async =>
      throw FileSystemException('save rejected');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late AppStorageService storage;
  late ModelCenterService center;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temporary = await Directory.systemTemp.createTemp('asr-language-');
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory(p.join(temporary.path, 'support')),
        documents: Directory(p.join(temporary.path, 'docs')),
        defaultData: Directory(p.join(temporary.path, 'data')),
        executable: Directory(p.join(temporary.path, 'exe')),
      ),
    );
    await storage.initialize();
    center = ModelCenterService(storage: storage);
    await center.initialize();
  });
  tearDown(() async {
    await center.shutdown();
    center.dispose();
    await temporary.delete(recursive: true);
  });
  void bind(String id) {
    final model = center.artifact(id)!;
    final profile = ModelServiceProfile(
      id: 'local:$id',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: id,
    );
    center.profiles[profile.id] = profile;
    center.asrProfileId = profile.id;
  }

  test(
    'every selectable local export only offers its own recognition languages',
    () {
      for (final model in center.catalog.where(
        (m) => m.purpose == ModelPurpose.transcription,
      )) {
        bind(model.id);
        final options = center.currentAsrLanguageOptions;
        expect(
          options.codes.toSet().length,
          options.codes.length,
          reason: model.id,
        );
        expect(
          options.codes
              .where((c) => c != 'auto')
              .every(model.languages.contains),
          isTrue,
          reason: model.id,
        );
        expect(options.editable, model.languages.length > 1, reason: model.id);
      }
      bind('dolphin-base-int8');
      expect(center.currentAsrLanguageOptions.codes, isNot(contains('en')));
      bind('parakeet-v3-int8');
      expect(center.currentAsrLanguageOptions.codes, isNot(contains('ja')));
      bind('parakeet-ja-0.6b-q8');
      expect(center.currentAsrLanguageOptions.codes, ['ja']);
    },
  );

  test(
    'switching models restores each choice and unsupported legacy preference safely uses auto',
    () async {
      bind('qwen3-asr-0.6b-f16');
      await center.selectAsrLanguage('ja-JP');
      bind('parakeet-v3-int8');
      expect(center.effectiveAsrLanguage, 'auto');
      expect(center.selectedLanguage, 'ja');
      await center.selectAsrLanguage('de');
      bind('qwen3-asr-1.7b-f16');
      await center.selectAsrLanguage('en-US');
      bind('dolphin-base-int8');
      expect(center.effectiveAsrLanguage, 'auto');
      await expectLater(center.selectAsrLanguage('en'), throwsArgumentError);
      await center.selectAsrLanguage('ko');
      bind('qwen3-asr-0.6b-f16');
      expect(center.effectiveAsrLanguage, 'ja');
      bind('parakeet-v3-int8');
      expect(center.effectiveAsrLanguage, 'de');
      bind('qwen3-asr-1.7b-f16');
      expect(center.effectiveAsrLanguage, 'en');
      bind('parakeet-ja-0.6b-q8');
      expect(center.effectiveAsrLanguage, 'ja');
      await expectLater(center.selectAsrLanguage('en'), throwsArgumentError);
    },
  );

  test(
    'per-model choices survive service restart and keep existing language fallback',
    () async {
      bind('sensevoice-small-int8');
      await center.selectAsrLanguage('ko');
      bind('qwen3-asr-0.6b-f16');
      await center.selectAsrLanguage('ja');
      final restarted = ModelCenterService(storage: storage);
      try {
        await restarted.initialize();
        expect(restarted.effectiveAsrLanguage, 'ja');
        expect(
          restarted.asrLanguagePreferences['local:sensevoice-small-int8'],
          'ko',
        );
        expect(restarted.selectedLanguage, 'ja');
        restarted.asrProfileId = 'local:sensevoice-small-int8';
        expect(restarted.effectiveAsrLanguage, 'ko');
      } finally {
        await restarted.shutdown();
        restarted.dispose();
      }
    },
  );

  test(
    'captured language and dependency identities remain frozen after another selection',
    () async {
      bind('qwen3-asr-0.6b-f16');
      await center.selectAsrLanguage('ja');
      final saved = center.transcriptionConfiguration;
      final fingerprint = saved.recognitionFingerprint;
      expect(
        saved.enhancementModels,
        contains(AsrEnhancementOptions.alignmentQwenId),
      );
      await center.selectAsrLanguage('en');
      final next = center.transcriptionConfiguration;
      expect(next.profile.language, 'en');
      expect(
        next.enhancementModels,
        contains(AsrEnhancementOptions.alignmentEnglishId),
      );
      expect(
        next.enhancementModels,
        isNot(contains(AsrEnhancementOptions.alignmentQwenId)),
      );
      final restored = ModelJobSpec.fromJson(saved.toJson());
      expect(restored.profile.language, 'ja');
      expect(restored.recognitionFingerprint, fingerprint);
      expect(
        center
            .asrEnhancementArtifacts(center.artifact(saved.profile.model)!)
            .map((m) => m.id),
        next.enhancementModels.keys,
      );
    },
  );

  test(
    'picker answer for an older model cannot change a newly selected model',
    () async {
      bind('qwen3-asr-0.6b-f16');
      final original = center.asrProfile;
      bind('parakeet-v3-int8');
      await center.selectAsrLanguage('de');
      await center.selectAsrLanguage('ja', profile: original);
      expect(center.effectiveAsrLanguage, 'de');
      expect(center.selectedLanguage, 'de');
      expect(center.languageForProfile(original), 'ja');
    },
  );

  test(
    'rejected persistence rolls back the displayed and per-model selection',
    () async {
      final failing = _FailingCenter()..catalog = center.catalog;
      final model = center.artifact('qwen3-asr-0.6b-f16')!;
      final profile = ModelServiceProfile(
        id: 'local:${model.id}',
        name: model.name,
        kind: TranscriptionServiceKind.local,
        model: model.id,
      );
      failing.profiles[profile.id] = profile;
      failing.asrProfileId = profile.id;
      try {
        await expectLater(
          failing.selectAsrLanguage('ja'),
          throwsA(isA<FileSystemException>()),
        );
        expect(failing.effectiveAsrLanguage, 'auto');
        expect(failing.asrLanguagePreferences, isEmpty);
      } finally {
        failing.dispose();
      }
    },
  );

  test(
    'cloud language hints match known API contracts and auto omits the hint',
    () {
      ModelServiceProfile ali(String model, String code) => ModelServiceProfile(
        id: 'ali',
        name: 'Ali',
        kind: TranscriptionServiceKind.aliyun,
        model: model,
        language: code,
      );
      expect(aliyunAsrLanguageHints(ali('fun-asr', 'ja')), ['ja']);
      expect(aliyunAsrLanguageHints(ali('fun-asr', 'fil')), ['tl']);
      expect(aliyunAsrLanguageHints(ali('paraformer-v2', 'ko')), ['ko']);
      expect(aliyunAsrLanguageHints(ali('paraformer-v1', 'en')), isNull);
      expect(aliyunAsrLanguageHints(ali('fun-asr', 'auto')), isNull);
      expect(
        aliyunAsrLanguageHints(ali('custom-unverified-model', 'ja')),
        isNull,
      );
      expect(aliyunAsrLanguageHints(ali('paraformer-v2', 'es')), isNull);
      const tencent = ModelServiceProfile(
        id: 'tc',
        name: 'TC',
        kind: TranscriptionServiceKind.tencent,
        model: '16k_ja',
      );
      expect(asrLanguageOptions(tencent).codes, ['ja']);
      expect(
        asrLanguageOptions(ModelCenterService.legacyProfile).editable,
        isFalse,
      );
      expect(
        asrLanguageOptions(ModelCenterService.legacyProfile).resolve('ja'),
        'auto',
      );
    },
  );

  test(
    'automatic-only service ignores a stale global language without changing task settings',
    () {
      center.asrProfileId = ModelCenterService.legacyProfile.id;
      final fingerprint = center.transcriptionConfiguration.fingerprint;
      center.selectedLanguage = 'en';
      expect(center.effectiveAsrLanguage, 'auto');
      expect(center.transcriptionConfiguration.fingerprint, fingerprint);
      expect(center.currentAsrLanguageOptions.editable, isFalse);
    },
  );
}
