import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_accelerator_transport.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';

class _Transport implements AsrAcceleratorTransport {
  _Transport(this.respond);
  final FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>) respond;

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async =>
      respond(value);

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in ['android', 'windows']) {
    test(
      '$platform GPU failure keeps the CPU fallback under the ASR permit',
      () async {
        final now = DateTime.now();
        final session = InferenceResourceSession(
          InferenceResourceGovernor(
            DeviceResourceSnapshot(
              platform: platform,
              processors: 16,
              memoryBytes: 16 * 1073741824,
              availableMemoryBytes: 12 * 1073741824,
              capturedAt: now,
            ),
            now: () => now,
          ),
        );
        final cpuStarted = Completer<void>();
        final finishCpu = Completer<void>();
        final states = <Map<String, dynamic>>[];
        final selected = <String>[];
        final decoder = QwenAsrDecoder(
          model: 'prepared.gguf',
          identity: 'fallback-test',
          language: 'ja',
          hotwords: '',
          threads: 4,
          mode: 'gpu',
          onLoad: () {},
          onState: states.add,
          runtimeFactory: () {
            var backend = '';
            return QwenAsrRuntime(
              openTransport: () async => _Transport((message) async {
                switch (message['op']) {
                  case 'capabilities':
                    return {
                      'devices': [
                        {'name': 'Vulkan0', 'gpu': true},
                      ],
                    };
                  case 'load':
                    final requested = message['backend'] as String;
                    selected.add(requested);
                    backend = requested == 'cpu' ? 'CPU' : 'Vulkan0';
                    return {'backend': backend};
                  case 'decode':
                    if (backend == 'CPU') {
                      cpuStarted.complete();
                      await finishCpu.future;
                    }
                    return {
                      'result': {
                        'text': 'test',
                        'lang': 'ja',
                        'timingKind': 'segment',
                        // A GPU without executed operators must fall back.
                        'gpuOperators': 0,
                      },
                    };
                  default:
                    throw StateError('unexpected operation: ${message['op']}');
                }
              }),
            );
          },
        );
        final run = session.run(
          InferenceLane.recognition,
          (_) => decoder.decode(Float32List(16000), () {}),
          requested: 4,
        );
        InferenceComputePermit? alignment;
        try {
          await cpuStarted.future.timeout(const Duration(seconds: 10));
          expect(selected, ['vulkan', 'cpu']);
          expect(states.last['reason'], contains('回退 CPU'));
          expect(session.activeThreads, 4);

          var alignmentStarted = false;
          final waiting = session
              .acquire(InferenceLane.alignment, requested: 6)
              .then((permit) {
                alignmentStarted = true;
                return permit;
              });
          await Future<void>.delayed(Duration.zero);
          expect(alignmentStarted, isFalse);
          expect(session.activeThreads, 4);

          finishCpu.complete();
          expect((await run)['_backend'], 'CPU');
          alignment = await waiting;
          expect(alignmentStarted, isTrue);
          expect(session.activeThreads, alignment.threads);
          expect(
            session.activeThreads,
            lessThanOrEqualTo(session.decision.totalThreads),
          );
        } finally {
          if (!finishCpu.isCompleted) finishCpu.complete();
          alignment?.release();
          await decoder.close();
          await session.close();
        }
      },
    );
  }
}
