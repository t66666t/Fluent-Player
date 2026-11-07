import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_accelerator_transport.dart';
import 'package:video_player_app/features/model_center/asr_accelerated_decoder.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_text_processing.dart';
import 'package:video_player_app/features/model_center/inference_tuning.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';
import 'package:video_player_app/models/local_asr_progress.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

class _Transport implements AsrAcceleratorTransport {
  _Transport(this._handle);
  final Map<String, dynamic> Function(Map<String, dynamic> message) _handle;
  final messages = <Map<String, dynamic>>[];
  var closed = false;

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    messages.add(Map<String, dynamic>.from(message));
    return _handle(message);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test('thread hysteresis keeps a heavy model across small grants', () {
    expect(
      asrReloadThreads(
        loaded: null,
        granted: 4,
        protective: false,
        heavy: true,
        lowGrants: 0,
      ),
      4,
    );
    expect(
      asrReloadThreads(
        loaded: 4,
        granted: 6,
        protective: false,
        heavy: true,
        lowGrants: 0,
      ),
      isNull,
    );
    expect(
      asrReloadThreads(
        loaded: 4,
        granted: 6,
        protective: false,
        heavy: false,
        lowGrants: 0,
      ),
      6,
    );
    expect(
      asrReloadThreads(
        loaded: 4,
        granted: 3,
        protective: false,
        heavy: true,
        lowGrants: 2,
      ),
      isNull,
    );
    expect(
      asrReloadThreads(
        loaded: 6,
        granted: 2,
        protective: true,
        heavy: true,
        lowGrants: 0,
      ),
      2,
    );
    expect(
      asrReloadThreads(
        loaded: 6,
        granted: 2,
        protective: false,
        heavy: true,
        lowGrants: 1,
      ),
      isNull,
    );
    expect(
      asrReloadThreads(
        loaded: 6,
        granted: 2,
        protective: false,
        heavy: true,
        lowGrants: 2,
      ),
      2,
    );
    expect(
      asrReloadThreads(
        loaded: 6,
        granted: 2,
        protective: false,
        heavy: true,
        lowGrants: 1,
        lowFor: const Duration(seconds: 60),
      ),
      2,
    );
  });

  test('availability v2 ignores threads and still honors a v1 record', () {
    final now = DateTime.utc(2026, 11, 7);
    final config = <String, dynamic>{
      'identity': 'model@revision',
      'threads': 2,
      'language': 'zh',
      'accelerationEnvironment': 'phone',
    };
    final v2 = asrAvailabilitySignature(config);
    expect(asrAvailabilitySignature({...config, 'threads': 6}), v2);
    expect(
      asrAvailabilitySignatureV1({...config, 'threads': 6}),
      isNot(asrAvailabilitySignatureV1(config)),
    );
    final failed = AsrPerformanceProfile(
      signature: v2,
      testedAt: now,
      backend: 'GPU',
      device: 'preflight',
      weights: 'model@revision',
      sampleSeconds: 1,
      cpuMs: 0,
      gpuMs: 0,
      failed: true,
    );
    expect(
      asrAvailabilityMatches(failed, {...config, 'threads': 6}, now),
      isTrue,
    );
    final legacy = AsrPerformanceProfile(
      signature: asrAvailabilitySignatureV1(config),
      testedAt: now,
      backend: 'GPU',
      device: 'preflight',
      weights: 'model@revision',
      sampleSeconds: 1,
      cpuMs: 0,
      gpuMs: 0,
      failed: true,
    );
    expect(asrAvailabilityMatches(legacy, config, now), isTrue);
  });

