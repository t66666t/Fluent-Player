import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_accelerated_decoder.dart';
import 'package:video_player_app/features/model_center/asr_accelerator_transport.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';

class _Transport extends AsrAcceleratorTransport {
  _Transport({
    this.nodes = 12,
    this.failInt8 = false,
    this.gate,
    this.failAfter,
    this.result,
    this.devices,
    this.failCapabilities = false,
    this.failLoad = false,
    this.capabilities,
  });
  final int nodes;
  final bool failInt8;
  final Completer<void>? gate;
  final int? failAfter;
  final Map<String, dynamic>? result;
  final List<Map<String, dynamic>>? devices;
  final bool failCapabilities, failLoad;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  capabilities;
  final started = Completer<void>();
  bool floating = false, closed = false;
  int loads = 0, decodes = 0;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    if (message['op'] == 'capabilities') {
      if (capabilities != null) return capabilities!(message);
      if (failCapabilities) throw StateError('capabilities worker exited');
      return {
        'devices':
            devices ??
            [
              {
                'backend': 'directml',
                'device': 0,
                'label': 'GPU · DirectML',
                'fingerprint': 'physical-gpu:driver-1',
                'runtime': 'pinned-runtime',
              },
            ],
      };
    }
    if (message['op'] == 'load') {
      loads++;
      if (failLoad) throw StateError('insufficient GPU memory');
      floating = message['floatWeights'] == true;
      return {'ok': true};
    }
    if (message['op'] == 'decode') {
      decodes++;
      if (!started.isCompleted) started.complete();
      await gate?.future;
      if (closed) throw StateError('process exited');
      if (failAfter != null && decodes > failAfter!) {
        throw TimeoutException('native inference timed out');
      }
      if (failInt8 && !floating) throw StateError('unsupported int8 kernel');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return {
        'acceleratedNodes': nodes,
        'result':
            result ??
            {
              'text': 'Hello world',
              'tokens': ['Hello', 'world'],
              'timestamps': [0.0, .5],
              'durations': [.5, .5],
            },
      };
    }
    return {'ok': true};
  }

  @override
  Future<void> close() async {
    closed = true;
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 20);
  AsrPerformanceProfile profile({int startup = 0, bool failed = false}) =>
      AsrPerformanceProfile(
        signature: 'signature',
        testedAt: now,
        backend: 'GPU',
        device: 'adapter/driver',
        weights: 'weights@revision',
        sampleSeconds: 10,
        cpuMs: 1000,
        gpuMs: 500,
        gpuStartupMs: startup,
        failed: failed,
      );

  test('startup and model reload count decide whether GPU is faster', () {
    expect(profile(startup: 3000).useGpu(10), isFalse);
    expect(profile(startup: 3000).useGpu(600), isTrue);
    expect(profile(startup: 3000).useGpu(600, loads: 20), isFalse);
    expect(profile(failed: true).useGpu(600), isFalse);
  });
  test(
    'short-phrase dispatch costs and probe length prevent optimistic GPU selection',
    () {
      expect(profile().useGpu(600), isTrue);
      expect(profile().useGpu(600, calls: 300), isFalse);
      expect(profile().supportsProbe(10.3), isTrue);
      expect(profile().supportsProbe(11.2), isTrue);
      expect(profile().supportsProbe(3), isFalse);
      expect(profile(failed: true).supportsProbe(3), isTrue);
    },
  );
  test(
    'preflight keys track installation and weights, not task audio length',
    () {
      final config = <String, dynamic>{
        'identity': 'model@revision',
        'accelerationEnvironment': ['device', 'app-update-1'],
        'durationSeconds': 600,
      };
      final before = asrAvailabilitySignature(config);
      expect(
        asrAvailabilitySignature({...config, 'durationSeconds': 20}),
        before,
      );
      expect(asrAvailabilitySignature({...config, 'mode': 'gpu'}), before);
      expect(
        asrAvailabilitySignature({
          ...config,
          'accelerationEnvironment': ['device', 'app-update-2'],
        }),
        isNot(before),
      );
      expect(
        asrAvailabilitySignature({
          ...config,
          'gpuIdentity': 'new-float@revision',
        }),
        isNot(before),
      );
      expect(
        asrAvailabilitySignature({...config, 'identity': 'new-model@revision'}),
        isNot(before),
      );
    },
  );
  test('profiles expire and reject invalid, future and mismatched records', () {
    final stored = AsrPerformanceProfile.fromJson(profile().toJson())!;
    expect(
      stored.matches('signature', now.add(const Duration(days: 13))),
      isTrue,
    );
    expect(
      stored.matches('signature', now.add(const Duration(days: 14))),
      isFalse,
    );
    expect(stored.matches('other', now), isFalse);
    expect(
      stored.matches('signature', now.subtract(const Duration(seconds: 1))),
      isFalse,
    );
    expect(
      AsrPerformanceProfile.fromJson({
        ...profile().toJson(),
        'sampleSeconds': 0,
      }),
      isNull,
    );
    expect(AsrPerformanceProfile.fromJson({'signature': 'broken'}), isNull);
  });
  test(
    'probe output gate normalizes punctuation and rejects unrelated words',
    () {
      expect(asrProbeAgrees('Hello, WORLD!', 'hello world'), isTrue);
      expect(asrProbeAgrees('你好，世界。', '你好世界'), isTrue);
      expect(asrProbeAgrees('hello world', 'completely different'), isFalse);
      expect(asrProbeAgrees('hello', ''), isFalse);
      expect(asrMedian([100, 2, 3]), 3);
    },
  );
  test(
    'driver, weight, language and decoding changes invalidate timing keys',
    () {
      final config = {
        'identity': 'model@revision',
        'threads': 2,
        'language': 'en',
        'decoding': '',
        'pipeline': true,
      };
      final device = {
        'fingerprint': 'gpu/driver',
        'backend': 'directml',
        'runtime': 'runtime',
      };
      String signature(
        Map<String, dynamic> c,
        Map<String, dynamic> d, [
        String weights = 'int8',
      ]) => asrPerformanceSignature(
        configuration: c,
        device: d,
        weights: weights,
      );
      final before = signature(config, device);
      expect(signature({...config, 'language': 'zh'}, device), isNot(before));
      expect(signature({...config, 'threads': 4}, device), isNot(before));
      expect(
        signature({...config, 'decoding': 'hotword'}, device),
        isNot(before),
      );
      expect(
        signature(config, {...device, 'fingerprint': 'gpu/new-driver'}),
        isNot(before),
      );
      expect(signature(config, device, 'fp32'), isNot(before));
    },
  );
  test(
    'old tasks preserve CPU semantics and recognition checkpoint identity',
    () {
      const service = ModelServiceProfile(
        id: 'local:m',
        name: 'm',
        model: 'm',
        kind: TranscriptionServiceKind.local,
      );
      const old = ModelJobSpec(profile: service);
      final restored = ModelJobSpec.fromJson(old.toJson());
      expect(restored.asrAcceleration, isNull);
      expect(old.toJson().containsKey('asrAcceleration'), isFalse);
      const accelerated = ModelJobSpec(
        profile: service,
        asrAcceleration: AsrAcceleration.gpu,
        asrAccelerationModels: {'m-gpu': 'float@revision'},
      );
      final roundTrip = ModelJobSpec.fromJson(accelerated.toJson());
      expect(roundTrip.asrAcceleration, AsrAcceleration.gpu);
      expect(roundTrip.asrAccelerationModels, {'m-gpu': 'float@revision'});
      expect(roundTrip.recognitionFingerprint, old.recognitionFingerprint);
    },
  );
  test('raw cue metadata retains actual backend and exact weight identity', () {
    const data = SubtitleAsrInfo(
      language: 'zh',
      backend: 'GPU · DirectML',
      weights: 'weights@revision',
    );
    final restored = SubtitleAsrInfo.fromJson(
      data.toJson(),
    ).copyWith(reviewReason: 'review');
    expect(restored.backend, data.backend);
    expect(restored.weights, data.weights);
    expect(SubtitleAsrInfo.fromJson({'language': 'en'}).backend, isEmpty);
  });

  group('decoder ownership, cancellation and fallback', () {
    late Directory root;
    late Map<String, dynamic> config;
    late List<_Transport> transports;
    late List<Map<String, dynamic>> states;
    var cpuCalls = 0, releases = 0;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('asr-acceleration-test-');
      config = {
        'mode': 'auto',
        'identity': 'model@revision',
        'modelId': 'model',
        'directory': root.path,
        'runtimeDirectory': root.path,
        'durationSeconds': 600.0,
        'threads': 2,
        'language': 'en',
        'pipeline': true,
        'decoding': '',
      };
      transports = [];
      states = [];
      cpuCalls = 0;
      releases = 0;
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });
    Future<Map<String, dynamic>> cpu() async {
      cpuCalls++;
      await Future<void>.delayed(const Duration(milliseconds: 12));
      return {
        'text': 'Hello world',
        'tokens': ['Hello', 'world'],
        'timestamps': [0.0, .5],
      };
    }

    AsrAcceleratedDecoder decoder({_Transport Function()? factory}) =>
        AsrAcceleratedDecoder(
          configuration: config,
          releaseCpu: () => releases++,
          onState: states.add,
          openTransport: () async {
            final value = factory?.call() ?? _Transport();
            transports.add(value);
            return value;
          },
          now: () => now,
        );
    final audio = Float32List(4 * 16000);
    test(
      'one failing GPU probe keeps a working FP32 route and releases every probe process',
      () async {
        config.addAll({
          'mode': 'gpu',
          'gpuDirectory': root.path,
          'gpuIdentity': 'fp32@revision',
        });
        final gpu = {
          'backend': 'opencl',
          'device': 0,
          'label': 'GPU · OpenCL',
          'fingerprint': 'gpu-driver',
          'runtime': 'private-mnn',
          'requiresFloatWeights': true,
        };
        final probes = <String?>[];
        final session = decoder(
          factory: () => _Transport(
            capabilities: (request) async {
              final route = request['probeBackend'] as String?;
              probes.add(route);
              if (route == null)
                return {
                  'devices': [],
                  'optionalBackends': ['vulkan', 'opencl'],
                };
              if (route == 'vulkan') throw StateError('vendor process exited');
              return {
                'devices': [gpu],
              };
            },
          ),
        );
        final result = await session.decode(audio, cpu: cpu, check: () {});
        expect(result['_backend'], 'GPU · OpenCL');
        expect(probes, [null, 'vulkan', 'opencl']);
        expect(transports.take(3).every((t) => t.closed), isTrue);
        expect(transports.last.floating, isTrue);
        expect(cpuCalls, 0);
        await session.close();
        expect(transports.every((t) => t.closed), isTrue);
      },
    );
    test(
      'a float-only route never sends the CPU INT8 export to its loader',
      () async {
        config['mode'] = 'gpu';
        final session = decoder(
          factory: () => _Transport(
            devices: [
              {
                'backend': 'vulkan',
                'device': 0,
                'label': 'GPU · Vulkan',
                'requiresFloatWeights': true,
              },
            ],
          ),
        );
        expect(
          (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
          'CPU',
        );
        expect(transports.single.loads, 0);
        expect(states.last['reason'], contains('FP32'));
        await session.close();
      },
    );
    test('manual CPU never opens or probes a GPU', () async {
      config['mode'] = 'cpu';
      final session = decoder();
      expect(
        (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
        'CPU',
      );
      expect(transports, isEmpty);
      expect(releases, 0);
      expect(cpuCalls, 1);
      await session.close();
    });
    test('uncalibrated short jobs avoid GPU model loading', () async {
      config['durationSeconds'] = 20;
      final session = decoder();
      expect(
        (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
        'CPU',
      );
      expect(transports.fold(0, (int n, t) => n + t.loads), 0);
      expect(transports, isEmpty);
      expect(cpuCalls, 1);
      await session.close();
    });
    test(
      'warm comparison selects measured GPU and reuses one retained session',
      () async {
        final session = decoder();
        final first = await session.decode(audio, cpu: cpu, check: () {});
        expect(first['_backend'], 'GPU · DirectML');
        expect(cpuCalls, 4);
        expect(releases, greaterThan(0));
        expect(states.where((s) => s.containsKey('profile')), hasLength(1));
        final loads = transports.fold(0, (int n, t) => n + t.loads);
        await session.decode(audio, cpu: cpu, check: () {});
        expect(transports.fold(0, (int n, t) => n + t.loads), loads);
        await session.close();
        expect(transports.every((t) => t.closed), isTrue);
        expect(await root.list().toList(), isEmpty);
      },
    );
    test(
      'zero assigned hardware kernels falls back once for the whole task',
      () async {
        config['mode'] = 'gpu';
        final session = decoder(factory: () => _Transport(nodes: 0));
        expect(
          (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
          'CPU',
        );
        await session.decode(audio, cpu: cpu, check: () {});
        expect(transports, hasLength(1));
        expect(cpuCalls, 2);
        expect(transports.single.closed, isTrue);
        await session.close();
      },
    );
    test(
      'unsupported INT8 can use the explicitly installed float pack',
      () async {
        config.addAll({
          'mode': 'gpu',
          'gpuDirectory': root.path,
          'gpuIdentity': 'float@revision',
        });
        final session = decoder(factory: () => _Transport(failInt8: true));
        final output = await session.decode(audio, cpu: cpu, check: () {});
        expect(output['_backend'], 'GPU · DirectML');
        expect(output['_weights'], 'float@revision');
        expect(transports, hasLength(2));
        expect(cpuCalls, 0);
        await session.close();
      },
    );
    for (final manual in [false, true]) {
      test(
        'cached CPU winner respects a manual GPU override ($manual)',
        () async {
          config['mode'] = manual ? 'gpu' : 'auto';
          config['profiles'] = [
            AsrPerformanceProfile(
              signature: asrPerformanceSignature(
                configuration: config,
                device: {
                  'fingerprint': 'physical-gpu:driver-1',
                  'runtime': 'pinned-runtime',
                  'backend': 'directml',
                },
                weights: 'model@revision',
              ),
              testedAt: now,
              backend: 'GPU · DirectML',
              device: 'physical-gpu:driver-1',
              weights: 'model@revision',
              sampleSeconds: 4,
              cpuMs: 10,
              gpuMs: 100,
            ).toJson(),
          ];
          final session = decoder();
          expect(
            (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
            manual ? 'GPU · DirectML' : 'CPU',
          );
          expect(cpuCalls, manual ? 0 : 1);
          expect(
            transports.fold<int>(0, (sum, t) => sum + t.loads),
            manual ? 1 : 0,
          );
          expect(states.where((s) => s.containsKey('profile')), isEmpty);
          await session.close();
        },
      );
    }
    test(
      'a cached long probe chooses CPU for short VAD without remeasuring',
      () async {
        config['profiles'] = [
          AsrPerformanceProfile(
            signature: asrPerformanceSignature(
              configuration: config,
              device: {
                'fingerprint': 'physical-gpu:driver-1',
                'runtime': 'pinned-runtime',
                'backend': 'directml',
              },
              weights: 'model@revision',
            ),
            testedAt: now,
            backend: 'GPU · DirectML',
            device: 'physical-gpu:driver-1',
            weights: 'model@revision',
            sampleSeconds: 10,
            cpuMs: 1000,
            gpuMs: 10,
          ).toJson(),
        ];
        final session = decoder();
        await session.decode(audio, cpu: cpu, check: () {});
        expect(cpuCalls, 1);
        expect(transports.single.loads, 0);
        expect(states.where((s) => s['profile'] != null), isEmpty);
        await session.close();
      },
    );
    void rememberProfiles() {
      final stored = <String, Map<String, dynamic>>{};
      for (final state in states) {
        if (state['clearProfileSignature'] case final String signature) {
          stored.remove(signature);
        }
        if (state['profile'] case final Map value) {
          stored[value['signature'] as String] = Map<String, dynamic>.from(
            value,
          );
        }
      }
      config['profiles'] = stored.values.toList();
    }

    for (final failure in [
      'open',
      'capabilities',
      'unsupported',
      'load',
      'decode',
    ]) {
      test(
        '$failure failure is remembered before GPU startup in the next task',
        () async {
          config['mode'] = 'gpu';
          final session = failure == 'open'
              ? AsrAcceleratedDecoder(
                  configuration: config,
                  releaseCpu: () {},
                  onState: states.add,
                  openTransport: () async =>
                      throw StateError('missing component'),
                  now: () => now,
                )
              : decoder(
                  factory: () => _Transport(
                    failCapabilities: failure == 'capabilities',
                    devices: failure == 'unsupported' ? [] : null,
                    failLoad: failure == 'load',
                    nodes: 0,
                  ),
                );
          expect(
            (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
            'CPU',
          );
          await session.close();
          rememberProfiles();
          expect(
            (config['profiles'] as List).any(
              (p) => p['signature'] == asrAvailabilitySignature(config),
            ),
            isTrue,
          );
          final before = transports.length;
          states.clear();
          config['mode'] = 'auto';
          final next = decoder();
          expect(
            (await next.decode(
              Float32List(9 * 16000),
              cpu: cpu,
              check: () {},
            ))['_backend'],
            'CPU',
          );
          expect(transports.length, before);
          expect(cpuCalls, 2);
          expect(states.any((s) => '${s['reason']}'.contains('不可用')), isFalse);
          expect(states.where((s) => s['profile'] != null), isEmpty);
          await next.close();
        },
      );
    }
    test(
      'failed auto calibration is not repeated by subsequent tasks',
      () async {
        final first = decoder(factory: () => _Transport(nodes: 0));
        await first.decode(audio, cpu: cpu, check: () {});
        await first.close();
        rememberProfiles();
        final opens = transports.length;
        final calls = cpuCalls;
        final next = decoder();
        await next.decode(audio, cpu: cpu, check: () {});
        expect(transports.length, opens);
        expect(cpuCalls, calls + 1);
        await next.close();
      },
    );
    for (final reset in ['expired', 'update', 'pack', 'benchmark', 'clear']) {
      test('$reset allows retry after a remembered failure', () async {
        final failed = AsrPerformanceProfile(
          signature: asrAvailabilitySignature(config),
          testedAt: reset == 'expired'
              ? now.subtract(const Duration(days: 14))
              : now,
          backend: 'GPU',
          device: 'preflight',
          weights: 'model@revision',
          sampleSeconds: 1,
          cpuMs: 0,
          gpuMs: 0,
          failed: true,
        );
        config['profiles'] = [failed.toJson()];
        if (reset == 'update') config['accelerationEnvironment'] = ['new-apk'];
        if (reset == 'pack') {
          config['gpuDirectory'] = root.path;
          config['gpuIdentity'] = 'new-float@revision';
        }
        if (reset == 'clear') config['profiles'] = [];
        if (reset == 'benchmark') config['benchmark'] = true;
        final next = decoder();
        await next.decode(audio, cpu: cpu, check: () {});
        expect(transports, isNotEmpty);
        expect(
          states.any(
            (s) =>
                s['clearProfileSignature'] == asrAvailabilitySignature(config),
          ),
          isTrue,
        );
        await next.close();
      });
    }
    test('unknown or insufficient memory never opens a GPU', () async {
      config.addAll({'mode': 'gpu', 'gpuAllowed': false});
      final session = decoder();
      expect(
        (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
        'CPU',
      );
      expect(transports, isEmpty);
      expect(cpuCalls, 1);
      expect(states.where((s) => s['profile'] != null), isEmpty);
      expect(states.any((s) => '${s['reason']}'.contains('不可用')), isFalse);
      await session.close();
      config['gpuAllowed'] = true;
      final recovered = decoder();
      expect(
        (await recovered.decode(audio, cpu: cpu, check: () {}))['_backend'],
        'GPU · DirectML',
      );
      await recovered.close();
    });
    test(
      'missing hardware provider falls back without loading a model',
      () async {
        config['mode'] = 'gpu';
        final session = decoder(factory: () => _Transport(devices: []));
        expect(
          (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
          'CPU',
        );
        expect(transports.single.loads, 0);
        expect(transports.single.closed, isTrue);
        await session.close();
      },
    );
    test(
      'long speech uses at most twelve identical seconds for both probes',
      () async {
        final session = decoder();
        final lengths = <int>[];
        await session.decode(
          Float32List(24 * 16000),
          cpu: cpu,
          check: () {},
          cpuProbe: (probe) {
            lengths.add(probe.length);
            return cpu();
          },
        );
        expect(lengths, List.filled(4, 12 * 16000));
        expect(
          states
              .where((s) => s['profile'] != null)
              .single['profile']['sampleSeconds'],
          12,
        );
        await session.close();
      },
    );
    test(
      'text mismatch rejects a GPU profile and retains the measured CPU result',
      () async {
        final session = decoder(
          factory: () => _Transport(
            result: {
              'text': 'Completely unrelated output',
              'tokens': <String>[],
              'timestamps': <double>[],
            },
          ),
        );
        final output = await session.decode(audio, cpu: cpu, check: () {});
        expect(output['_backend'], 'CPU');
        expect(output['text'], 'Hello world');
        expect(cpuCalls, 4);
        expect(
          states
              .where((s) => s['profile'] != null)
              .every((s) => s['profile']['failed'] == true),
          isTrue,
        );
        await session.close();
      },
    );
    for (final result in [
      {'text': '', 'tokens': [], 'timestamps': []},
      {
        'text': 'hello',
        'tokens': ['hello'],
        'timestamps': [double.nan],
      },
      {
        'text': 'hello',
        'tokens': ['hello'],
        'timestamps': [0.0],
        'durations': 'invalid',
      },
      {
        'text': 'hello',
        'tokens': ['hello'],
        'timestamps': [0.0],
        'durations': [0.2, 0.3],
      },
      {
        'text': 'hello',
        'tokens': ['hello'],
        'timestamps': [50000.0],
      },
    ]) {
      test(
        'malformed native text or timing cannot reach committed cues ($result)',
        () async {
          config['mode'] = 'gpu';
          final session = decoder(factory: () => _Transport(result: result));
          expect(
            (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
            'CPU',
          );
          expect(cpuCalls, 1);
          expect(transports.single.closed, isTrue);
          await session.close();
        },
      );
    }
    test(
      'timeout after successful GPU output switches once to CPU without trying other packs',
      () async {
        config.addAll({
          'mode': 'gpu',
          'gpuDirectory': root.path,
          'gpuIdentity': 'float@revision',
        });
        final session = decoder(factory: () => _Transport(failAfter: 1));
        final committed = await session.decode(audio, cpu: cpu, check: () {});
        expect(committed['_backend'], 'GPU · DirectML');
        expect(
          (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
          'CPU',
        );
        expect(
          (await session.decode(audio, cpu: cpu, check: () {}))['_backend'],
          'CPU',
        );
        expect(committed['_backend'], 'GPU · DirectML');
        expect(cpuCalls, 2);
        expect(transports, hasLength(1));
        expect(transports.single.closed, isTrue);
        await session.close();
        rememberProfiles();
        final next = decoder();
        await next.decode(audio, cpu: cpu, check: () {});
        expect(transports, hasLength(1));
        await next.close();
      },
    );
    test(
      'cancelling an active GPU request never re-runs the audio on CPU',
      () async {
        config['mode'] = 'gpu';
        var cancelled = false;
        final transport = _Transport(gate: Completer<void>());
        final session = decoder(factory: () => transport);
        final result = session.decode(
          audio,
          cpu: cpu,
          check: () {
            if (cancelled) throw StateError('cancelled');
          },
        );
        final expectation = expectLater(result, throwsStateError);
        await transport.started.future;
        cancelled = true;
        await session.cancel();
        await expectation;
        expect(cpuCalls, 0);
        expect(transport.closed, isTrue);
        expect(states.where((s) => s['profile'] != null), isEmpty);
        await session.close();
      },
    );
    test(
      'cancel during process startup closes the late connection before model loading',
      () async {
        config['mode'] = 'gpu';
        final opened = Completer<AsrAcceleratorTransport>();
        final transport = _Transport();
        final session = AsrAcceleratedDecoder(
          configuration: config,
          releaseCpu: () => releases++,
          onState: states.add,
          openTransport: () => opened.future,
        );
        final output = session.decode(audio, cpu: cpu, check: () {});
        final rejected = expectLater(output, throwsStateError);
        await session.cancel();
        opened.complete(transport);
        await rejected;
        expect(transport.loads, 0);
        expect(transport.closed, isTrue);
        expect(cpuCalls, 0);
        expect(states.where((s) => s['profile'] != null), isEmpty);
        await session.close();
      },
    );
    test(
      'GPU releases before low-memory postprocessing and reloads safely',
      () async {
        config['mode'] = 'gpu';
        final session = decoder();
        await session.decode(audio, cpu: cpu, check: () {});
        await session.releaseForEnhancement();
        expect(transports.single.closed, isTrue);
        await session.decode(audio, cpu: cpu, check: () {});
        expect(transports, hasLength(2));
        expect(cpuCalls, 0);
        await session.close();
      },
    );
  });
}
