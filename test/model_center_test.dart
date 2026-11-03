import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_screen.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/ios_model_download.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_screen.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_center_widgets.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_token_timing.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation_screen.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/app_default_settings_trial.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _ViewCenter extends ModelCenterService {
  _ViewCenter({
    required super.storage,
    required super.catalogLoader,
    required super.secrets,
  });
  final enqueued = <String>[];
  bool rejectDownloads = false;
  @override
  Future<void> enqueue(String id) async {
    if (rejectDownloads) throw StateError('测试下载失败');
    enqueued.add(id);
    downloads[id] = ModelDownload(artifactId: id);
    notifyListeners();
  }

  @override
  Future<void> save() async {}
}

class _TaskProgress extends ChangeNotifier implements TranscriptionManager {
  double fraction = .1;
  @override
  bool get isProcessing => true;
  @override
  double get progress => fraction;
  @override
  String get statusMessage => '测试进度 ${(fraction * 100).round()}%';
  void update(double value) {
    fraction = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeCenter extends _ViewCenter {
  _ProbeCenter({
    required super.storage,
    required super.catalogLoader,
    required super.secrets,
  });
  int fileChecks = 0;
  int inferenceCalls = 0;

  @override
  Future<void> verify(String id) async {
    fileChecks++;
    throw StateError('不应自动扫描文件');
  }

  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) async {
    inferenceCalls++;
    throw StateError('已直接进入推理');
  }
}

class _Transfer implements HttpClientAdapter {
  _Transfer(
    this.bytes, {
    this.slow = false,
    this.corrupt = false,
    this.truncated = false,
  });
  final List<int> bytes;
  final bool slow, truncated;
  bool corrupt;
  final offsets = <int>[];
  bool changed = false;
  bool invalidRange = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final offset =
        int.tryParse(
          '${options.headers['Range'] ?? ''}'
              .replaceAll('bytes=', '')
              .replaceAll('-', ''),
        ) ??
        0;
    offsets.add(offset);
    final start = changed ? 0 : offset;
    Stream<Uint8List> stream() async* {
      final end = bytes.length - (truncated ? 128 : 0);
      for (var at = start; at < end; at += 128) {
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 4));
        final chunk = bytes.sublist(at, (at + 128).clamp(0, bytes.length));
        if (corrupt && chunk.isNotEmpty) chunk[0] ^= 1;
        yield Uint8List.fromList(chunk);
      }
    }

    return ResponseBody(
      stream(),
      start > 0 ? 206 : 200,
      headers: {
        'etag': [changed ? '"v2"' : '"v1"'],
        'content-length': ['${bytes.length - start}'],
        if (start > 0)
          'content-range': [
            'bytes ${invalidRange ? start + 1 : start}-${bytes.length - 1}/${bytes.length}',
          ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CloudAdapter implements HttpClientAdapter {
  _CloudAdapter(this.respond);
  final Object Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    if (body != null) await body.drain<void>();
    final value = respond(options);
    return ResponseBody.fromString(
      value is String ? value : jsonEncode(value),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SourceTransfer implements HttpClientAdapter {
  _SourceTransfer(
    this.bytes, {
    this.corruptPrefix = false,
    this.ignoreRange = false,
  });
  final List<int> bytes;
  final bool corruptPrefix, ignoreRange;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (options.uri.host == 'official.test') {
      Stream<Uint8List> failing() async* {
        final prefix = bytes.sublist(0, 1024);
        if (corruptPrefix) prefix[0] ^= 1;
        yield Uint8List.fromList(prefix);
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'network disconnected',
        );
      }

      return ResponseBody(
        failing(),
        200,
        headers: {
          'etag': ['"official-v1"'],
          'content-length': ['${bytes.length}'],
        },
      );
    }
    final offset = ignoreRange
        ? 0
        : int.tryParse(
                '${options.headers['Range'] ?? ''}'
                    .replaceAll('bytes=', '')
                    .replaceAll('-', ''),
              ) ??
              0;
    return ResponseBody.fromBytes(
      bytes.sublist(offset),
      offset == 0 ? 200 : 206,
      headers: {
        'etag': ['"mirror-v2"'],
        'content-length': ['${bytes.length - offset}'],
        if (offset > 0)
          'content-range': [
            'bytes $offset-${bytes.length - 1}/${bytes.length}',
          ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStorageService storage;
  late _Secrets secrets;
  late List<int> bytes;
  late ModelArtifact model;
  final services = <ModelCenterService>[];

  ModelCenterService create({
    bool view = false,
    _Transfer? transfer,
    HttpClientAdapter? adapter,
    List<ModelArtifact>? catalog,
  }) {
    final service = view
        ? _ViewCenter(
            storage: storage,
            secrets: secrets,
            catalogLoader: () async => catalog ?? [model],
          )
        : ModelCenterService(
            storage: storage,
            secrets: secrets,
            catalogLoader: () async => catalog ?? [model],
            createDio: () {
              final dio = Dio();
              dio.httpClientAdapter = adapter ?? transfer ?? _Transfer(bytes);
              return dio;
            },
          );
    if (!view) services.add(service);
    return service;
  }

  Future<void> until(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) fail('state did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    root = await Directory.systemTemp.createTemp('model-center-test-');
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
    secrets = _Secrets();
    bytes = List.generate(4096, (index) => index % 251);
    model = ModelArtifact(
      id: 'fixture',
      name: '测试翻译模型',
      engine: 'hy-mt',
      revision: '0123456789abcdef',
      parameters: '1.8B',
      quantization: 'Q4_K_M',
      languages: const ['zh', 'en'],
      description: '测试模型',
      license: 'Apache-2.0',
      homepage: 'https://example.com',
      purpose: ModelPurpose.translation,
      suggestedRamGb: 8,
      memoryNote: '建议起测档位',
      files: [
        ModelFile(
          name: 'model.gguf',
          bytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          sources: const {'official': 'https://example.com/model.gguf'},
        ),
      ],
    );
  });
  tearDown(() async {
    for (final service in services.reversed) {
      await service.shutdown();
    }
    services.clear();
    await root.delete(recursive: true);
  });

  test(
    'live default trial restores legacy effective options and retains current model and view state',
    () async {
      final file = await storage.dataRecord('model_center.json');
      await writeStorageJson(file, {
        'version': 1,
        'threads': 3,
        'language': 'ja',
        'asrLanguagePreferences': {'local:qwen3-asr-0.6b-f16': 'ko'},
        'asrExecution': 'unknown-legacy-mode',
        'asrAccelerationOptions': {'old-model': 'unknown-legacy-mode'},
      });
      final service = create();
      await service.initialize();
      final originalProfile = service.asrProfileId;
      expect(service.asrCpuThreads, 3);
      final original = TrialFieldMask.capture(
        Map<String, dynamic>.from(await readStorageJson(file) as Map),
        RecommendedAppDefaults.modelFields,
      );
      final applying = service.patchPreferencesForTrial(
        RecommendedAppDefaults.modelValues(
          const DefaultSettingsDevice(TargetPlatform.windows, Size(1280, 720)),
        ),
        false,
      );
      final progressSave = service.save();
      await Future.wait([applying, progressSave]);
      expect(service.asrCpuThreads, 0);
      expect(service.selectedLanguage, 'auto');
      expect(service.asrLanguagePreferences, isEmpty);
      service.search = 'keep new search';
      service.diagnostics['new-task'] = 'keep new task result';
      final restoring = service.patchPreferencesForTrial(original, true);
      final concurrentSave = service.save();
      await Future.wait([restoring, concurrentSave]);
      await service.reloadPreferencesForTrial();
      expect(service.selectedLanguage, 'ja');
      expect(service.asrLanguagePreferences['local:qwen3-asr-0.6b-f16'], 'ko');
      expect(service.threads, 3);
      expect(service.asrCpuThreads, 3);
      expect(service.asrExecution, AsrExecutionMode.auto);
      expect(service.asrAccelerationOptions['old-model'], AsrAcceleration.auto);
      expect(service.asrProfileId, originalProfile);
      final saved = await readStorageJson(file) as Map;
      expect(saved['search'], 'keep new search');
      expect(saved['diagnostics']['new-task'], 'keep new task result');
    },
  );

  test('catalog pins every file and rejects traversal', () async {
    final catalog = await loadModelCatalog();
    // Additions are allowed; shipped identities are pinned by the integration
    // compatibility fixture instead of a total count that blocks new models.
    expect(
      catalog.where((m) => m.purpose != ModelPurpose.ocr).length,
      greaterThanOrEqualTo(14),
    );
    expect(catalog.where((m) => m.purpose == ModelPurpose.ocr), isNotEmpty);
    for (final artifact in catalog) {
      expect(
        artifact.revision,
        matches(RegExp(r'^(?:[a-f0-9]{40}|[a-f0-9]{64})$')),
      );
      for (final file in artifact.files) {
        expect(file.sha256, hasLength(64));
        expect(file.bytes, greaterThan(0));
      }
    }
    expect(
      () => ModelFile.fromJson({
        'name': '../escape',
        'bytes': 1,
        'sha256': 'a' * 64,
        'sources': {},
      }),
      throwsFormatException,
    );
  });

  test(
    'ASR modes and bounded per-model measurements persist independently',
    () async {
      final service = create();
      await service.initialize();
      service.asrAccelerationOptions.addAll({
        'sensevoice': AsrAcceleration.cpu,
        'dolphin': AsrAcceleration.gpu,
      });
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 18; i++) {
        await service.recordAsrState('sensevoice', {
          'backend': 'CPU',
          'reason': 'measured',
          'profile': AsrPerformanceProfile(
            signature: 'configuration-$i',
            testedAt: now.add(Duration(seconds: i)),
            backend: 'GPU · DirectML',
            device: 'driver',
            weights: 'fp32@revision',
            sampleSeconds: 4,
            cpuMs: 100,
            gpuMs: 200,
          ).toJson(),
        });
      }
      await service.recordAsrState('dolphin', {
        'backend': 'CPU',
        'reason': 'failed',
        'profile': AsrPerformanceProfile(
          signature: 'failed',
          testedAt: now,
          failed: true,
          backend: 'GPU · DirectML',
          device: 'driver',
          weights: 'fp32@revision',
          sampleSeconds: 4,
          cpuMs: 0,
          gpuMs: 0,
        ).toJson(),
      });
      final restored = create();
      await restored.initialize();
      expect(restored.asrAccelerationFor('sensevoice'), AsrAcceleration.cpu);
      expect(restored.asrAccelerationFor('dolphin'), AsrAcceleration.gpu);
      expect(restored.asrAccelerationFor('zipformer'), AsrAcceleration.auto);
      expect(restored.asrPerformance.length, 17);
      expect(
        restored.asrPerformance.containsKey('sensevoice:configuration-0'),
        isFalse,
      );
      restored.clearAsrPerformance('sensevoice');
      await restored.settingsChanged();
      expect(restored.asrPerformance.keys, ['dolphin:failed']);
    },
  );

  test(
    'early ASR failures persist across restarts and successful retests clear them',
    () async {
      final service = create();
      await service.initialize();
      final signature = asrAvailabilitySignature({
        'identity': 'sensevoice@rev',
      });
      await service.recordAsrState('sensevoice', {
        'backend': 'CPU',
        'reason': 'missing hardware',
        'profile': AsrPerformanceProfile(
          signature: signature,
          testedAt: DateTime.now().toUtc(),
          backend: 'GPU',
          device: 'preflight',
          weights: 'sensevoice@rev',
          sampleSeconds: 1,
          cpuMs: 0,
          gpuMs: 0,
          failed: true,
        ).toJson(),
      });
      final restored = create();
      await restored.initialize();
      expect(restored.asrPerformance['sensevoice:$signature']?.failed, isTrue);
      await restored.recordAsrState('sensevoice', {
        'backend': 'CPU',
        'reason': 'retest passed, CPU faster',
        'clearProfileSignature': signature,
      });
      final retested = create();
      await retested.initialize();
      expect(
        retested.asrPerformance.containsKey('sensevoice:$signature'),
        isFalse,
      );
    },
  );

  test(
    'optional ASR packs lease their frozen identity without enhancement dependencies',
    () async {
      ModelArtifact fixture(String id, ModelPurpose purpose) => ModelArtifact(
        id: id,
        name: id,
        engine: 'sensevoice',
        revision: model.revision,
        parameters: '',
        quantization: '',
        languages: model.languages,
        description: '',
        license: model.license,
        homepage: model.homepage,
        purpose: purpose,
        files: model.files,
        suggestedRamGb: 1,
        memoryNote: '',
      );
      final primary = fixture('voice', ModelPurpose.transcription);
      final pack = fixture('voice-gpu', ModelPurpose.acceleration);
      final service = create(catalog: [primary, pack]);
      await service.initialize();
      await service.enqueue(primary.id);
      await service.enqueue(pack.id);
      await until(
        () => service.installed(primary.id) && service.installed(pack.id),
      );
      ModelJobSpec job(AsrAcceleration? mode, {String? version}) =>
          ModelJobSpec(
            profile: const ModelServiceProfile(
              id: 'local:voice',
              name: 'voice',
              model: 'voice',
              kind: TranscriptionServiceKind.local,
            ),
            artifactIdentity: primary.identity,
            asrAcceleration: mode,
            asrAccelerationModels: {pack.id: version ?? pack.identity},
          );
      for (final mode in [
        AsrAcceleration.auto,
        AsrAcceleration.gpu,
        AsrAcceleration.cpu,
        null,
      ]) {
        final leased = await service.usingAsrModels(job(mode), (
          _,
          _,
          extras,
        ) async {
          expect(
            service.inUse(pack.id),
            mode == AsrAcceleration.auto || mode == AsrAcceleration.gpu,
          );
          return extras.keys.toList();
        });
        expect(
          leased,
          mode == AsrAcceleration.auto || mode == AsrAcceleration.gpu
              ? [pack.id]
              : isEmpty,
        );
        expect(service.inUse(pack.id), isFalse);
      }
      expect(
        await service.usingAsrModels(
          job(AsrAcceleration.gpu, version: 'old@revision'),
          (_, _, extras) async => extras,
        ),
        isEmpty,
      );
    },
  );

  test(
    'retired speaker downloads and saved dependencies are ignored without deleting weights',
    () async {
      final oldWeight = File(
        p.join(
          (await storage.featureDirectory('local_models')).path,
          'old-speaker',
          'model.onnx',
        ),
      );
      await oldWeight.parent.create(recursive: true);
      await oldWeight.writeAsBytes([1, 2, 3]);
      final record = await storage.dataRecord('model_center.json');
      await record.writeAsString(
        jsonEncode({
          'subtitleSegmentation': {
            'version': 1,
            'maxDurationMs': 4000,
            'maxWidth': 40,
          },
          'asrEnhancements': {
            'version': 1,
            'diarization': true,
            'denoise': false,
          },
          'downloads': [
            ModelDownload(artifactId: 'asr-speaker-segmentation-int8').toJson(),
            ModelDownload(
              artifactId: 'asr-speaker-campplus',
              phase: ModelDownloadPhase.installed,
            ).toJson(),
          ],
          'diagnostics': {'asr-speaker-campplus': 'old result'},
        }),
      );
      final service = create();
      await service.initialize();
      expect(service.downloads, isEmpty);
      expect(service.diagnostics, isEmpty);
      expect(service.subtitleSegmentation, SubtitleSegmentationOptions.natural);
      expect(service.asrEnhancements.denoise, isFalse);
      expect(service.asrEnhancements.toJson(), isNot(contains('diarization')));
      expect(await oldWeight.readAsBytes(), [1, 2, 3]);
      await service.save();
      final saved = jsonDecode(await record.readAsString()) as Map;
      expect(saved['downloads'], isEmpty);
      expect(
        (saved['asrEnhancements'] as Map).containsKey('diarization'),
        isFalse,
      );

      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      final frozen = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'old-local',
          name: 'old',
          kind: TranscriptionServiceKind.local,
          model: model.id,
        ),
        asrEnhancements: const AsrEnhancementOptions(
          denoise: false,
          alignment: false,
          punctuation: false,
        ),
        enhancementModels: {
          for (final id in retiredAsrModelIds) id: '$id@old-revision',
        },
      );
      expect(
        await service.usingAsrModels(
          frozen,
          (_, _, dependencies) async => dependencies,
        ),
        isEmpty,
      );
    },
  );

  test('iOS retirement pauses the two original background transfer keys', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosModelDownload.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosModelDownload.channel, null),
    );
    for (final id in retiredAsrModelIds) {
      await IosModelDownload.pauseRetiredSpeakerDownload(id);
    }
    await IosModelDownload.pauseRetiredSpeakerDownload('parakeet-v3-int8');
    expect(calls.map((c) => c.method), ['pause', 'pause']);
    expect(calls.map((c) => (c.arguments as Map)['key']), [
      'asr-speaker-segmentation-int8@9403a6902bb58e3d5ae8c7e77c3422de279db2e0:model.int8.onnx',
      'asr-speaker-campplus@8be2a75c9ed7a590538b268e46fbb65e1aa9d208:model.onnx',
    ]);
  });

  test(
    'Parakeet does not reuse raw checkpoints with incomplete TDT token times',
    () {
      ModelJobSpec spec(String modelId) => ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'local',
          name: 'local',
          kind: TranscriptionServiceKind.local,
          model: modelId,
        ),
      );
      final parakeet = spec('parakeet-v3-int8');
      expect(
        jsonDecode(parakeet.recognitionFingerprint)['tokenTiming'],
        'tdt-frame-groups-v2',
      );
      expect(
        parakeet.recognitionCacheFingerprints.first,
        parakeet.recognitionFingerprint,
      );
      // Thread-budget migration is safe only for checkpoints with the fixed
      // TDT timing format. No accepted legacy key may omit that marker.
      for (final key in parakeet.recognitionCacheFingerprints) {
        expect(jsonDecode(key)['tokenTiming'], 'tdt-frame-groups-v2');
      }
      expect(
        parakeet.recognitionCacheFingerprints
            .map((key) => jsonDecode(key)['threads'])
            .whereType<int>()
            .toSet(),
        {1, 2, 3, 4},
      );
      final sensevoice = spec('sensevoice-small-int8');
      expect(
        jsonDecode(sensevoice.recognitionFingerprint)['tokenTiming'],
        isNull,
      );
      expect(
        sensevoice.recognitionCacheFingerprints
            .map((key) => jsonDecode(key))
            .where((key) => key.containsKey('translation'))
            .map((key) => key['threads'])
            .toSet(),
        {1, 2, 3, 4},
      );
    },
  );
  test(
    'download is application owned and survives removing observers',
    () async {
      final service = create();
      await service.initialize();
      void listener() {}
      service.addListener(listener);
      await service.enqueue(model.id);
      service.removeListener(listener);
      await until(() => service.installed(model.id));
      final file = File(
        p.join((await service.modelDirectory(model)).path, 'model.gguf'),
      );
      expect(await file.readAsBytes(), bytes);
      await service.save();
      final restored = create();
      await restored.initialize();
      expect(restored.installed(model.id), isTrue);
    },
  );
  test(
    'explicit pause persists and new service resumes with Range and validator',
    () async {
      final adapter = _Transfer(bytes, slow: true);
      final first = create(transfer: adapter);
      await first.initialize();
      await first.enqueue(model.id);
      await until(() => first.downloads[model.id]!.received >= 256);
      await first.pauseAll();
      final second = create(transfer: adapter);
      await second.initialize();
      expect(second.downloads[model.id]!.phase, ModelDownloadPhase.paused);
      await second.enqueue(model.id);
      await until(() => second.installed(model.id));
      expect(adapter.offsets.any((offset) => offset > 0), isTrue);
      expect(
        await File(
          p.join((await second.modelDirectory(model)).path, 'model.gguf'),
        ).readAsBytes(),
        bytes,
      );
    },
  );
  test(
    'changed server entity restarts rather than appending mixed content',
    () async {
      final adapter = _Transfer(bytes, slow: true);
      final service = create(transfer: adapter);
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.downloads[model.id]!.received >= 256);
      await service.pauseAll();
      adapter.changed = true;
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      expect(
        await File(
          p.join((await service.modelDirectory(model)).path, 'model.gguf'),
        ).readAsBytes(),
        bytes,
      );
    },
  );
  test('incomplete transfer never becomes installed', () async {
    final service = create(transfer: _Transfer(bytes, truncated: true));
    await service.initialize();
    await service.enqueue(model.id);
    await until(
      () => service.downloads[model.id]!.phase == ModelDownloadPhase.failed,
    );
    expect(service.installed(model.id), isFalse);
    expect(
      await File(
        p.join((await service.modelDirectory(model)).path, 'installed.json'),
      ).exists(),
      isFalse,
    );
  });
  test(
    'downloads and use do not scan content; full hashing is manual',
    () async {
      final transfer = _Transfer(bytes, corrupt: true);
      final service = create(transfer: transfer);
      await service.initialize();
      final phases = <ModelDownloadPhase>[];
      service.addListener(() {
        if (service.downloads[model.id] case final download?) {
          phases.add(download.phase);
        }
      });
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      expect(phases, isNot(contains(ModelDownloadPhase.verifying)));
      expect(service.downloads[model.id]!.checkedAt, isNull);
      expect(service.downloads[model.id]!.message, contains('可直接使用'));
      expect(
        await service.usingModel(model.id, (_, _) async => 'loaded'),
        'loaded',
      );
      await service.save();
      final restored = create();
      await restored.initialize();
      expect(restored.installed(model.id), isTrue);
      await expectLater(service.verify(model.id), throwsStateError);
      expect(phases, contains(ModelDownloadPhase.verifying));
      transfer.corrupt = false;
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      await service.pauseAll();
      expect(
        await File(
          p.join((await service.modelDirectory(model)).path, 'model.gguf'),
        ).readAsBytes(),
        bytes,
      );
    },
  );
  for (final scenario in ['resume', 'corrupt prefix', 'range ignored']) {
    test(
      'source failover handles $scenario without a post-download scan',
      () async {
        model = ModelArtifact.fromJson({
          'id': model.id,
          'name': model.name,
          'engine': model.engine,
          'revision': model.revision,
          'parameters': model.parameters,
          'quantization': model.quantization,
          'languages': model.languages,
          'description': model.description,
          'license': model.license,
          'homepage': model.homepage,
          'purpose': model.purpose.name,
          'suggestedRamGb': model.suggestedRamGb,
          'memoryNote': model.memoryNote,
          'files': [
            {
              'name': model.files.first.name,
              'bytes': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
              'sources': {
                'official': 'https://official.test/model.gguf',
                'mirror': 'https://mirror.test/model.gguf',
              },
            },
          ],
        });
        final adapter = _SourceTransfer(
          bytes,
          corruptPrefix: scenario == 'corrupt prefix',
          ignoreRange: scenario == 'range ignored',
        );
        final service = create(adapter: adapter);
        await service.initialize();
        service.sourcePreference = 'official';
        await service.enqueue(model.id);
        await until(
          () =>
              service.installed(model.id) ||
              service.downloads[model.id]!.phase == ModelDownloadPhase.failed,
        );
        expect(
          service.installed(model.id),
          isTrue,
          reason: service.downloads[model.id]!.message,
        );
        final mirrors = adapter.requests
            .where((r) => r.uri.host == 'mirror.test')
            .toList();
        expect(mirrors.first.headers['Range'], 'bytes=1024-');
        expect(mirrors.first.headers.containsKey('If-Range'), isFalse);
        if (scenario == 'corrupt prefix') {
          expect(mirrors, hasLength(1));
        }
        final received = [...bytes];
        if (scenario == 'corrupt prefix') received[0] ^= 1;
        expect(
          await File(
            p.join(
              (await service.modelDirectory(model)).path,
              model.files.first.name,
            ),
          ).readAsBytes(),
          received,
        );
        if (scenario == 'corrupt prefix') {
          await expectLater(service.verify(model.id), throwsStateError);
        }
      },
    );
  }
  test(
    'OCR captures its own source choice and restores it independently',
    () async {
      final ocr = ModelArtifact(
        id: 'ocr-fixture',
        name: 'OCR component',
        engine: 'ppocr',
        revision: model.revision,
        parameters: 'upstream',
        quantization: 'FP32',
        languages: ['zh'],
        description: 'test',
        license: 'Apache-2.0',
        homepage: 'https://example.com',
        purpose: ModelPurpose.ocr,
        suggestedRamGb: 4,
        memoryNote: 'test',
        files: [
          ModelFile(
            name: 'inference.onnx',
            bytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
            sources: {
              'official': 'https://official.test/model.gguf',
              'mirror': 'https://mirror.test/model.gguf',
            },
          ),
        ],
      );
      final adapter = _SourceTransfer(bytes);
      final service = create(adapter: adapter, catalog: [ocr]);
      await service.initialize();
      service.sourcePreference = 'official';
      service.ocrSourcePreference = 'mirror';
      await service.enqueue(ocr.id);
      await until(
        () =>
            service.installed(ocr.id) ||
            service.downloads[ocr.id]!.phase == ModelDownloadPhase.failed,
      );
      expect(
        service.installed(ocr.id),
        isTrue,
        reason: service.downloads[ocr.id]!.message,
      );
      expect(adapter.requests.first.uri.host, 'mirror.test');
      expect(service.downloads[ocr.id]!.sourcePreference, 'mirror');
      expect(service.sourcePreference, 'official');
      await service.shutdown();
      final restored = create(catalog: [ocr]);
      await restored.initialize();
      expect(restored.ocrSourcePreference, 'mirror');
      expect(restored.sourcePreference, 'official');
      expect(restored.downloads[ocr.id]!.sourcePreference, 'mirror');
      expect(restored.installed(ocr.id), isTrue);
    },
  );
  test(
    'model lease blocks deletion and profiles persist without credentials',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      final hold = Completer<void>();
      final acquired = Completer<void>();
      final run = service.usingModel(model.id, (_, _) async {
        acquired.complete();
        await hold.future;
      });
      await acquired.future;
      await expectLater(service.remove(model.id), throwsStateError);
      hold.complete();
      await run;
      const profile = ModelServiceProfile(
        id: 'paid',
        name: '付费',
        kind: TranscriptionServiceKind.openai,
        endpoint: 'https://example.com/v1/audio/transcriptions',
        model: 'one',
      );
      await service.saveProfile(profile, secret: 'private-test-secret');
      service.asrProfileId = profile.id;
      await service.settingsChanged();
      final spec = await service.captureTranscription();
      await service.saveProfile(
        const ModelServiceProfile(
          id: 'paid',
          name: '改动',
          kind: TranscriptionServiceKind.openai,
          model: 'two',
        ),
      );
      expect(spec.profile.model, 'one');
      final record = await (await storage.dataRecord(
        'model_center.json',
      )).readAsString();
      expect(record, isNot(contains('private-test-secret')));
      expect(await service.readSecret(profile.id), 'private-test-secret');
    },
  );
  test(
    'cancelled local translation resumes only validated lines and preserves order',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      service.translationModelId = model.id;
      final cancelled = Completer<void>();
      final calls = <String>[];
      final translator = LocalSubtitleTranslator(
        center: service,
        scheduler: InferenceScheduler(),
        complete: (text, context, target, glossary, _) async {
          calls.add(text);
          if (text == 'third') {
            cancelled.complete();
          }
          return '译：$text';
        },
      );
      await expectLater(
        translator.translate(
          texts: const ['first', '', 'second', 'third'],
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '中文',
          onProgress: (_) {},
          cancelSignal: cancelled.future,
        ),
        throwsStateError,
      );
      final resumedCalls = <String>[];
      final resumed = LocalSubtitleTranslator(
        center: service,
        scheduler: InferenceScheduler(),
        complete: (text, context, target, glossary, _) async {
          resumedCalls.add(text);
          return '译：$text';
        },
      );
      final output = await resumed.translate(
        texts: const ['first', '', 'second', 'third'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        onProgress: (_) {},
      );
      expect(resumedCalls, ['third']);
      expect(output, ['译：first', '', '译：second', '译：third']);
      resumedCalls.clear();
      await resumed.translate(
        texts: const ['first', '', 'second', 'third'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        onProgress: (_) {},
        resume: false,
      );
      expect(resumedCalls, ['first', 'second', 'third']);
      resumedCalls.clear();
      await resumed.translate(
        texts: const ['first', '', 'second', 'third'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        onProgress: (_) {},
        checkpointScope: 'fresh-transcription',
      );
      expect(resumedCalls, ['first', 'second', 'third']);
      resumedCalls.clear();
      await resumed.translate(
        texts: const ['first', '', 'second', 'third'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        onProgress: (_) {},
        checkpointScope: 'fresh-transcription',
      );
      expect(resumedCalls, isEmpty);
    },
  );
  test(
    'native audio contract rejects stereo/wrong rate and preserves Unicode chunks',
    () {
      expect(() => decodeModelWave(Uint8List(44)), throwsFormatException);
      final text = '😀字幕。' * 250;
      expect(splitLocalTranslationText(text).join(), text);
      expect(
        () => validateLocalTranslation('<i>hello</i>', '你好'),
        throwsFormatException,
      );
    },
  );
  test(
    'local translation batches preserve cue order, blanks, markup and multiline text',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      service.translationModelId = model.id;
      service.translationOptions = const LocalTranslationOptions(batchSize: 4);
      final calls = <List<String>>[];
      final input = [
        'one',
        '',
        '<i>two</i>\nsecond line',
        'three',
        'four',
        'five',
        'six',
        'seven',
      ];
      final progress = <double>[];
      final output =
          await LocalSubtitleTranslator(
            center: service,
            scheduler: InferenceScheduler(),
            completeBatch: (texts, _, target, glossary, cancel) async {
              calls.add(texts.values.toList());
              return texts.entries
                  .toList()
                  .reversed
                  .map((e) => jsonEncode([e.key, '译：${e.value}']))
                  .join('\n');
            },
          ).translate(
            texts: input,
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '中文',
            onProgress: progress.add,
          );
      expect(calls.map((c) => c.length), [4, 3]);
      expect(output, input.map((s) => s.isEmpty ? '' : '译：$s').toList());
      expect(progress.last, 1);
      expect(progress, orderedEquals([...progress]..sort()));
    },
  );
  test(
    'batch repair retries only missing, duplicate or unprotected rows',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      service.translationModelId = model.id;
      final calls = <List<int>>[];
      final output =
          await LocalSubtitleTranslator(
            center: service,
            scheduler: InferenceScheduler(),
            completeBatch: (texts, _, target, glossary, cancel) async {
              calls.add(texts.keys.toList());
              if (calls.length == 1) {
                return '[0,"译：zero"]\n[1,"重复甲"]\n[1,"重复乙"]\n[2,"译：two"]\n[4,"缺少标签"]\n[5,"译：five"]';
              }
              return texts.entries
                  .map((e) => jsonEncode([e.key, '译：${e.value}']))
                  .join('\n');
            },
          ).translate(
            texts: const ['zero', 'one', 'two', 'three', '<i>four</i>', 'five'],
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '中文',
            onProgress: (_) {},
          );
      expect(calls, [
        [0, 1, 2, 3, 4, 5],
        [1, 3],
        [4],
      ]);
      expect(output, [
        '译：zero',
        '译：one',
        '译：two',
        '译：three',
        '译：<i>four</i>',
        '译：five',
      ]);
    },
  );
  test(
    'cancelled batches resume completed work after changing performance settings',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      service.translationModelId = model.id;
      service.translationOptions = const LocalTranslationOptions(batchSize: 2);
      final cancel = Completer<void>();
      var requests = 0;
      final translator = LocalSubtitleTranslator(
        center: service,
        scheduler: InferenceScheduler(),
        completeBatch: (texts, _, target, glossary, signal) async {
          if (++requests == 2) cancel.complete();
          return texts.entries
              .map((e) => jsonEncode([e.key, '译：${e.value}']))
              .join('\n');
        },
      );
      await expectLater(
        translator.translate(
          texts: const ['one', 'two', 'three', 'four'],
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '中文',
          onProgress: (_) {},
          cancelSignal: cancel.future,
        ),
        throwsStateError,
      );
      service.translationOptions = const LocalTranslationOptions(
        batchSize: 8,
        threads: 4,
        acceleration: TranslationAcceleration.cpu,
      );
      final repeated = <String>[];
      final output =
          await LocalSubtitleTranslator(
            center: service,
            scheduler: InferenceScheduler(),
            completeBatch: (texts, _, target, glossary, signal) async {
              repeated.addAll(texts.values);
              return texts.entries
                  .map((e) => jsonEncode([e.key, '译：${e.value}']))
                  .join('\n');
            },
          ).translate(
            texts: const ['one', 'two', 'three', 'four'],
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '中文',
            onProgress: (_) {},
          );
      expect(repeated, ['three', 'four']);
      expect(output, ['译：one', '译：two', '译：three', '译：four']);
    },
  );
  test(
    'original per-cue checkpoints migrate without retranslating valid cues',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      service.translationModelId = model.id;
      final specification = await captureLocalTranslation(service);
      final oldSpec = specification.toJson()..remove('translation');
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'texts': ['one', 'two'],
                'source': 'en',
                'target': 'zh-CN',
                'spec': oldSpec,
                'prompt': '',
              }),
            ),
          )
          .toString();
      final jobs = await storage.featureDirectory('model_jobs');
      await writeStorageJson(File(p.join(jobs.path, 'translation-$key.json')), {
        'translations': {'0': '已完成'},
      });
      service.threads = 3; // The original v1 checkpoint was written with 2.
      final calls = <String>[];
      final translator = LocalSubtitleTranslator(
        center: service,
        scheduler: InferenceScheduler(),
        complete: (text, _, target, glossary, cancel) async {
          calls.add(text);
          return '译：$text';
        },
      );
      final output = await translator.translate(
        texts: const ['one', 'two'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        onProgress: (_) {},
      );
      expect(calls, ['two']);
      expect(output, ['已完成', '译：two']);
      calls.clear();
      await translator.translate(
        texts: const ['one', 'two'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '中文',
        glossary: '不同术语',
        onProgress: (_) {},
      );
      expect(calls, ['one', 'two']);
    },
  );
  test(
    'cloud providers normalize time units without inventing missing timestamps',
    () {
      final open = parseCloudCues({
        'segments': [
          {'start': 1.5, 'end': 2.5, 'text': 'hello'},
        ],
      }, TranscriptionServiceKind.openai);
      final tencent = parseCloudCues({
        'code': 0,
        'flash_result': [
          {
            'sentence_list': [
              {'start_time': 1500, 'end_time': 2500, 'text': 'hello'},
            ],
          },
        ],
      }, TranscriptionServiceKind.tencent);
      final ali = parseCloudCues({
        'transcripts': [
          {
            'sentences': [
              {'begin_time': 1500, 'end_time': 2500, 'text': 'hello'},
            ],
          },
        ],
      }, TranscriptionServiceKind.aliyun);
      expect(open.single.startTime, tencent.single.startTime);
      expect(open.single.endTime, ali.single.endTime);
      expect(
        () => parseCloudCues({
          'text': 'no timing',
        }, TranscriptionServiceKind.openai),
        throwsFormatException,
      );
      expect(tencentSignatureQuery({'b': '2', 'a': '1'}), 'a=1&b=2');
    },
  );

  test('native token boundaries align conservatively and retain Unicode', () {
    final spans = alignModelTokens(
      text: '你好 world',
      tokens: ['你', '好', '▁world'],
      starts: [0, .2, .5],
      cueEnd: 1,
      offset: 2,
    );
    expect(spans, isEmpty); // Offset places the tokens beyond this cue.
    final timed = alignModelTokens(
      text: '你好 world',
      tokens: ['你', '好', '▁world'],
      starts: [0, .2, .5],
      cueEnd: 3,
      offset: 2,
    );
    expect(timed.length, 3);
    expect(timed.last.textStart, 3);
    expect(timed.last.endTime, const Duration(seconds: 3));
    expect(
      alignModelTokens(text: '50', tokens: ['fifty'], starts: [0], cueEnd: 1),
      isEmpty,
    );
  });

  test(
    'offline import preserves the installed files when source files are incomplete',
    () async {
      final service = create();
      await service.initialize();
      await service.enqueue(model.id);
      await until(() => service.installed(model.id));
      final folder = await Directory(p.join(root.path, 'offline')).create();
      final input = File(p.join(folder.path, 'model.gguf'));
      final target = File(
        p.join((await service.modelDirectory(model)).path, 'model.gguf'),
      );
      await input.writeAsBytes(List<int>.filled(bytes.length - 1, 0));
      await expectLater(
        service.importFiles(model.id, folder),
        throwsStateError,
      );
      expect(await target.readAsBytes(), bytes);
      expect(service.installed(model.id), isTrue);
      final imported = List<int>.filled(bytes.length, 7);
      await input.writeAsBytes(imported);
      await service.importFiles(model.id, folder);
      await service.importFiles(model.id, await service.modelDirectory(model));
      final restored = create();
      await restored.initialize();
      expect(restored.installed(model.id), isTrue);
      expect(restored.downloads[model.id]!.checkedAt, isNull);
      expect(await target.readAsBytes(), imported);
    },
  );

  test(
    'view state and performance choices survive an application restart',
    () async {
      final service = create();
      await service.initialize();
      service.selectedTab = 1;
      expect(
        service.subtitlePunctuation,
        SubtitlePunctuation.removeTrailingFullStopsAndCommas,
      );
      service.subtitlePunctuation = SubtitlePunctuation.removeAll;
      service.search = 'English';
      service.filter = 'translation';
      service.selectedModelId = model.id;
      service.scrollPositions['1'] = 320;
      service.sourcePreference = 'mirror';
      service.selectedLanguage = 'en';
      service.threads = 3;
      service.expandedPerformanceSections.addAll(['asr', 'translation']);
      service.asrExecution = AsrExecutionMode.lowMemory;
      service.translationOptions = const LocalTranslationOptions(
        acceleration: TranslationAcceleration.cpu,
        threads: 4,
        batchSize: 6,
      );
      service.subtitleSegmentation = SubtitleSegmentationOptions.standard
          .copyWith(
            allowEstimatedTiming: true,
            naturalBreaks: true,
            maxLatinWidth: 80,
          );
      service.profiles[ModelCenterService.legacyProfile.id] =
          const ModelServiceProfile(
            id: 'gongyi',
            name: '过时的接口名称',
            kind: TranscriptionServiceKind.gongyi,
          );
      await service.save();
      final restored = create();
      await restored.initialize();
      expect(restored.selectedTab, 1);
      expect(restored.search, 'English');
      expect(restored.filter, 'translation');
      expect(restored.selectedModelId, model.id);
      expect(restored.scrollPositions['1'], 320);
      expect(restored.sourcePreference, 'mirror');
      expect(restored.selectedLanguage, 'en');
      expect(restored.threads, 3);
      expect(restored.expandedPerformanceSections, {'asr', 'translation'});
      expect(restored.asrExecution, AsrExecutionMode.lowMemory);
      expect(
        restored.translationOptions.toJson(),
        service.translationOptions.toJson(),
      );
      expect(restored.subtitleSegmentation, service.subtitleSegmentation);
      expect(restored.subtitlePunctuation, SubtitlePunctuation.removeAll);
      expect(restored.asrProfile.name, '公益接口');
    },
  );

  for (final savedMode in [
    null,
    SubtitlePunctuation.removeTrailingFullStops,
    SubtitlePunctuation.removeTrailingFullStopsAndCommas,
  ]) {
    test(
      'punctuation defaults and saved selection survive restart: $savedMode',
      () async {
        final record = await storage.dataRecord('model_center.json');
        await record.writeAsString(
          jsonEncode({
            if (savedMode != null) 'subtitlePunctuation': savedMode.name,
          }),
        );
        final service = create();
        await service.initialize();
        final expected =
            savedMode ?? SubtitlePunctuation.removeTrailingFullStopsAndCommas;
        expect(service.subtitlePunctuation, expected);
        await service.save();
        await service.shutdown();
        final restored = create();
        await restored.initialize();
        expect(restored.subtitlePunctuation, expected);
      },
    );
  }

  test(
    'an uninstalled ASR binding persists but cannot start inference',
    () async {
      final catalog = await loadModelCatalog();
      final asr = catalog.firstWhere(
        (model) => model.purpose == ModelPurpose.transcription,
      );
      final service = create(catalog: catalog);
      await service.initialize();
      await service.selectAsr(asr);
      expect(service.asrProfile.model, asr.id);
      expect(service.installed(asr.id), isFalse);
      expect(
        service.downloads.keys,
        containsAll(
          service.asrEnhancements.requiredModels(asr.languages, 'auto'),
        ),
      );
      await expectLater(service.captureTranscription(), throwsStateError);
      // A restart closes the first application-owned downloader before opening
      // another service on the same checkpoint; both now have enhancement work.
      await service.shutdown();
      services.remove(service);
      final restored = create(catalog: catalog);
      await restored.initialize();
      expect(restored.asrProfileId, 'local:${asr.id}');
      expect(restored.asrProfile.local, isTrue);
      await expectLater(restored.captureTranscription(), throwsStateError);
    },
  );

  test(
    'recommendations respect memory and documented recognition languages',
    () async {
      final catalog = await loadModelCatalog();
      expect(
        const ModelDeviceInfo(
          memoryBytes: 4 * 1073741824,
          processors: 4,
        ).recommend(catalog, 'zh').map((m) => m.id),
        ['sensevoice-small-int8'],
      );
      final large = const ModelDeviceInfo(
        memoryBytes: 16 * 1073741824,
        processors: 8,
      );
      expect(large.recommend(catalog, 'en').map((m) => m.id), [
        'parakeet-v3-int8',
        'hy-mt2-1.8b-q4',
      ]);
      expect(
        catalog.firstWhere((m) => m.id == 'dolphin-base-int8').languages,
        isNot(contains('en')),
      );
    },
  );

  for (final failure in [
    'network',
    'FAILED',
    'CANCELED',
    'subtask',
    '404',
    '410',
    'result404',
    'result410',
  ]) {
    test(
      'paid polling recovers from $failure without resurrecting invalid backup IDs',
      () async {
        final service = create();
        await service.initialize();
        const profile = ModelServiceProfile(
          id: 'ali',
          name: '百炼',
          kind: TranscriptionServiceKind.aliyun,
          endpoint: 'https://dashscope.aliyuncs.com',
          model: 'fun-asr',
          language: 'ja',
        );
        await service.saveProfile(profile, secret: 'fixture-token');
        var submits = 0, uploads = 0, polls = 0;
        final adapter = _CloudAdapter((options) {
          if (options.uri.path == '/api/v1/uploads') {
            return {
              'data': {
                'upload_dir': 'fixture',
                'oss_access_key_id': 'temporary',
                'signature': 'fixture-signature',
                'policy': 'fixture-policy',
                'upload_host': 'https://upload.example.com/file',
              },
            };
          }
          if (options.uri.host == 'upload.example.com') {
            uploads++;
            return {};
          }
          if (options.method == 'POST') {
            submits++;
            expect((options.data as Map)['parameters']['language_hints'], [
              'ja',
            ]);
            return {
              'output': {'task_id': 'paid-task-$submits'},
            };
          }
          if (options.uri.path.startsWith('/api/v1/tasks/paid-task-')) {
            polls++;
            if (polls == 1 && !failure.startsWith('result')) {
              if (failure == 'FAILED' || failure == 'CANCELED') {
                return {
                  'output': {'task_status': failure},
                };
              }
              if (failure == 'subtask') {
                return {
                  'output': {
                    'task_status': 'SUCCEEDED',
                    'results': [
                      {'subtask_status': 'FAILED', 'message': 'invalid audio'},
                    ],
                  },
                };
              }
              throw DioException(
                requestOptions: options,
                type: failure == 'network'
                    ? DioExceptionType.connectionError
                    : DioExceptionType.badResponse,
                response: failure == 'network'
                    ? null
                    : Response(
                        requestOptions: options,
                        statusCode: int.parse(failure),
                      ),
              );
            }
            expect(
              options.uri.path,
              '/api/v1/tasks/paid-task-${failure == 'network' || polls == 1 ? 1 : 2}',
            );
            return {
              'output': {
                'task_status': 'SUCCEEDED',
                'results': [
                  {
                    'subtask_status': 'SUCCEEDED',
                    'transcription_url': 'https://result.example.com/subtitles',
                  },
                ],
              },
            };
          }
          if (polls == 1 && failure.startsWith('result')) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: int.parse(failure.substring(6)),
              ),
            );
          }
          return {
            'transcripts': [
              {
                'sentences': [
                  {'begin_time': 100, 'end_time': 900, 'text': 'hello'},
                ],
              },
            ],
          };
        });
        final runner = ModelTranscriptionRunner(
          center: service,
          createDio: () => Dio()..httpClientAdapter = adapter,
        );
        Future<List<dynamic>> run() async => runner.run(
          spec: const ModelJobSpec(profile: profile),
          sourceIdentity: 'paid-fixture',
          duration: const Duration(seconds: 1),
          onProgress: (_) {},
          prepareAudio: (_, _, _, _) async {
            final file = File(p.join(root.path, 'cloud.m4a'));
            await file.writeAsBytes([1, 2, 3]);
            return file.path;
          },
        );
        await expectLater(run(), throwsStateError);
        // Simulate a v1 checkpoint whose key also contained translation settings.
        // The provider already accepted this upload; only polling may be retried.
        const oldSpec = ModelJobSpec(profile: profile);
        final jobs = await storage.featureDirectory('model_jobs');
        File checkpointFor(String fingerprint) => File(
          p.join(
            jobs.path,
            'asr-${sha256.convert(utf8.encode('paid-fixture\n$fingerprint'))}.json',
          ),
        );
        final checkpoint = checkpointFor(oldSpec.recognitionFingerprint);
        final previous = checkpointFor(
          oldSpec.recognitionCacheFingerprints.last,
        );
        expect(previous.path, isNot(checkpoint.path));
        if (failure == 'network') {
          await checkpoint.rename(previous.path);
        } else {
          final stale =
              jsonDecode(await checkpoint.readAsString())
                  as Map<String, dynamic>;
          for (final state in (stale['remote'] as Map).values) {
            (state as Map).remove('remoteReset');
            state['taskId'] = 'paid-task-1';
          }
          await previous.writeAsString(jsonEncode(stale));
        }
        final cues = await run();
        expect(cues.single.text, 'hello');
        expect(submits, failure == 'network' ? 1 : 2);
        expect(uploads, failure == 'network' ? 1 : 2);
        expect(polls, 2);
      },
    );
  }

  for (final status in [null, 408, 500, 400, 401, 403, 404, 422, 429]) {
    test(
      'paid submission $status distinguishes rejection from uncertain writes',
      () async {
        final service = create();
        await service.initialize();
        const profile = ModelServiceProfile(
          id: 'ali',
          name: '百炼',
          kind: TranscriptionServiceKind.aliyun,
          endpoint: 'https://dashscope.aliyuncs.com',
          model: 'fun-asr',
        );
        await service.saveProfile(profile, secret: 'fixture-token');
        var submits = 0;
        final adapter = _CloudAdapter((options) {
          if (options.uri.path == '/api/v1/uploads') {
            return {
              'data': {
                'upload_dir': 'fixture',
                'oss_access_key_id': 'key',
                'signature': 'sig',
                'policy': 'policy',
                'upload_host': 'https://upload.example.com/file',
              },
            };
          }
          if (options.uri.host == 'upload.example.com') return {};
          submits++;
          throw DioException(
            requestOptions: options,
            type: status == null
                ? DioExceptionType.receiveTimeout
                : DioExceptionType.badResponse,
            response: status == null
                ? null
                : Response(requestOptions: options, statusCode: status),
          );
        });
        final runner = ModelTranscriptionRunner(
          center: service,
          createDio: () => Dio()..httpClientAdapter = adapter,
        );
        Future<void> run() async {
          await runner.run(
            spec: const ModelJobSpec(profile: profile),
            sourceIdentity: 'uncertain',
            duration: const Duration(seconds: 1),
            onProgress: (_) {},
            prepareAudio: (_, _, _, _) async {
              final file = File(p.join(root.path, 'cloud.m4a'));
              await file.writeAsBytes([1]);
              return file.path;
            },
          );
        }

        await expectLater(run(), throwsStateError);
        final uncertain = status == null || status == 408 || status >= 500;
        await expectLater(
          run(),
          uncertain
              ? throwsA(
                  isA<StateError>().having(
                    (e) => e.message,
                    'reason',
                    contains('避免重复计费'),
                  ),
                )
              : throwsStateError,
        );
        expect(submits, uncertain ? 1 : 2);
      },
    );
  }

  test(
    'unauthenticated compatible local servers retain timed results',
    () async {
      final service = create();
      await service.initialize();
      final adapter = _CloudAdapter((options) {
        expect(options.headers.containsKey('Authorization'), isFalse);
        expect(options.data, isA<FormData>());
        return {
          'segments': [
            {'start': 0.1, 'end': .9, 'text': 'hello'},
          ],
        };
      });
      final cues =
          await ModelTranscriptionRunner(
            center: service,
            createDio: () => Dio()..httpClientAdapter = adapter,
          ).run(
            spec: const ModelJobSpec(
              profile: ModelServiceProfile(
                id: 'local-server',
                name: 'whisper.cpp',
                kind: TranscriptionServiceKind.openai,
                endpoint: 'http://localhost:8080/v1/audio/transcriptions',
                model: 'whisper-1',
              ),
            ),
            sourceIdentity: 'compatible',
            duration: const Duration(seconds: 1),
            onProgress: (_) {},
            prepareAudio: (_, _, _, _) async {
              final file = File(p.join(root.path, 'fixture.wav'));
              await file.writeAsBytes([1]);
              return file.path;
            },
          );
      expect(cues.single.text, 'hello');
    },
  );

  Future<void> advance(WidgetTester tester) async {
    await tester.pump();
    // The service was initialized with real filesystem IO in runAsync. Let
    // callbacks awaiting that cached future complete before the next frame.
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> mountCenter(
    WidgetTester tester,
    ModelCenterService service,
    SubtitleTranslateSettings settings, {
    Size size = const Size(1440, 900),
    double scale = 1,
    int? initialTab,
    bool transcriptionOnly = false,
    GlobalKey? previewKey,
    TranscriptionManager? transcriptions,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const previews = bool.fromEnvironment('MODEL_CENTER_PREVIEWS');
    if (previews) {
      final font = FontLoader('ModelPreview')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await tester.runAsync(font.load);
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await tester.runAsync(icons.load);
    }
    Widget home = ModelCenterScreen(
      service: service,
      translateSettings: settings,
      initialTab: initialTab,
      transcriptionOnly: transcriptionOnly,
      deviceInfo: const ModelDeviceInfo(
        memoryBytes: 16 * 1073741824,
        availableMemoryBytes: 12 * 1073741824,
        processors: 8,
      ),
    );
    if (transcriptions != null) {
      home = ChangeNotifierProvider<TranscriptionManager>.value(
        value: transcriptions,
        child: home,
      );
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.blue,
              surface: Color(0xFF121212),
            ),
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: previews ? 'ModelPreview' : null,
            ),
            appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E)),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester, GlobalKey key, String label) async {
    if (!const bool.fromEnvironment('MODEL_CENTER_PREVIEWS')) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('.artifacts/model-center').create(recursive: true);
      await File(
        '.artifacts/model-center/redesign-$label.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    expect(finder, findsOneWidget);
    await tester.ensureVisible(finder);
    await advance(tester);
    await tester.tap(finder);
    await advance(tester);
  }

  void bindLocal(ModelCenterService service, ModelArtifact model) {
    final profile = ModelServiceProfile(
      id: 'local:${model.id}',
      name: model.name,
      kind: TranscriptionServiceKind.local,
      model: model.id,
    );
    service.profiles[profile.id] = profile;
    service.asrProfileId = profile.id;
  }

  Future<void> closeDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('model-detail-close')));
    await tester.pumpAndSettle();
  }

  test(
    'Qwen download combination matches task dependencies and shares active files',
    () async {
      final catalog = await loadModelCatalog();
      final service = create(view: true, catalog: catalog) as _ViewCenter;
      await service.initialize();
      final models = catalog
          .where(
            (m) =>
                m.purpose == ModelPurpose.transcription &&
                m.engine == 'qwen3-asr',
          )
          .toList();
      final first = models.first, second = models.last;
      bindLocal(service, first);
      final components = service.asrDownloadComponents(first);
      expect(
        components.skip(1).map((m) => m.id).toSet(),
        service.transcriptionConfiguration.enhancementModels.keys.toSet(),
      );
      service.downloads[AsrEnhancementOptions.languageId] = ModelDownload(
        artifactId: AsrEnhancementOptions.languageId,
        phase: ModelDownloadPhase.installed,
      );
      final missing = components
          .where((m) => !service.installed(m.id))
          .map((m) => m.id)
          .toList();
      await service.queueAsrDownload(first);
      expect(service.enqueued, missing);
      service.downloads[first.id]!.received = 123;
      await service.queueAsrDownload(first);
      await service.queueAsrDownload(second);
      expect(service.enqueued, [...missing, second.id]);
      expect(service.downloads[first.id]!.received, 123);
      service.downloads[AsrEnhancementOptions.alignmentQwenId]!.phase =
          ModelDownloadPhase.paused;
      await service.queueAsrDownload(second);
      expect(service.enqueued.last, AsrEnhancementOptions.alignmentQwenId);
      expect(service.enqueued.where((id) => id == second.id), hasLength(1));
      expect(service.installed(AsrEnhancementOptions.languageId), isTrue);
      service.asrEnhancements = service.asrEnhancements.copyWith(
        alignment: false,
      );
      expect(
        service.asrDownloadComponents(second).map((m) => m.id),
        isNot(contains(AsrEnhancementOptions.alignmentQwenId)),
      );
      service.selectedLanguage = 'ja';
      expect(
        service.asrDownloadComponents(second).map((m) => m.id),
        isNot(contains(AsrEnhancementOptions.languageId)),
      );
      service.asrEnhancements = AsrEnhancementOptions.disabled;
      expect(service.asrDownloadComponents(second), [second]);
      service.dispose();
    },
  );

  for (final size in [const Size(320, 800), const Size(1440, 900)]) {
    for (final modelId in ['qwen3-asr-0.6b-f16', 'qwen3-asr-1.7b-f16']) {
      testWidgets(
        'Qwen download discloses components before transfer $modelId at ${size.width}',
        (tester) async {
          final catalog = (await tester.runAsync(loadModelCatalog))!;
          final service = create(view: true, catalog: catalog) as _ViewCenter;
          await tester.runAsync(service.initialize);
          final target = service.artifact(modelId)!;
          service.downloads[AsrEnhancementOptions.languageId] = ModelDownload(
            artifactId: AsrEnhancementOptions.languageId,
            phase: ModelDownloadPhase.installed,
          );
          final settings = SubtitleTranslateSettings();
          await settings.ensureLoaded();
          final originalProfile = service.asrProfileId;
          final key = GlobalKey();
          await mountCenter(
            tester,
            service,
            settings,
            size: size,
            scale: size.width == 320 ? 1.3 : 1,
            previewKey: key,
          );
          await tapVisible(
            tester,
            find.byKey(ValueKey('asr-binding-$originalProfile')),
          );
          await tester.enterText(
            find.byKey(const ValueKey('model-center-picker-search')),
            target.name,
          );
          await advance(tester);
          await tester.tap(
            find.byKey(
              ValueKey(
                modelId.contains('0.6b')
                    ? 'option-download-$modelId'
                    : 'model-center-choice-local:$modelId',
              ),
            ),
          );
          await advance(tester);
          expect(find.byKey(ValueKey('model-detail-$modelId')), findsOneWidget);
          expect(
            service.enqueued,
            isEmpty,
            reason: 'show the download contents before starting transfers',
          );
          expect(service.asrProfileId, originalProfile);
          final components = service.asrDownloadComponents(target);
          for (final part in components.skip(1)) {
            expect(find.text(part.name), findsOneWidget);
          }
          final total = components.fold(0, (n, part) => n + part.bytes);
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('asr-download-total')))
                .data,
            contains(modelBytes(total)),
          );
          final alignmentSwitch = find.byKey(
            const ValueKey('asr-download-alignment'),
          );
          await tester.ensureVisible(alignmentSwitch);
          await advance(tester);
          if (modelId.contains('0.6b')) {
            await tester.tap(alignmentSwitch);
            await advance(tester);
            expect(service.asrEnhancements.alignment, isFalse);
            expect(
              find.text(
                service.artifact(AsrEnhancementOptions.alignmentQwenId)!.name,
              ),
              findsNothing,
            );
            expect(service.enqueued, isEmpty);
          }
          await preview(
            tester,
            key,
            'qwen-${target.parameters}-${size.width.toInt()}-download-contents',
          );
          final expected = service
              .asrDownloadComponents(target)
              .where((m) => !service.installed(m.id))
              .map((m) => m.id)
              .toList();
          final downloadButton = find.byKey(
            ValueKey('model-detail-download-$modelId'),
          );
          await tester.tap(downloadButton);
          await advance(tester);
          expect(service.enqueued, expected);
          service.downloads[target.id]!.phase = ModelDownloadPhase.installed;
          service.notifyListeners();
          await advance(tester);
          expect(
            find.byKey(ValueKey('model-detail-default-$modelId')),
            findsNothing,
            reason: 'the combination still has queued components',
          );
          await tester.tap(find.byKey(ValueKey('model-detail-pause-$modelId')));
          await advance(tester);
          expect(
            service.downloads.values.where(
              (state) => state.phase == ModelDownloadPhase.queued,
            ),
            isEmpty,
          );
          expect(service.installed(AsrEnhancementOptions.languageId), isTrue);
          await tester.tap(downloadButton);
          await advance(tester);
          expect(service.enqueued, [
            ...expected,
            ...expected.where((id) => id != modelId),
          ]);
          for (final part in service.asrDownloadComponents(target)) {
            service.downloads[part.id]!.phase = ModelDownloadPhase.installed;
          }
          service.notifyListeners();
          await advance(tester);
          expect(
            find.byKey(ValueKey('model-detail-default-$modelId')),
            findsOneWidget,
          );
          expect(service.asrProfileId, originalProfile);
          expect(tester.takeException(), isNull);
          await closeDetails(tester);
          await tester.pumpWidget(const SizedBox());
          settings.dispose();
        },
      );
    }
  }

  testWidgets(
    'model checks enter inference directly; hashing is a separate action',
    (tester) async {
      final service = _ProbeCenter(
        storage: storage,
        catalogLoader: () async => [model],
        secrets: secrets,
      );
      await tester.runAsync(service.initialize);
      service.downloads[model.id] = ModelDownload(
        artifactId: model.id,
        phase: ModelDownloadPhase.installed,
      );
      service.selectedTab = 1;
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ModelCenterScreen(
            service: service,
            translateSettings: settings,
            deviceInfo: const ModelDeviceInfo(processors: 4),
            initialTab: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.installed(model.id), isTrue);
      expect(find.text(model.name), findsWidgets);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('本机推理检查'));
        await until(() => service.checking.isEmpty);
      });
      await tester.pumpAndSettle();
      expect(service.inferenceCalls, 1);
      expect(service.fileChecks, 0);
      expect(service.diagnostics[model.id], contains('已直接进入推理'));
      expect(service.installed(model.id), isTrue);

      await tester.tap(find.byKey(ValueKey('model-library-${model.id}')));
      await advance(tester);
      await tapVisible(tester, find.text('模型工具'));
      await tester.ensureVisible(find.text('本机推理检查'));
      await tester.runAsync(() async {
        await tester.tap(find.text('本机推理检查'));
        await until(() => service.checking.isEmpty);
      });
      await tester.pumpAndSettle();
      expect(service.inferenceCalls, 2);
      expect(service.fileChecks, 0);

      await tester.ensureVisible(find.text('手动校验文件'));
      await tester.tap(find.text('手动校验文件'));
      await tester.pumpAndSettle();
      expect(service.fileChecks, 1);
      expect(service.inferenceCalls, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  for (final size in [const Size(360, 800), const Size(1440, 900)]) {
    for (final purpose in [
      ModelPurpose.transcription,
      ModelPurpose.translation,
    ]) {
      testWidgets(
        '${purpose.name} download opens exact detail at ${size.width}',
        (tester) async {
          final catalog = (await tester.runAsync(loadModelCatalog))!;
          final service = create(view: true, catalog: catalog) as _ViewCenter;
          await tester.runAsync(service.initialize);
          final settings = SubtitleTranslateSettings();
          await settings.ensureLoaded();
          if (purpose == ModelPurpose.translation) {
            await settings.setProviderEnZh(SubtitleTranslateProvider.local);
          }
          // Existing model download shortcuts retain their one-click behavior.
          // Qwen's larger shared combination has separate disclosure coverage.
          final target = catalog.lastWhere(
            (model) => model.purpose == purpose && model.engine != 'qwen3-asr',
          );
          service.search = 'does-not-match-the-target';
          service.filter = 'enhancement';
          service.selectedModelId = catalog.first.id;
          service.scrollPositions['1'] = 900;
          final originalAsr = service.asrProfileId;
          final originalModel = service.translationModelId;
          final originalProvider = settings.providerEnZh;
          final key = GlobalKey();
          await mountCenter(
            tester,
            service,
            settings,
            size: size,
            previewKey: key,
          );

          Future<void> openDownload() async {
            final field = purpose == ModelPurpose.transcription
                ? ValueKey('asr-binding-${service.asrProfileId}')
                : ValueKey('translation-model-${service.translationModelId}');
            await tapVisible(tester, find.byKey(field));
            await tester.enterText(
              find.byKey(const ValueKey('model-center-picker-search')),
              target.name,
            );
            await advance(tester);
            await tester.tap(
              find.byKey(ValueKey('option-download-${target.id}')),
            );
            await advance(tester);
            expect(
              find.byKey(ValueKey('model-detail-${target.id}')),
              findsOneWidget,
            );
            expect(service.selectedTab, 0);
            expect(service.asrProfileId, originalAsr);
            expect(service.translationModelId, originalModel);
            expect(settings.providerEnZh, originalProvider);
            expect(service.search, 'does-not-match-the-target');
            expect(service.filter, 'enhancement');
            expect(tester.takeException(), isNull);
          }

          await openDownload();
          expect(service.enqueued, [target.id]);
          expect(
            service.downloads[target.id]!.phase,
            ModelDownloadPhase.queued,
          );
          final detailRect = tester.getRect(
            find.byKey(ValueKey('model-detail-${target.id}')),
          );
          expect(detailRect.width, size.width >= 1000 ? 420 : size.width);
          expect(detailRect.right, size.width);
          await closeDetails(tester);

          await openDownload();
          expect(
            service.enqueued,
            [target.id],
            reason: 'queued transfers must not be enqueued twice',
          );
          service.downloads[target.id]!.phase = ModelDownloadPhase.downloading;
          service.downloads[target.id]!.received = target.bytes ~/ 3;
          service.notifyListeners();
          await advance(tester);
          await preview(
            tester,
            key,
            '${size.width.toInt()}-${purpose.name}-download',
          );
          await tester.tap(
            find.byKey(ValueKey('model-detail-pause-${target.id}')),
          );
          await advance(tester);
          expect(
            service.downloads[target.id]!.phase,
            ModelDownloadPhase.paused,
          );
          expect(find.text('继续下载'), findsOneWidget);
          await tester.tap(
            find.byKey(ValueKey('model-detail-download-${target.id}')),
          );
          await advance(tester);
          expect(service.enqueued, [target.id, target.id]);
          service.downloads[target.id]!.phase = ModelDownloadPhase.failed;
          service.downloads[target.id]!.message = '测试连接失败';
          service.notifyListeners();
          await advance(tester);
          expect(find.text('重试下载'), findsOneWidget);
          expect(find.text('测试连接失败'), findsOneWidget);
          await tester.tap(
            find.byKey(ValueKey('model-detail-download-${target.id}')),
          );
          await advance(tester);
          expect(service.enqueued, [target.id, target.id, target.id]);
          service.downloads[target.id]!.phase = ModelDownloadPhase.installed;
          service.notifyListeners();
          await advance(tester);
          expect(
            find.byKey(ValueKey('model-detail-default-${target.id}')),
            findsOneWidget,
          );
          expect(settings.providerEnZh, originalProvider);
          expect(service.asrProfileId, originalAsr);
          await closeDetails(tester);
          await tester.pumpWidget(const SizedBox());
          service.selectedTab = 3;
          await mountCenter(tester, service, settings, size: size);
          expect(service.selectedTab, 0);
          expect(find.text('默认转录服务'), findsOneWidget);
          expect(
            find.byKey(ValueKey('model-detail-${target.id}')),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox());
          settings.dispose();
        },
      );
    }
  }
  testWidgets(
    'local settings show useful recommendations and restore only their own performance',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      final asr = catalog.firstWhere(
        (m) => m.purpose == ModelPurpose.transcription,
      );
      bindLocal(service, asr);
      service.asrExecution = AsrExecutionMode.lowMemory;
      service.asrCpuThreads = 2;
      service.asrAccelerationOptions[asr.id] = AsrAcceleration.gpu;
      service.translationOptions = const LocalTranslationOptions(
        threads: 3,
        batchSize: 4,
      );
      final enhancements = service.asrEnhancements;
      final segmentation = service.subtitleSegmentation;
      await mountCenter(
        tester,
        service,
        settings,
        size: const Size(320, 720),
        scale: 1.5,
      );
      expect(find.textContaining('个逻辑核心'), findsNothing);
      expect(
        find.byKey(const ValueKey('asr-thread-recommendation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('translation-thread-recommendation')),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('本地转录设置'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-translation-acceleration')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('asr-execution-mode')), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('restore-asr-performance')),
      );
      expect(service.asrCpuThreads, 0);
      expect(service.asrExecution, AsrExecutionMode.auto);
      expect(service.asrAccelerationFor(asr.id), AsrAcceleration.auto);
      expect(service.translationOptions.threads, 3);
      expect(service.translationOptions.batchSize, 4);
      expect(service.asrEnhancements, enhancements);
      expect(service.subtitleSegmentation, segmentation);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('本地翻译设置'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('asr-acceleration-${asr.id}')), findsNothing);
      expect(
        find.byKey(const ValueKey('local-translation-threads')),
        findsNothing,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('restore-translation-performance')),
      );
      expect(service.translationOptions.threads, 0);
      expect(service.translationOptions.batchSize, 8);
      expect(service.asrExecution, AsrExecutionMode.auto);
      expect(service.asrEnhancements, enhancements);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-terminology')),
      );
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('model-center-terminology')),
      );
      input.controller!.value = const TextEditingValue(
        text: '正在编辑的术语',
        composing: TextRange(start: 0, end: 7),
      );
      service.notifyListeners();
      await advance(tester);
      expect(input.controller!.text, '正在编辑的术语');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets('configuration is conditional and remembers local choices', (
    tester,
  ) async {
    final catalog = (await tester.runAsync(loadModelCatalog))!;
    final service = create(view: true, catalog: catalog);
    await tester.runAsync(service.initialize);
    final settings = SubtitleTranslateSettings();
    await settings.ensureLoaded();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      AiSubtitleApiSettings.preferencesKey,
      jsonEncode(
        const AiSubtitleApiSettings(
          baseUrl: 'http://localhost:11434/v1',
          model: 'qwen3:4b',
        ).toJson(),
      ),
    );
    await mountCenter(tester, service, settings, size: const Size(390, 844));
    final originalModel = service.translationModelId;
    service.translationOptions = service.translationOptions.copyWith(
      threads: 4,
      gpuLayers: 16,
    );
    for (final provider in SubtitleTranslateProvider.values) {
      await settings.setProviderEnZh(provider);
      await advance(tester);
      expect(
        find.byKey(ValueKey('translation-model-$originalModel')),
        provider == SubtitleTranslateProvider.local
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('model-center-ai-binding')),
        provider == SubtitleTranslateProvider.ai
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.byKey(const PageStorageKey('local-translation-settings')),
        provider == SubtitleTranslateProvider.local
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.byKey(const PageStorageKey('ai-translation-settings')),
        provider == SubtitleTranslateProvider.ai
            ? findsOneWidget
            : findsNothing,
      );
      if (provider == SubtitleTranslateProvider.ai) {
        expect(find.textContaining('Ollama 本地 · qwen3:4b'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('local-translation-acceleration')),
          findsNothing,
        );
      }
      expect(service.translationModelId, originalModel);
      expect(service.translationOptions.threads, 4);
      expect(tester.takeException(), isNull);
    }

    for (final kind in TranscriptionServiceKind.values) {
      final localModel = catalog.firstWhere(
        (model) => model.purpose == ModelPurpose.transcription,
      );
      final profile = ModelServiceProfile(
        id: 'test-${kind.name}',
        name: '测试服务',
        kind: kind,
        model: localModel.id,
      );
      service.profiles[profile.id] = profile;
      service.asrProfileId = profile.id;
      service.notifyListeners();
      await advance(tester);
      expect(
        find.byKey(const PageStorageKey('local-asr-settings')),
        kind == TranscriptionServiceKind.local ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(const ValueKey('open-asr-enhancements')), findsNothing);
      expect(find.byKey(const ValueKey('asr-execution-mode')), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets(
    'download preserves configuration scroll and expansion, enabling is explicit',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      final model = catalog.firstWhere(
        (model) => model.purpose == ModelPurpose.translation,
      );
      service.translationModelId = model.id;
      await mountCenter(tester, service, settings, size: const Size(360, 800));
      await tapVisible(tester, find.text('本地翻译设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('selected-download-${model.id}')),
      );
      await advance(tester);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('local-translation-scroll')),
          )
          .controller!;
      final before = scroll.offset;
      await tester.tap(find.byKey(ValueKey('selected-download-${model.id}')));
      await advance(tester);
      await closeDetails(tester);
      expect(scroll.offset, closeTo(before, .1));
      expect(
        find.byKey(const ValueKey('local-translation-acceleration')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());

      await settings.setProviderEnZh(SubtitleTranslateProvider.bing);
      service.downloads[model.id] = ModelDownload(
        artifactId: model.id,
        phase: ModelDownloadPhase.installed,
      );
      service.search = model.name;
      service.filter = 'all';
      await mountCenter(tester, service, settings, initialTab: 1);
      await tester.tap(find.byKey(ValueKey('model-library-${model.id}')));
      await advance(tester);
      expect(settings.providerEnZh, SubtitleTranslateProvider.bing);
      await tester.tap(
        find.byKey(ValueKey('model-detail-default-${model.id}')),
      );
      await tester.pumpAndSettle();
      expect(settings.providerEnZh, SubtitleTranslateProvider.local);
      expect(service.translationModelId, model.id);
      expect(find.byKey(ValueKey('model-detail-${model.id}')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('默认翻译服务'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets(
    'management restores filters, list position and configuration expansion',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      bindLocal(
        service,
        catalog.firstWhere(
          (model) => model.purpose == ModelPurpose.transcription,
        ),
      );
      await mountCenter(tester, service, settings, size: const Size(360, 800));
      await tapVisible(tester, find.text('本地转录设置'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('高级设置'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-1')),
      );
      await tester.drag(
        find.byKey(const PageStorageKey('model-center-models')),
        const Offset(0, -400),
      );
      await advance(tester);
      final offset = service.scrollPositions['1']!;
      expect(offset, greaterThan(0));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('本地转录设置'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('open-asr-enhancements')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('asr-execution-mode')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-1')),
      );
      expect(service.scrollPositions['1'], closeTo(offset, .1));
      await tester.tap(
        find.byKey(const ValueKey('model-center-filter-translation')),
      );
      await advance(tester);
      await tester.enterText(
        find.byKey(const ValueKey('model-center-library-search')),
        'Qwen',
      );
      await advance(tester);
      expect(find.text('Qwen3 4B'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-1')),
      );
      expect(service.filter, 'translation');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('model-center-library-search')),
            )
            .controller!
            .text,
        'Qwen',
      );
      expect(find.text('Qwen3 4B'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets('details adapt to resizing and handle a removed catalog item', (
    tester,
  ) async {
    final catalog = (await tester.runAsync(loadModelCatalog))!;
    final service = create(view: true, catalog: catalog);
    await tester.runAsync(service.initialize);
    final settings = SubtitleTranslateSettings();
    await settings.ensureLoaded();
    await mountCenter(tester, service, settings, initialTab: 1);
    final model = catalog.first;
    await tester.tap(find.byKey(ValueKey('model-library-${model.id}')));
    await advance(tester);
    expect(
      tester.getSize(find.byKey(ValueKey('model-detail-${model.id}'))).width,
      420,
    );
    tester.view.physicalSize = const Size(390, 844);
    await advance(tester);
    expect(
      tester.getSize(find.byKey(ValueKey('model-detail-${model.id}'))).width,
      390,
    );
    service.catalog = catalog.where((item) => item.id != model.id).toList();
    service.notifyListeners();
    await advance(tester);
    expect(find.text('模型不可用'), findsOneWidget);
    expect(find.textContaining('此模型已不在当前模型库中'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  for (final size in const [Size(320, 740), Size(1440, 900)]) {
    testWidgets('transcription settings edits shared defaults at $size', (
      tester,
    ) async {
      final service = create(view: true, catalog: []);
      await tester.runAsync(service.initialize);
      service.profiles['test-asr'] = const ModelServiceProfile(
        id: 'test-asr',
        name: '测试转录接口',
        kind: TranscriptionServiceKind.openai,
        model: 'whisper-1',
      );
      final settings = SubtitleTranslateSettings(modelCenter: service);
      await settings.ensureLoaded();
      final provider = settings.providerEnZh;
      final languages = settings.languageSummary;
      await mountCenter(
        tester,
        service,
        settings,
        size: size,
        scale: size.width == 320 ? 1.6 : 1,
        transcriptionOnly: true,
      );
      expect(find.text('转录设置'), findsOneWidget);
      expect(find.text('默认转录服务'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model-center-translation')),
        findsNothing,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('asr-binding-gongyi')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-choice-test-asr')),
      );
      expect(service.asrProfileId, 'test-asr');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-audio-language')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-choice-ja')),
      );
      expect(service.selectedLanguage, 'ja');
      expect(settings.providerEnZh, provider);
      expect(settings.languageSummary, languages);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      service.dispose();
    });
  }

  for (final size in const [
    Size(320, 800),
    Size(360, 800),
    Size(390, 844),
    Size(600, 900),
    Size(1000, 900),
    Size(1440, 900),
    Size(1920, 1080),
  ]) {
    testWidgets('responsive configuration and controls ${size.width}', (
      tester,
    ) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      final asrModel = catalog.firstWhere(
        (model) => model.purpose == ModelPurpose.transcription,
      );
      bindLocal(service, asrModel);
      final key = GlobalKey();
      await mountCenter(
        tester,
        service,
        settings,
        size: size,
        scale: size.width == 320 ? 1.3 : 1,
        previewKey: key,
      );
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('默认转录服务'), findsOneWidget);
      expect(find.text('默认翻译服务'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (size.width == 360 || size.width == 390) {
        final rect = tester.getRect(
          find.byKey(ValueKey('translation-${settings.providerEnZh}')),
        );
        expect(
          rect.bottom,
          lessThan(size.height),
          reason: 'both service selectors should fit on the phone first screen',
        );
      }
      if (size.width >= 1000) {
        final asr = tester.getRect(
          find.byKey(const ValueKey('model-center-asr')),
        );
        final output = tester.getRect(
          find.byKey(const ValueKey('model-center-output')),
        );
        final translationCard = tester.getRect(
          find.byKey(const ValueKey('model-center-translation')),
        );
        final device = tester.getRect(
          find.byKey(const ValueKey('model-center-device')),
        );
        expect(output.top - asr.bottom, closeTo(12, .1));
        expect(device.top - translationCard.bottom, closeTo(12, .1));
        expect(translationCard.left, greaterThan(asr.right));
      }
      await preview(tester, key, '${size.width.toInt()}-functions');

      for (final mode in SubtitlePunctuation.values) {
        await tapVisible(
          tester,
          find.byKey(const ValueKey('model-center-punctuation')),
        );
        await tapVisible(
          tester,
          find.byKey(ValueKey('model-center-choice-$mode')),
        );
        expect(service.subtitlePunctuation, mode);
      }
      await tapVisible(tester, find.text('本地转录设置'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('asr-thread-recommendation')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('asr-execution-mode')), findsNothing);
      await preview(tester, key, '${size.width.toInt()}-asr-performance');
      if (size.width == 360 || size.width == 1440) {
        await tapVisible(
          tester,
          find.byKey(const ValueKey('open-asr-enhancements')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AsrEnhancementScreen), findsOneWidget);
        await preview(tester, key, '${size.width.toInt()}-enhancements');
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      await tapVisible(
        tester,
        find.byKey(const ValueKey('open-subtitle-segmentation')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleSegmentationScreen), findsOneWidget);
      await preview(tester, key, '${size.width.toInt()}-segmentation');
      await tester.tap(
        find.byKey(const ValueKey('segmentation-preset-natural')),
      );
      await advance(tester);
      await tester.tap(find.text('标准').last);
      await advance(tester);
      expect(
        service.subtitleSegmentation,
        SubtitleSegmentationOptions.standard,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('高级设置'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('asr-execution-mode')),
      );
      await tester.tap(find.text('省内存 · 顺序处理').last);
      await advance(tester);
      expect(service.asrExecution, AsrExecutionMode.lowMemory);
      await tapVisible(
        tester,
        find.byKey(ValueKey('asr-acceleration-${asrModel.id}')),
      );
      await tester.tap(find.text('GPU / 硬件加速 · 失败回退 CPU').last);
      await advance(tester);
      expect(service.asrAccelerationFor(asrModel.id), AsrAcceleration.gpu);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('asr-benchmark')))
            .onPressed,
        isNull,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('本地翻译设置'));
      await tester.pumpAndSettle();
      final acceleration = find.byKey(
        const ValueKey('local-translation-acceleration'),
      );
      await tapVisible(tester, acceleration);
      if (Platform.isWindows) {
        final field = tester
            .widget<CapsuleDropdownButton<TranslationAcceleration>>(
              find.descendant(
                of: acceleration,
                matching: find.byType(
                  CapsuleDropdownButton<TranslationAcceleration>,
                ),
              ),
            );
        expect(
          field.items!
              .singleWhere((item) => item.value == TranslationAcceleration.gpu)
              .enabled,
          isTrue,
        );
      }
      await tester.tap(find.text('CPU · 兼容模式').last);
      await advance(tester);
      expect(
        service.translationOptions.acceleration,
        TranslationAcceleration.cpu,
      );
      expect(
        find.byKey(const ValueKey('local-translation-gpu-layers')),
        findsNothing,
      );
      await tapVisible(tester, find.text('高级设置'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('local-translation-gpu-layers')),
      );
      await tester.tap(find.text('16 层').last);
      await advance(tester);
      expect(service.translationOptions.gpuLayers, 16);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('local-translation-threads')),
      );
      await tester.tap(find.text('4 个线程').last);
      await advance(tester);
      expect(service.translationOptions.threads, 4);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('local-translation-batch-size')),
      );
      await tester.tap(find.text('4 条').last);
      await advance(tester);
      expect(service.translationOptions.batchSize, 4);
      await preview(
        tester,
        key,
        '${size.width.toInt()}-translation-performance',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-1')),
      );
      await preview(tester, key, '${size.width.toInt()}-models');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    });
  }

  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets('picker stays scrollable with keyboard at $size', (
      tester,
    ) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await mountCenter(tester, service, settings, size: size, scale: 1.3);
      await tapVisible(
        tester,
        find.byKey(ValueKey('asr-binding-${service.asrProfileId}')),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await advance(tester);
      await tester.enterText(
        find.byKey(const ValueKey('model-center-picker-search')),
        'Dolphin',
      );
      await advance(tester);
      final choice = find.byKey(
        const ValueKey('option-download-dolphin-base-int8'),
      );
      await tester.scrollUntilVisible(
        choice,
        80,
        scrollable: find
            .descendant(
              of: find.byType(ModelCenterPicker<String>),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await advance(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Dolphin Base'), findsOneWidget);
      expect(choice, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    });
  }
  testWidgets(
    'service and model pickers update shared choices without downloading the selected model',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog) as _ViewCenter;
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      final key = GlobalKey();
      await mountCenter(
        tester,
        service,
        settings,
        size: const Size(360, 800),
        previewKey: key,
      );
      await preview(tester, key, '360-online-functions');
      await tapVisible(
        tester,
        find.byKey(ValueKey('asr-binding-${service.asrProfileId}')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('model-center-picker-search')),
        'Dolphin',
      );
      await advance(tester);
      await tester.tap(find.text('Dolphin Base'));
      await advance(tester);
      expect(service.asrProfile.local, isTrue);
      expect(service.asrProfile.model, 'dolphin-base-int8');
      expect(service.installed('dolphin-base-int8'), isFalse);
      expect(service.enqueued, isNot(contains('dolphin-base-int8')));

      Future<void> chooseProvider(SubtitleTranslateProvider provider) async {
        await tapVisible(
          tester,
          find.byKey(ValueKey('translation-${settings.providerEnZh}')),
        );
        final item = find.byKey(ValueKey('model-center-choice-$provider'));
        await tester.scrollUntilVisible(
          item,
          160,
          scrollable: find
              .descendant(
                of: find.byType(ModelCenterPicker<SubtitleTranslateProvider>),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(item);
        await advance(tester);
        expect(settings.providerEnZh, provider);
      }

      await chooseProvider(SubtitleTranslateProvider.local);
      final model = catalog.lastWhere(
        (model) => model.purpose == ModelPurpose.translation,
      );
      await tapVisible(
        tester,
        find.byKey(ValueKey('translation-model-${service.translationModelId}')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('model-center-picker-search')),
        model.name,
      );
      await advance(tester);
      await tester.tap(find.byKey(ValueKey('model-center-choice-${model.id}')));
      await advance(tester);
      expect(service.translationModelId, model.id);
      expect(service.enqueued, isNot(contains(model.id)));
      await tapVisible(tester, find.text('本地翻译设置'));
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-terminology')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('model-center-terminology')),
        'subtitle 统一译为字幕',
      );
      await advance(tester);
      expect(settings.aiOptions.customPrompt, 'subtitle 统一译为字幕');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await chooseProvider(SubtitleTranslateProvider.bing);
      expect(
        find.byKey(const PageStorageKey('local-translation-settings')),
        findsNothing,
      );
      expect(service.translationModelId, model.id);
      expect(settings.aiOptions.customPrompt, 'subtitle 统一译为字幕');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets(
    'phone service editor saves above the keyboard and returns to management',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      final key = GlobalKey();
      await mountCenter(
        tester,
        service,
        settings,
        size: const Size(360, 640),
        scale: 1.3,
        previewKey: key,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-2')),
      );
      await tapVisible(tester, find.text('兼容转录接口'));
      expect(find.text('配置转录服务'), findsOneWidget);
      // Compatible endpoints now require an explicit model instead of a
      // deprecated provider model as the implicit default.
      await tester.enterText(
        find.widgetWithText(TextFormField, '模型 / 引擎名称'),
        'my-transcriber',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await advance(tester);
      await tester.enterText(find.byType(TextFormField).first, '手机转录接口');
      await advance(tester);
      final save = find.byKey(const ValueKey('model-center-save-service'));
      final rect = tester.getRect(save);
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.bottom, lessThanOrEqualTo(400));
      await preview(tester, key, '360-service-keyboard');
      await tester.tap(save);
      await advance(tester);
      expect(
        service.profiles.values.any((profile) => profile.name == '手机转录接口'),
        isTrue,
      );
      expect(
        service.asrProfileId,
        'gongyi',
        reason: 'saving a service does not silently enable it',
      );
      expect(find.text('服务管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
  testWidgets(
    'background downloads during a management pop keep scroll controllers separate',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      final model = catalog.first;
      service.downloads[model.id] = ModelDownload(
        artifactId: model.id,
        phase: ModelDownloadPhase.downloading,
        received: model.bytes ~/ 4,
      );
      await mountCenter(tester, service, settings, size: const Size(360, 800));
      final homeScroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const PageStorageKey('model-center-features-scroll')),
          )
          .controller!;
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-3')),
      );
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 16));
      service.downloads[model.id]!.received = model.bytes ~/ 2;
      service.notifyListeners();
      await tester.pump(const Duration(milliseconds: 16));
      expect(homeScroll.positions.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.text('默认转录服务'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets(
    'failed enqueue stays in the target detail and rapid taps open it once',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog) as _ViewCenter;
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setProviderEnZh(SubtitleTranslateProvider.local);
      final model = catalog.firstWhere(
        (model) => model.purpose == ModelPurpose.translation,
      );
      service.translationModelId = model.id;
      service.rejectDownloads = true;
      await mountCenter(tester, service, settings, size: const Size(360, 800));
      final download = find.byKey(ValueKey('selected-download-${model.id}'));
      await tester.ensureVisible(download);
      final onDownload = tester.widget<IconButton>(download).onPressed!;
      onDownload();
      onDownload();
      await advance(tester);
      expect(find.byKey(ValueKey('model-detail-${model.id}')), findsOneWidget);
      expect(find.textContaining('测试下载失败'), findsOneWidget);
      expect(service.enqueued, isEmpty);
      service.rejectDownloads = false;
      await tester.tap(
        find.byKey(ValueKey('model-detail-download-${model.id}')),
      );
      await advance(tester);
      expect(service.enqueued, [model.id]);
      expect(service.downloads[model.id]!.phase, ModelDownloadPhase.queued);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
  testWidgets(
    'task page observes transcription progress while configuration stays mounted',
    (tester) async {
      final catalog = (await tester.runAsync(loadModelCatalog))!;
      final service = create(view: true, catalog: catalog);
      await tester.runAsync(service.initialize);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      final tasks = _TaskProgress();
      await mountCenter(
        tester,
        service,
        settings,
        size: const Size(360, 800),
        transcriptions: tasks,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('model-center-manage-3')),
      );
      expect(find.text('测试进度 10%'), findsOneWidget);
      tasks.update(.6);
      await advance(tester);
      expect(find.text('测试进度 60%'), findsOneWidget);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .any((indicator) => indicator.value == .6),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      tasks.dispose();
      settings.dispose();
    },
  );
}