  test(
    'a phone without a fresh GPU win never opens Qwen capabilities',
    () async {
      final states = <Map<String, dynamic>>[];
      final transport = _Transport((message) {
        if (message['op'] == 'load') return {'backend': 'CPU'};
        return {
          'result': {'text': '你好', 'lang': 'zh', 'timingKind': 'segment'},
        };
      });
      final decoder = QwenAsrDecoder(
        model: 'weights.gguf',
        identity: 'qwen@1',
        language: 'zh',
        hotwords: '',
        threads: 4,
        mode: 'auto',
        conservativeGpu: true,
        onLoad: () {},
        onState: states.add,
        runtimeFactory: () =>
            QwenAsrRuntime(openTransport: () async => transport),
      );
      final result = await decoder.decode(Float32List(16000), () {});
      expect(result['text'], '你好');
      expect(
        transport.messages.map((m) => m['op']),
        isNot(contains('capabilities')),
      );
      expect(
        transport.messages.firstWhere((m) => m['op'] == 'load')['backend'],
        'cpu',
      );
      expect(states.any((s) => s['selecting'] == true), isFalse);
      await decoder.close();
    },
  );

  test('GPU load failure is recorded and cancellation is not', () async {
    final states = <Map<String, dynamic>>[];
    QwenAsrDecoder decoder(bool cancel) => QwenAsrDecoder(
      model: 'weights.gguf',
      identity: 'qwen@1',
      language: 'zh',
      hotwords: '',
      threads: 4,
      mode: 'gpu',
      confirmGpuFault: () async => false,
      onLoad: () {},
      onState: states.add,
      runtimeFactory: () => QwenAsrRuntime(
        openTransport: () async => _Transport((message) {
          if (message['op'] == 'capabilities') {
            return {
              'devices': [
                {'name': 'vulkan0', 'gpu': true},
              ],
              'build': 'test',
            };
          }
          if (message['op'] == 'load' && message['backend'] != 'cpu') {
            throw StateError('GPU load failed');
          }
          if (message['op'] == 'load') return {'backend': 'CPU'};
          return {
            'result': {'text': '你好', 'lang': 'zh', 'timingKind': 'segment'},
          };
        }),
      ),
    );
    final first = decoder(false);
    await first.decode(Float32List(16000), () {});
    expect(states.where((s) => s['profile']?['failed'] == true), isNotEmpty);
    states.clear();
    final second = decoder(true);
    expect(
      () => second.decode(Float32List(16000), () {
        throw StateError('转录已取消');
      }),
      throwsStateError,
    );
    expect(states.where((s) => s['profile'] != null), isEmpty);
    await first.close();
    await second.close();
  });

  test(
    'a process exit is not a GPU failure unless the bridge confirms it',
    () async {
      final states = <Map<String, dynamic>>[];
      final decoder = QwenAsrDecoder(
        model: 'weights.gguf',
        identity: 'qwen@1',
        language: 'zh',
        hotwords: '',
        threads: 4,
        mode: 'gpu',
        confirmGpuFault: () async => false,
        onLoad: () {},
        onState: states.add,
        runtimeFactory: () => QwenAsrRuntime(
          openTransport: () async => _Transport((message) {
            if (message['op'] == 'capabilities') {
              return {
                'devices': [
                  {'name': 'vulkan0', 'gpu': true},
                ],
              };
            }
            throw StateError('Qwen 音频进程已退出，已保留有效断点');
          }),
        ),
      );
      await expectLater(
        decoder.decode(Float32List(16000), () {}),
        throwsStateError,
      );
      expect(states.where((s) => s['profile'] != null), isEmpty);
      await decoder.close();
    },
  );

  test(
    'mobile sherpa auto does not open a GPU transport without a win',
    () async {
      final root = await Directory.systemTemp.createTemp('asr-device-');
      var opened = 0;
      final config = <String, dynamic>{
        'mode': 'auto',
        'conservativeGpu': true,
        'automaticTuningAllowed': false,
        'identity': 'model@revision',
        'modelId': 'model',
        'directory': root.path,
        'runtimeDirectory': root.path,
        'durationSeconds': 600.0,
        'threads': 4,
        'language': 'zh',
        'profiles': <Object>[],
      };
      final session = AsrAcceleratedDecoder(
        configuration: config,
        releaseCpu: () {},
        onState: (_) {},
        openTransport: () async {
          opened++;
          return _Transport((_) => {'devices': <Object>[]});
        },
      );
      expect(session.needsExclusiveLoad, isFalse);
      final output = await session.decode(
        Float32List(4 * 16000),
        cpu: () async => {'text': '你好'},
        check: () {},
      );
      expect(output['_backend'], 'CPU');
      expect(opened, 0);
      expect(session.needsExclusiveLoad, isFalse);
      await session.close();
      await root.delete(recursive: true);
    },
  );

