import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/asr_accelerator_transport.dart';
import 'package:video_player_app/features/model_center/local_asr_model_adapter.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/native_asr_cpu_decoder.dart';
import 'package:video_player_app/services/ocr_model_catalog.dart';

import '../tool/model_integration_contract.dart';

class _Transport implements AsrAcceleratorTransport {
  final messages = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pending;
  bool closed = false;
  bool badTiming = false;
  bool untimed = false;
  Completer<void>? exitGate;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    messages.add(message);
    if (message['op'] == 'decode') {
      expect(File(message['path'] as String).existsSync(), isTrue);
      if (pending != null) return pending!.future;
      return {
        'result': {
          'text': '你好',
          'tokens': ['你', '好'],
          'timestamps': untimed
              ? []
              : badTiming
              ? [.04]
              : [.04, .08],
        },
      };
    }
    return {'ok': true};
  }

  @override
  Future<void> close() async {
    closed = true;
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(StateError('worker closed'));
    }
    await exitGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new exports retain independent complete CPU/GPU identities', () async {
    final models = await loadModelCatalog(includeRetired: true);
    validateModelIntegration(models, await loadOcrPresets());
    for (final id in ['whisper-large-v3-turbo-int8', 'firered-asr2-ctc-int8']) {
      final model = models.singleWhere((m) => m.id == id);
      final gpu = models.singleWhere((m) => m.id == '$id-gpu');
      expect(model.purpose, ModelPurpose.transcription);
      expect(gpu.purpose, ModelPurpose.acceleration);
      expect(model.identity, isNot(gpu.identity));
      expect(model.languages, containsAll(['zh', 'en']));
      expect(localAsrAdapter(model.engine).supportsHotwords, isFalse);
      final external = gpu.files.singleWhere(
        (f) => f.name.endsWith('.weights'),
      );
      expect(external.bytes, greaterThan(2000000000));
      // A tiny ONNX graph alone is not an installable float model.
      final incomplete = ModelArtifact(
        id: gpu.id,
        name: gpu.name,
        engine: gpu.engine,
        revision: gpu.revision,
        parameters: gpu.parameters,
        quantization: gpu.quantization,
        languages: gpu.languages,
        description: gpu.description,
        license: gpu.license,
        homepage: gpu.homepage,
        purpose: gpu.purpose,
        files: gpu.files.where((f) => f != external).toList(),
        suggestedRamGb: gpu.suggestedRamGb,
        memoryNote: gpu.memoryNote,
      );
      expect(
        () => validateModelIntegration([
          for (final m in models) m.id == gpu.id ? incomplete : m,
        ], []),
        throwsFormatException,
      );
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'local:$id',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: id,
          language: 'en',
        ),
        artifactIdentity: model.identity,
        asrTokenTiming: asrTokenTimingOverride(id, model.engine),
      );
      final restored = ModelJobSpec.fromJson(spec.toJson());
      expect(restored.fingerprint, spec.fingerprint);
      expect(restored.recognitionFingerprint, spec.recognitionFingerprint);
    }
  });

  test(
    'Whisper uses 128-mel-aware native export and always transcribes',
    () async {
      for (final language in ['auto', 'zh', 'en', 'ja', 'ko', 'yue']) {
        final model = (await loadModelCatalog(
          includeRetired: true,
        )).singleWhere((m) => m.id == 'whisper-large-v3-turbo-int8');
        expect(model.languages, contains(language == 'auto' ? 'en' : language));
        final config = localOfflineAsrConfiguration(
          engine: model.engine,
          directory: 'weights',
          language: language,
          threads: 4,
          hotwordsFile: 'unsupported-hotwords.txt',
        );
        expect(
          config.model.whisper.encoder,
          p.join('weights', 'turbo-encoder.int8.onnx'),
        );
        expect(
          config.model.whisper.decoder,
          p.join('weights', 'turbo-decoder.int8.onnx'),
        );
        expect(config.model.tokens, p.join('weights', 'turbo-tokens.txt'));
        expect(
          config.model.whisper.language,
          language == 'auto' ? '' : language,
        );
        expect(config.model.whisper.task, 'transcribe');
        expect(config.model.numThreads, 4);
        expect(config.decodingMethod, 'greedy_search');
        expect(config.hotwordsFile, isEmpty);
      }
    },
  );

  test('FireRed2 requires its loader and freezes 40 ms CTC timing', () {
    expect(localAsrAdapter('firered2').nativeWorker, isTrue);
    expect(
      asrTokenTimingOverride('firered-asr2-ctc-int8', 'firered2'),
      'ctc-40ms-v1',
    );
    expect(
      () => localOfflineAsrConfiguration(
        engine: 'firered2',
        directory: 'weights',
        language: 'auto',
        threads: 2,
      ),
      throwsArgumentError,
    );
  });

  group('new architecture CPU session ownership', () {
    late Directory root;
    late NativeAsrCpuDecoder decoder;
    late _Transport transport;
    var loads = 0;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('new-asr-test-');
      transport = _Transport();
      loads = 0;
      decoder = NativeAsrCpuDecoder(
        configuration: {
          'engine': 'firered2',
          'modelId': 'firered-asr2-ctc-int8',
          'directory': root.path,
          'runtimeDirectory': root.path,
          'threads': 2,
          'identity': 'frozen-model-identity',
        },
        onLoad: () => loads++,
        openTransport: () async => transport,
      );
      expect(localAsrAdapter('whisper').windowsNativeWorker, isTrue);
    });
    tearDown(() async {
      await decoder.close();
      await root.delete(recursive: true);
    });

    test(
      'retains one CPU model, cleans PCM and releases before reloading',
      () async {
        for (var i = 0; i < 2; i++) {
          final result = await decoder.decode(Float32List(1600), () {});
          expect(result['_backend'], 'CPU');
          expect(result['_weights'], 'frozen-model-identity');
        }
        expect(loads, 1);
        expect(decoder.hasLoadedModel, isTrue);
        expect(transport.messages.first['backend'], 'cpu');
        expect(transport.messages.first['floatWeights'], isFalse);
        final files = await root
            .list(recursive: true)
            .where((f) => f is File)
            .toList();
        expect(files, isEmpty);
        await decoder.release();
        expect(decoder.hasLoadedModel, isFalse);
        expect(transport.closed, isTrue);
        expect(await root.list().toList(), isEmpty);
      },
    );

    test(
      'cancel interrupts a pending native decode and permits a fresh session',
      () async {
        transport.pending = Completer<Map<String, dynamic>>();
        final run = decoder.decode(Float32List(1600), () {});
        final assertion = expectLater(run, throwsStateError);
        while (!transport.messages.any((m) => m['op'] == 'decode')) {
          await Future<void>.delayed(Duration.zero);
        }
        await decoder.release();
        await assertion;
        expect(decoder.hasLoadedModel, isFalse);
        transport = _Transport();
        expect((await decoder.decode(Float32List(1600), () {}))['text'], '你好');
        expect(loads, 2);
      },
    );

    test('malformed native timing fails and releases the process', () async {
      transport.badTiming = true;
      await expectLater(
        decoder.decode(Float32List(1600), () {}),
        throwsStateError,
      );
      expect(transport.closed, isTrue);
      expect(decoder.hasLoadedModel, isFalse);
    });

    test(
      'Whisper may return untimed tokens but rejects partial timing arrays',
      () async {
        decoder.configuration['engine'] = 'whisper';
        transport.untimed = true;
        final result = await decoder.decode(Float32List(1600), () {});
        expect(result['tokens'], isNotEmpty);
        expect(result['timestamps'], isEmpty);
        transport.untimed = false;
        transport.badTiming = true;
        await expectLater(
          decoder.decode(Float32List(1600), () {}),
          throwsStateError,
        );
      },
    );

    test(
      'cancellation waits for native process exit before removing PCM',
      () async {
        transport.pending = Completer<Map<String, dynamic>>();
        transport.exitGate = Completer<void>();
        final run = decoder.decode(Float32List(1600), () {});
        final assertion = expectLater(run, throwsStateError);
        while (!transport.messages.any((m) => m['op'] == 'decode')) {
          await Future<void>.delayed(Duration.zero);
        }
        final pcm = File(transport.messages.last['path'] as String);
        final releasing = decoder.release();
        await Future<void>.delayed(Duration.zero);
        expect(
          await pcm.exists(),
          isTrue,
          reason: 'Native decoder still owns this file',
        );
        transport.exitGate!.complete();
        await releasing;
        await assertion;
        expect(await pcm.exists(), isFalse);
        expect(await root.list().toList(), isEmpty);
      },
    );
  });
}
