import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/models/ocr_model_files.dart';
import 'package:video_player_app/services/ocr_android_worker.dart';
import 'package:video_player_app/services/ocr_process_worker.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.example.video_player_app/ocr_acceleration',
  );
  const files = OcrModelFiles(
    detection: 'det.onnx',
    recognition: 'rec.onnx',
    dictionary: 'dict.txt',
    legacy: true,
    identity: 'small-revision',
  );
  test(
    'concurrent closes wait for service retirement before reusing a slot',
    () async {
      final retired = Completer<void>();
      final closing = Completer<void>();
      final starts = <int>[];
      var closes = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = call.arguments as Map;
        final slot = args['slot'] as int;
        if (call.method == 'close') {
          if (slot == 0) {
            closes++;
            if (!closing.isCompleted) closing.complete();
            await retired.future;
          }
          return null;
        }
        starts.add(slot);
        return {
          'runtimeVersion': 'test',
          'backends': ['CPU'],
        };
      });
      AndroidOcrWorker? first, second, replacement;
      try {
        first = await AndroidOcrWorker.start(files);
        second = await AndroidOcrWorker.start(files);
        final firstClose = first.close();
        await closing.future;
        var closedAgain = false;
        final secondClose = first.close().then((_) => closedAgain = true);
        await Future<void>.delayed(Duration.zero);
        expect(closedAgain, isFalse);
        await expectLater(AndroidOcrWorker.start(files), throwsStateError);
        retired.complete();
        await Future.wait([firstClose, secondClose]);
        replacement = await AndroidOcrWorker.start(files);
        expect(starts, [0, 1, 0]);
        expect(closes, 1);
      } finally {
        if (!retired.isCompleted) retired.complete();
        await first?.close();
        await second?.close();
        await replacement?.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test('a late ready reply cannot resurrect a cancelled startup', () async {
    final loading = Completer<void>();
    final ready = Completer<Map<String, Object?>>();
    final closed = Completer<void>();
    final cancel = Completer<void>();
    const stalePid = 908172;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'close') {
        if (!closed.isCompleted) closed.complete();
        return null;
      }
      loading.complete();
      return ready.future;
    });
    AndroidOcrWorker? unexpected;
    try {
      final pending = AndroidOcrWorker.start(
        files,
        cancelSignal: cancel.future,
      );
      await loading.future;
      cancel.complete();
      await closed.future;
      ready.complete({
        'runtimeVersion': 'test',
        'backends': ['CPU'],
        'workerPid': stalePid,
      });
      await expectLater(
        pending.then((worker) => unexpected = worker),
        throwsA(isA<OcrWorkerProcessFailure>()),
      );
      expect(InferenceProcessRegistry.instance.pids, isNot(contains(stalePid)));
    } finally {
      await unexpected?.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });
  test(
    'one crashing GPU probe preserves other Android acceleration routes',
    () async {
      var closes = 0;
      final checked = <String?>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'close') {
          closes++;
          return null;
        }
        final command = (call.arguments as Map)['command'] as Map;
        final provider = command['onlyProvider'] as String?;
        checked.add(provider);
        if (provider == 'Vulkan') return {'workerFailure': true};
        return {
          'platform': 'android',
          'isolated': true,
          'providers': ['CPU', 'OpenCL', 'Vulkan', 'QNN GPU', 'QNN HTP'],
          'devices': provider == 'OpenCL'
              ? [
                  {
                    'provider': provider,
                    'id': 0,
                    'key': 'OpenCL:phone',
                    'name': 'Adreno',
                  },
                ]
              : [],
        };
      });
      try {
        final result = await AndroidOcrWorker.probe();
        expect(result.accelerators.map((d) => d.provider), ['OpenCL']);
        expect(result.note, contains('Vulkan'));
        expect(checked, [null, 'OpenCL', 'Vulkan', 'QNN GPU', 'QNN HTP']);
        expect(closes, 2);
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test(
    'Android CPU workers have separate slots and one native exit does not close the other',
    () async {
      final requests = <int, List<String>>{};
      final closed = <int>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = Map<String, Object?>.from(call.arguments as Map),
            slot = args['slot'] as int;
        if (call.method == 'close') {
          closed.add(slot);
          return null;
        }
        final command = Map<String, Object?>.from(args['command'] as Map);
        requests.putIfAbsent(slot, () => []).add(command['op'] as String);
        if (command['op'] == 'start') {
          return {
            'runtimeVersion': '1.23.2',
            'backends': ['CPU', 'NNAPI'],
            'workerPid': 10001 + slot,
          };
        }
        if (command['op'] == 'frame' && slot == 0) {
          return {'workerFailure': true};
        }
        if (command['op'] == 'frame') {
          return {
            'backend': 'CPU（2 线程）',
            'candidate': true,
            'text': 'English subtitle',
            'confidence': .95,
            'boundaryMs': 100,
            'checkpoint': {'pendingChange': false},
            'timingsUs': <String, int>{},
          };
        }
        return <String, Object?>{};
      });
      AndroidOcrWorker? first, second;
      try {
        first = await AndroidOcrWorker.start(files);
        second = await AndroidOcrWorker.start(files);
        expect(first.isolated, isTrue);
        expect(second.isolated, isTrue);
        await expectLater(AndroidOcrWorker.start(files), throwsStateError);
        Future<OcrFrameAnalysis> frame(OcrWorker w) => w.analyzeRawFrame(
          path: 'frames.rgb',
          offset: 0,
          width: 640,
          height: 128,
          atMs: 100,
          track: 1,
          threads: 2,
          batchLimit: 1,
        );
        await expectLater(
          frame(first),
          throwsA(isA<OcrWorkerProcessFailure>()),
        );
        await first.close();
        final other = await frame(second);
        expect(other.text, 'English subtitle');
        expect(second.checkpoints.keys, [1]);
        expect(closed, [0]);
        expect(requests[0], ['start', 'frame']);
        expect(requests[1], ['start', 'frame']);
      } finally {
        await first?.close();
        await second?.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test(
    'Android restores a CPU recovery process with bounded initial settings',
    () async {
      final requests = <Map<String, Object?>>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'close') return null;
        final command = Map<String, Object?>.from(
          (call.arguments as Map)['command'] as Map,
        );
        requests.add(command);
        return command['op'] == 'start'
            ? {
                'runtimeVersion': '1.23.2',
                'backends': ['CPU'],
              }
            : <String, Object?>{};
      });
      AndroidOcrWorker? worker;
      try {
        worker = await AndroidOcrWorker.start(
          files,
          cpuThreads: 1,
          batchLimit: 1,
          conservative: true,
        );
        final state = {
          1: <String, dynamic>{
            'lastForcedMs': 6000,
            'pending': {
              'text': 'subtitle',
              'confidence': .9,
              'boundaryMs': 6600,
            },
          },
        };
        await worker.restoreFrameHistory(state);
        expect(requests.first['conservative'], isTrue);
        expect(requests.first['threads'], 1);
        expect(requests.first['batchLimit'], 1);
        expect(requests.last['op'], 'restore');
        expect(worker.checkpoints, state);
      } finally {
        await worker?.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
  test(
    'cancellation during Android model loading closes only that pending worker',
    () async {
      final loading = Completer<void>(),
          result = Completer<Map<String, Object?>>();
      final cancelled = Completer<void>();
      var closes = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'close') {
          closes++;
          if (!result.isCompleted) result.complete({'workerFailure': true});
          return null;
        }
        loading.complete();
        return result.future;
      });
      try {
        final pending = AndroidOcrWorker.start(
          files,
          cancelSignal: cancelled.future,
        );
        await loading.future;
        final assertion = expectLater(
          pending,
          throwsA(isA<OcrWorkerProcessFailure>()),
        );
        cancelled.complete();
        await assertion;
        expect(closes, 1);
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}
