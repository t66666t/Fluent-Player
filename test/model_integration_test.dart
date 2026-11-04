import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_model_adapter.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/local_translation_batch.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/ocr_model_catalog.dart';

import '../tool/model_integration_contract.dart';

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

ModelArtifact _variant(
  ModelArtifact model, {
  required String id,
  String? engine,
  List<ModelFile>? files,
}) => ModelArtifact(
  id: id,
  name: model.name,
  engine: engine ?? model.engine,
  revision: 'f' * 40,
  parameters: model.parameters,
  quantization: model.quantization,
  languages: model.languages,
  description: model.description,
  license: model.license,
  homepage: model.homepage,
  purpose: model.purpose,
  files: files ?? model.files,
  suggestedRamGb: model.suggestedRamGb,
  memoryNote: model.memoryNote,
);

Map<String, Object?> _snapshot(ModelArtifact model) => {
  'id': model.id,
  'identity': model.identity,
  'engine': model.engine,
  'purpose': model.purpose.name,
  'languages': model.languages,
  'files': [
    for (final file in model.files)
      {'name': file.name, 'bytes': file.bytes, 'sha256': file.sha256},
  ],
};

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'catalog additions preserve every shipped model and OCR combination',
    () async {
      final models = await loadModelCatalog(includeRetired: true);
      final presets = await loadOcrPresets();
      validateModelIntegration(models, presets);
      final baseline =
          jsonDecode(
                await File(
                  'test/fixtures/local_model_compatibility.json',
                ).readAsString(),
              )
              as Map;
      for (final raw in baseline['models'] as List) {
        final expected = raw as Map;
        final actual = models.singleWhere((m) => m.id == expected['id']);
        expect(_snapshot(actual), expected, reason: actual.id);
      }
      for (final raw in baseline['ocrPresets'] as List) {
        final expected = raw as Map;
        final actual = presets.singleWhere((m) => m.id == expected['id']);
        expect(
          {
            'id': actual.id,
            'detection': actual.detection,
            'recognition': actual.recognition,
            'groups': actual.groups,
            'languages': actual.languages,
            if (expected.containsKey('legacy')) 'legacy': actual.legacy,
          },
          expected,
          reason: actual.id,
        );
      }
    },
  );

  test(
    'old job serialization and every resume fingerprint remain byte-identical',
    () async {
      final baseline =
          jsonDecode(
                await File(
                  'test/fixtures/local_model_compatibility.json',
                ).readAsString(),
              )
              as Map;
      for (final entry in (baseline['jobs'] as Map).entries) {
        final expected = entry.value as Map;
        final spec = ModelJobSpec.fromJson(
          Map<String, dynamic>.from(expected['json'] as Map),
        );
        expect(spec.toJson(), expected['json'], reason: entry.key as String);
        expect(_digest(spec.fingerprint), expected['fingerprint']);
        expect(_digest(spec.recognitionFingerprint), expected['recognition']);
        expect(
          spec.recognitionCacheFingerprints.map(_digest).toList(),
          expected['recognitionCache'],
        );
        expect(_digest(spec.enhancementFingerprint), expected['enhancement']);
        expect(
          asrTokenTimingOverride(
            spec.profile.model,
            (await loadModelCatalog(
              includeRetired: true,
            )).singleWhere((m) => m.id == spec.profile.model).engine,
          ),
          isNull,
        );
      }
    },
  );

  test(
    'new family-compatible IDs validate; duplicate IDs and wrong exports fail early',
    () async {
      final models = await loadModelCatalog();
      final presets = await loadOcrPresets();
      for (final model in models.where(
        (m) =>
            m.purpose == ModelPurpose.transcription ||
            m.purpose == ModelPurpose.translation,
      )) {
        validateModelIntegration([
          ...models,
          _variant(model, id: '${model.id}-next'),
        ], presets);
      }
      expect(
        () => validateModelIntegration([...models, models.first], presets),
        throwsFormatException,
      );
      expect(
        () => validateModelIntegration([
          ...models,
          _variant(models.first, id: models.first.id.toUpperCase()),
        ], presets),
        throwsFormatException,
      );
      expect(
        () => validateModelIntegration([
          ...models,
          _variant(
            models.first,
            id: 'bad-export',
            files: [models.first.files.last],
          ),
        ], presets),
        throwsFormatException,
      );
      expect(
        () => validateModelIntegration([
          ...models,
          _variant(models.first, id: 'unknown-family', engine: 'unverified'),
        ], presets),
        throwsArgumentError,
      );
      expect(
        () => validateModelIntegration(
          models.where((m) => m.id != 'ocr-v6-tiny-det').toList(),
          presets,
        ),
        throwsFormatException,
      );
    },
  );

  for (final engine in ['sensevoice', 'dolphin', 'parakeet']) {
    test(
      '$engine retains native defaults, file roles and decoding parameters',
      () {
        final config = localOfflineAsrConfiguration(
          engine: engine,
          directory: 'models',
          language: 'auto',
          threads: 2,
        );
        expect(config.model.tokens, p.join('models', 'tokens.txt'));
        expect(config.model.numThreads, 2);
        expect(config.model.provider, 'cpu');
        expect(config.model.debug, isFalse);
        expect(config.decodingMethod, 'greedy_search');
        expect(config.hotwordsFile, isEmpty);
        expect(config.hotwordsScore, 1.5);
        expect(
          config.model.modelType,
          engine == 'parakeet' ? 'nemo_transducer' : '',
        );
        expect(config.model.senseVoice.toJson(), {
          'model': engine == 'sensevoice'
              ? p.join('models', 'model.int8.onnx')
              : '',
          'language': engine == 'sensevoice' ? 'auto' : '',
          'useInverseTextNormalization': engine == 'sensevoice',
        });
        expect(
          config.model.dolphin.model,
          engine == 'dolphin' ? p.join('models', 'model.int8.onnx') : '',
        );
        expect(
          config.model.transducer.encoder,
          engine == 'parakeet' ? p.join('models', 'encoder.int8.onnx') : '',
        );
        expect(
          () => localStreamingAsrConfiguration(
            engine: engine,
            directory: 'models',
            threads: 2,
          ),
          throwsArgumentError,
        );
      },
    );
  }

  test('Zipformer remains streaming with its BPE and hotword contract', () {
    final config = localStreamingAsrConfiguration(
      engine: 'zipformer',
      directory: 'models',
      threads: 3,
      hotwordsFile: 'hotwords.txt',
    );
    expect(config.model.modelingUnit, 'cjkchar+bpe');
    expect(config.model.bpeVocab, p.join('models', 'bpe.vocab'));
    expect(
      config.model.transducer.joiner,
      p.join('models', 'joiner.int8.onnx'),
    );
    expect(config.model.numThreads, 3);
    expect(config.model.provider, 'cpu');
    expect(config.enableEndpoint, isFalse);
    expect(config.decodingMethod, 'modified_beam_search');
    expect(config.hotwordsFile, 'hotwords.txt');
    expect(config.hotwordsScore, 1.5);
    expect(
      () => localOfflineAsrConfiguration(
        engine: 'zipformer',
        directory: 'models',
        language: 'zh',
        threads: 2,
      ),
      throwsArgumentError,
    );
  });

  test('existing single and batch prompt selection retains exact text', () {
    const source = '<i>Hello %s 😀</i>\nNext';
    expect(
      localTranslationSinglePrompt(
        engine: 'hy-mt',
        source: source,
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        glossary: 'API=接口',
        hasProtectedText: true,
      ),
      '术语和要求：API=接口\n将以下文本翻译为简体中文，注意只需要输出翻译后的结果，不要额外解释。保留所有字幕标签与占位符。\n\n$source',
    );
    for (final engine in ['hy-mt', 'qwen3', 'external-fixture']) {
      expect(
        localTranslationSinglePrompt(
          engine: engine,
          source: source,
          targetLanguage: 'en',
          targetLabel: '英语',
          glossary: 'API=interface',
        ),
        'Translate the following subtitle into English. Output the translation only. Preserve HTML tags, placeholders and line breaks.\nTerminology and requirements: API=interface\n\n$source',
      );
    }
    expect(localTranslationUsesEnglishPrompt('hy-mt', 'zh-HK'), isFalse);
    expect(localTranslationUsesEnglishPrompt('qwen3', 'zh-CN'), isTrue);
    expect(
      localTranslationSinglePrompt(
        engine: 'qwen3',
        source: source,
        targetLanguage: 'zh-HK',
        targetLabel: '中文',
      ),
      startsWith('Translate the following subtitle into Traditional Chinese.'),
    );
  });

  group('independent model IDs use existing storage and task flows', () {
    late Directory root;
    late AppStorageService storage;
    late ModelCenterService center;
    late List<ModelArtifact> models;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('model-integration-');
      storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'documents')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'executable')),
        ),
      );
      await storage.initialize();
      final catalog = await loadModelCatalog();
      final bytes = utf8.encode('small deterministic fixture');
      List<ModelFile> files(String name) => [
        ModelFile(
          name: name,
          bytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          sources: const {},
        ),
      ];
      models = [
        _variant(
          catalog.firstWhere((m) => m.engine == 'parakeet'),
          id: 'parakeet-old-fixture',
          files: files('fixture.onnx'),
        ),
        _variant(
          catalog.firstWhere((m) => m.engine == 'parakeet'),
          id: 'parakeet-new-fixture',
          files: files('fixture.onnx'),
        ),
        _variant(
          catalog.firstWhere((m) => m.purpose == ModelPurpose.translation),
          id: 'translation-old-fixture',
          files: files('fixture.gguf'),
        ),
        _variant(
          catalog.firstWhere((m) => m.purpose == ModelPurpose.translation),
          id: 'translation-new-fixture',
          files: files('fixture.gguf'),
        ),
      ];
      center = ModelCenterService(
        storage: storage,
        catalogLoader: () async => models,
        secrets: _Secrets(),
      );
      await center.initialize();
      center.asrEnhancements = AsrEnhancementOptions.disabled;
      final source = Directory(p.join(root.path, 'import'));
      await source.create();
      for (final model in models) {
        for (final file in model.files) {
          await File(p.join(source.path, file.name)).writeAsBytes(bytes);
        }
        await center.importFiles(model.id, source);
      }
    });
    tearDown(() async {
      await center.shutdown();
      center.dispose();
      await root.delete(recursive: true);
    });

    test(
      'selecting the new model preserves leased old files and frozen task identity after restart',
      () async {
        await center.selectAsr(models[0]);
        final oldSpec = await center.captureTranscription();
        await center.usingModel(models[0].id, (_, oldDirectory) async {
          await center.selectAsr(models[1]);
          final newSpec = await center.captureTranscription();
          expect(oldSpec.profile.model, models[0].id);
          expect(newSpec.profile.model, models[1].id);
          expect(
            oldSpec.recognitionFingerprint,
            isNot(newSpec.recognitionFingerprint),
          );
          for (final spec in [oldSpec, newSpec]) {
            expect(spec.asrTokenTiming, 'tdt-frame-groups-v2');
            final restored = ModelJobSpec.fromJson(spec.toJson());
            expect(restored.fingerprint, spec.fingerprint);
            for (final key in restored.recognitionCacheFingerprints) {
              expect(jsonDecode(key)['tokenTiming'], 'tdt-frame-groups-v2');
            }
          }
          await expectLater(center.remove(models[0].id), throwsStateError);
          expect(
            await File(p.join(oldDirectory.path, 'fixture.onnx')).exists(),
            isTrue,
          );
        });
        await center.shutdown();
        final restored = ModelCenterService(
          storage: storage,
          catalogLoader: () async => models,
          secrets: _Secrets(),
        );
        try {
          await restored.initialize();
          expect(restored.asrProfile.model, models[1].id);
          for (final model in models) {
            expect(restored.installed(model.id), isTrue, reason: model.id);
          }
          expect(
            ModelJobSpec.fromJson(oldSpec.toJson()).fingerprint,
            oldSpec.fingerprint,
          );
          await restored.usingAsrModels(oldSpec, (model, _, _) async {
            expect(model.identity, oldSpec.artifactIdentity);
          });
        } finally {
          await restored.shutdown();
          restored.dispose();
        }
      },
    );

    test(
      'changing the translation default cannot replace a captured model or its completed lines',
      () async {
        center.translationModelId = models[2].id;
        final spec = await captureLocalTranslation(center);
        final cancellation = Completer<void>();
        final calls = <String>[];
        final translator = LocalSubtitleTranslator(
          center: center,
          complete: (text, _, _, _, _) async {
            calls.add(text);
            if (text == 'Second') cancellation.complete();
            return '译：$text';
          },
        );
        await expectLater(
          translator.translate(
            texts: const ['First', 'Second'],
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '简体中文',
            specification: spec,
            cancelSignal: cancellation.future,
            onProgress: (_) {},
          ),
          throwsStateError,
        );
        center.translationModelId = models[3].id;
        await center.settingsChanged();
        final completed = <String>[];
        final resumed = LocalSubtitleTranslator(
          center: center,
          complete: (text, _, _, _, _) async {
            completed.add(text);
            expect(center.inUse(models[2].id), isTrue);
            expect(center.inUse(models[3].id), isFalse);
            return '译：$text';
          },
        );
        final result = await resumed.translate(
          texts: const ['First', 'Second'],
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: spec,
          onProgress: (_) {},
        );
        expect(result, ['译：First', '译：Second']);
        expect(completed, ['Second']);
        expect(center.translationModelId, models[3].id);
      },
    );
  });
}
