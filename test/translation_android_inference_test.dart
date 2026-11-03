import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/translation_android_inference.dart';
import 'package:video_player_app/features/model_center/translation_inference.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';

const channel = MethodChannel(
  'com.example.video_player_app/translation_acceleration',
);
const codec = StandardMethodCodec();
Map<String, Object> generation(String text) => {
  'text': text,
  'truncated': false,
  'promptTokens': 10,
  'generatedTokens': 2,
  'promptMs': 1.0,
  'decodeMs': 2.0,
  'sampleMs': 0.0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  AndroidTranslationInference? engine;
  tearDown(() async {
    await engine?.dispose();
    engine = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  Future<AndroidTranslationInference> open({Future<void>? cancel}) =>
      AndroidTranslationInference.load(
        modelPath: 'test.gguf',
        backend: 'opencl',
        threads: 2,
        promptThreads: 4,
        gpuLayers: 24,
        cancelSignal: cancel,
      );
  test(
    'private process streams by request id, ignores stale deltas and retains GPU truth',
    () async {
      final result = Completer<Map<String, Object>>();
      var requestId = 0, closed = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'close') {
          closed++;
          return null;
        }
        final command = Map<String, dynamic>.from(
          (call.arguments as Map)['command'] as Map,
        );
        if (command['op'] == 'load') {
          expect(command['backend'], 'opencl');
          return {
            'backend': 'OpenCL',
            'gpuLayers': 24,
            'workerPid': 2147000001,
          };
        }
        requestId = command['id'] as int;
        return result.future;
      });
      engine = await open();
      expect(engine!.backend, 'OpenCL');
      final deltas = <String>[];
      final pending = engine!.generate('hello', onDelta: deltas.add);
      await Future<void>.delayed(Duration.zero);
      Future<void> delta(int id, String text) async {
        final delivered = Completer<void>();
        // ignore: deprecated_member_use
        messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall('delta', {'id': id, 'text': text})),
          (_) => delivered.complete(),
        );
        await delivered.future;
      }

      await delta(requestId - 1, 'stale');
      await delta(requestId, '你');
      await delta(requestId, '好');
      result.complete(generation('你好'));
      expect((await pending).text, '你好');
      expect(deltas, ['你', '好']);
      await engine!.dispose();
      expect(closed, 1);
    },
  );
  test(
    'service death and false CPU offload release the slot for the next route',
    () async {
      var loads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'close') return null;
        loads++;
        return switch (loads) {
          1 => {'workerFailure': true},
          2 => {'backend': 'CPU', 'gpuLayers': 0},
          _ => {'backend': 'OpenCL', 'gpuLayers': 24},
        };
      });
      await expectLater(open(), throwsA(isA<TranslationWorkerFailure>()));
      await expectLater(open(), throwsA(isA<StateError>()));
      engine = await open();
      expect(engine!.gpuLayers, 24);
    },
  );
  test(
    'load cancellation ends a stalled request and does not occupy the next session',
    () async {
      final blocked = Completer<Map<String, Object>>();
      var closed = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'close') {
          closed++;
          return null;
        }
        return blocked.future;
      });
      final cancel = Completer<void>();
      final pending = open(cancel: cancel.future);
      final assertion = expectLater(
        pending,
        throwsA(isA<TranslationWorkerFailure>()),
      );
      cancel.complete();
      await assertion;
      expect(closed, 1);
      blocked.complete({'workerFailure': true});
    },
  );
  test(
    'temporary GPU memory pressure is not persisted as incompatibility',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'close') return null;
        final command = (call.arguments as Map)['command'] as Map;
        return command['op'] == 'load'
            ? {'backend': 'OpenCL', 'gpuLayers': 24}
            : {'event': 'error', 'pressure': true, 'message': 'GPU 推理失败'};
      });
      engine = await open();
      try {
        await engine!.generate('hello');
        fail('GPU error must propagate');
      } catch (error) {
        expect(isTransientInferencePressure(error), isTrue);
      }
    },
  );
}