  test(
    'an undecided sherpa fallback becomes decided for the rest of the task',
    () async {
      final root = await Directory.systemTemp.createTemp('asr-decided-');
      var opened = 0;
      final now = DateTime.utc(2026, 11, 7);
      final config = <String, dynamic>{
        'mode': 'auto',
        'automaticTuningAllowed': false,
        'identity': 'model@revision',
        'modelId': 'model',
        'directory': root.path,
        'runtimeDirectory': root.path,
        'durationSeconds': 600.0,
        'threads': 4,
        'language': 'zh',
        'profiles': [
          AsrPerformanceProfile(
            signature: 'unrelated',
            testedAt: now,
            backend: 'GPU',
            device: 'old',
            weights: 'other',
            sampleSeconds: 4,
            cpuMs: 100,
            gpuMs: 100,
            failed: true,
          ).toJson(),
        ],
      };
      final session = AsrAcceleratedDecoder(
        configuration: config,
        releaseCpu: () {},
        onState: (_) {},
        now: () => now,
        openTransport: () async {
          opened++;
          return _Transport(
            (_) => {
              'devices': [
                {
                  'backend': 'vulkan',
                  'device': 0,
                  'label': 'GPU · Vulkan',
                  'fingerprint': 'gpu',
                  'runtime': 'test',
                },
              ],
            },
          );
        },
      );
      expect(session.needsExclusiveLoad, isTrue);
      final output = await session.decode(
        Float32List(4 * 16000),
        cpu: () async => {'text': '你好'},
        check: () {},
      );
      expect(output['_backend'], 'CPU');
      expect(opened, 1);
      expect(session.needsExclusiveLoad, isFalse);
      await session.close();
      await root.delete(recursive: true);
    },
  );

  test(
    'mobile automatic alignment stays on CPU and manual GPU still probes',
    () async {
      final dir = await Directory.systemTemp.createTemp('align-cpu-');
      await File(
        p.join(dir.path, 'qwen3-forced-aligner-0.6b-f16.gguf'),
      ).writeAsBytes([1]);
      final cue = SubtitleItem(
        index: 1,
        startTime: Duration.zero,
        endTime: const Duration(milliseconds: 500),
        text: '你好',
        asrInfo: const SubtitleAsrInfo(language: 'zh'),
      );
      final audio = Float32List(8000);
      Future<List<String>> backends(String acceleration) async {
        final transport = _Transport((message) {
          if (message['op'] == 'capabilities') {
            return {
              'devices': [
                {'name': 'vulkan0', 'gpu': true},
              ],
            };
          }
          if (message['op'] == 'load') return {'backend': message['backend']};
          return {'times': <Object>[], 'gpuOperators': 1};
        });
        final processor = AsrTextProcessor(
          directories: {AsrEnhancementOptions.alignmentQwenId: dir.path},
          threads: 2,
          checkCancelled: () {},
          acceleration: acceleration,
          conservativeGpu: true,
          runtime: QwenAsrRuntime(openTransport: () async => transport),
        );
        await processor.align(cue, audio);
        final loads = transport.messages.where((m) => m['op'] == 'load');
        await processor.close();
        return loads.map((m) => '${m['backend']}').toList();
      }

      expect(await backends('auto'), ['cpu']);
      expect(await backends('gpu'), isNot(contains('cpu')));
      await dir.delete(recursive: true);
    },
  );

  test('a selected device shows a percentage and selection does not', () {
    const ready = LocalAsrLaneProgress(
      phase: '识别语音',
      phaseFraction: .4,
      piece: 1,
      active: true,
    );
    const selecting = LocalAsrLaneProgress(
      phase: '选择计算设备',
      phaseFraction: .4,
      piece: 1,
      active: true,
    );
    expect(ready.label, contains('%'));
    expect(selecting.label, isNot(contains('%')));
  });
}
