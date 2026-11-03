import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/cloud_asr_adapters.dart';
import 'package:video_player_app/features/model_center/cloud_asr_pipeline.dart';
import 'package:video_player_app/features/model_center/cloud_asr_transport.dart';
import 'package:video_player_app/features/model_center/cloud_asr_types.dart';

import 'cloud_asr_test_support.dart';

class _Adapter extends CloudAsrAdapter {
  _Adapter(super.connection, this.action, {this.onCleanup})
    : super(dio: cloudTestDio());
  final Future<dynamic> Function(String?, Map<String, dynamic>) action;
  final void Function(Map<String, dynamic>)? onCleanup;
  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) => action(filePath, state);
  @override
  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async => onCleanup?.call(state);
}

Map<String, dynamic> _speech(String text, {double start = 3, double end = 4}) =>
    {
      'text': text,
      'words': [
        {'type': 'word', 'text': text, 'start': start, 'end': end},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Map<String, dynamic> pieces, remote;
  late Map<String, Duration> origins;
  late List<({Duration start, Duration length, bool force, String path})>
  prepared;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloud-asr-pipeline-');
    pieces = {};
    remote = {};
    origins = {};
    prepared = [];
  });
  tearDown(() async => root.delete(recursive: true));
  Future<CloudAsrAudio> prepare(
    Duration start,
    Duration length,
    bool force,
    void Function(double) progress,
  ) async {
    final path = '${root.path}/${prepared.length}.mp3';
    prepared.add((start: start, length: length, force: force, path: path));
    origins[path] = start;
    await File(path).writeAsBytes([73, 68, 51, 0]);
    return CloudAsrAudio(path);
  }

  CloudAsrConnection connection({int seconds = 10, int bytes = 20000000}) =>
      cloudConnection(
        CloudAsrProvider.elevenlabs,
        endpoint: 'http://localhost',
        capabilities: CloudAsrCapabilities(
          maxSeconds: seconds,
          maxBytes: bytes,
        ),
      );
  CloudAsrPipeline pipeline(
    _Adapter adapter, {
    PrepareCloudAsrAudio? audio,
    Future<void> Function()? save,
    CancelToken? token,
  }) => CloudAsrPipeline(
    adapter: adapter,
    prepare: audio ?? prepare,
    pieces: pieces,
    remote: remote,
    save: save ?? () async {},
    token: token ?? CancelToken(),
    progress: (_, _, _) {},
  );

  test(
    'first slice runs before full preparation; out-of-order results persist but publish continuously',
    () async {
      final releaseFirst = Completer<void>(), secondSaved = Completer<void>();
      final called = <Duration>[], published = <Duration>[];
      final adapter = _Adapter(
        connection(),
        (path, state) async {
          final start = origins[path]!;
          state['originUs'] = start.inMicroseconds;
          called.add(start);
          if (start == Duration.zero) await releaseFirst.future;
          return _speech('slice-${start.inSeconds}');
        },
        onCleanup: (state) {
          final origin = state['originUs'];
          expect(
            pieces.keys.any((key) => key.startsWith('$origin:')),
            true,
            reason:
                'Never remove remote resources before durable subtitle checkpoint',
          );
        },
      );
      addTearDown(adapter.close);
      final running =
          pipeline(
            adapter,
            save: () async {
              if (pieces.keys.any((k) => k.startsWith('8000000:')) &&
                  !secondSaved.isCompleted) {
                secondSaved.complete();
              }
            },
          ).run(
            const Duration(seconds: 26),
            onStable: (cues, through) async {
              expect(cues.single.index, published.length + 1);
              published.add(through);
            },
          );
      await secondSaved.future;
      expect(published, isEmpty);
      expect(called, [Duration.zero, const Duration(seconds: 8)]);
      expect(prepared.map((p) => p.start), [
        Duration.zero,
        const Duration(seconds: 8),
        const Duration(seconds: 16),
      ]);
      releaseFirst.complete();
      final result = await running;
      expect(result.map((c) => c.startTime.inSeconds), [3, 11, 19]);
      expect(published, [
        const Duration(seconds: 10),
        const Duration(seconds: 18),
        const Duration(seconds: 26),
      ]);
      expect(pieces.length, 3);
      expect(remote.values.every((s) => s['cleaned'] == true), true);
      expect(prepared.every((p) => !File(p.path).existsSync()), true);
      final count = called.length, fileCount = prepared.length;
      pieces = jsonDecode(jsonEncode(pieces)) as Map<String, dynamic>;
      remote = jsonDecode(jsonEncode(remote)) as Map<String, dynamic>;
      await pipeline(adapter).run(const Duration(seconds: 26));
      expect(
        called.length,
        count,
        reason: 'Resume never recognizes completed slices',
      );
      expect(
        prepared.length,
        fileCount,
        reason: 'Resume never decodes completed slices',
      );
    },
  );

  test(
    'overlap trims only duplicate words, preserving new words in the same cue and silence offset',
    () async {
      final adapter = _Adapter(connection(), (path, state) async {
        if (origins[path] == Duration.zero) {
          return _speech('旧词', start: 8.5, end: 9.5);
        }
        return {
          'text': '旧词新词',
          'words': [
            {'type': 'word', 'text': '旧词', 'start': .5, 'end': 1.5},
            {'type': 'word', 'text': '新词', 'start': 2.1, 'end': 2.8},
          ],
        };
      });
      addTearDown(adapter.close);
      final result = await pipeline(adapter).run(const Duration(seconds: 18));
      expect(result.map((c) => c.text), ['旧词', '新词']);
      expect(result.map((c) => c.startTime.inMilliseconds), [8500, 10100]);
      expect(result.last.timedSpans.single.startTime.inMilliseconds, 10100);
      expect(result.last.timedSpans.single.textStart, 0);
    },
  );

  test(
    'size boundary normalizes once then splits with overlap, and never submits an oversized file',
    () async {
      final submittedSizes = <int>[];
      final adapter = _Adapter(connection(bytes: 1000), (path, state) async {
        submittedSizes.add(await File(path!).length());
        return _speech(
          'split-${origins[path]!.inMilliseconds}',
          start: 1.5,
          end: 2,
        );
      });
      addTearDown(adapter.close);
      await pipeline(
        adapter,
        audio: (start, length, force, progress) async {
          final audio = await prepare(start, length, force, progress);
          final size = force && length <= const Duration(seconds: 6)
              ? 500
              : 2000;
          await File(audio.path).writeAsBytes(List.filled(size, 0));
          return audio;
        },
      ).run(const Duration(seconds: 10));
      expect(
        prepared
            .where(
              (p) =>
                  p.start == Duration.zero &&
                  p.length == const Duration(seconds: 10),
            )
            .map((p) => p.force),
        [false, true],
      );
      expect(remote.values.any((s) => s['children'] is List), true);
      expect(submittedSizes, isNotEmpty);
      expect(submittedSizes.every((s) => s <= 1000), true);
      expect(prepared.any((p) => p.start == const Duration(seconds: 5)), true);
      final count = prepared.length;
      await pipeline(adapter).run(const Duration(seconds: 10));
      expect(prepared.length, count);
    },
  );

  test(
    'format rejection triggers one transcode, while an uncertain POST never does',
    () async {
      var calls = 0;
      final adapter = _Adapter(connection(), (path, state) async {
        if (++calls == 1) {
          throw const CloudAsrException(
            'unsupported audio',
            format: true,
            statusCode: 400,
          );
        }
        return _speech('normalized');
      });
      addTearDown(adapter.close);
      await pipeline(adapter).run(const Duration(seconds: 10));
      expect(prepared.map((p) => p.force), [false, true]);
      pieces.clear();
      remote.clear();
      prepared.clear();
      final uncertain = _Adapter(connection(), (path, state) async {
        state['submitting'] = true;
        throw const CloudAsrException('unknown server result', format: true);
      });
      addTearDown(uncertain.close);
      await expectLater(
        pipeline(uncertain).run(const Duration(seconds: 10)),
        throwsA(isA<CloudAsrException>()),
      );
      expect(prepared.length, 1);
      final before = prepared.length;
      await expectLater(
        pipeline(uncertain).run(const Duration(seconds: 10)),
        throwsA(isA<CloudAsrException>()),
      );
      expect(prepared.length, before);
    },
  );

  test(
    'failure keeps another completed slice and disposes unclaimed prefetch',
    () async {
      final release = Completer<void>(), secondSaved = Completer<void>();
      var failed = false;
      final calls = <int>[];
      final adapter = _Adapter(connection(), (path, state) async {
        final start = origins[path]!.inSeconds;
        calls.add(start);
        if (start == 0 && !failed) {
          await release.future;
          failed = true;
          throw const CloudAsrException('temporary rejection', statusCode: 400);
        }
        return _speech('slice-$start');
      });
      addTearDown(adapter.close);
      final running = pipeline(
        adapter,
        save: () async {
          if (pieces.isNotEmpty && !secondSaved.isCompleted) {
            secondSaved.complete();
          }
        },
      ).run(const Duration(seconds: 26));
      final rejection = expectLater(running, throwsA(isA<CloudAsrException>()));
      await secondSaved.future;
      release.complete();
      await rejection;
      expect(pieces.length, 1);
      expect(prepared.every((p) => !File(p.path).existsSync()), true);
      await pipeline(adapter).run(const Duration(seconds: 26));
      expect(calls.where((s) => s == 8).length, 1);
      expect(pieces.length, 3);
    },
  );

  test(
    'original audio ownership is retained; same account limits are shared and reset next session',
    () async {
      final audio = await prepare(
        Duration.zero,
        const Duration(seconds: 1),
        false,
        (_) {},
      );
      await CloudAsrAudio(audio.path, temporary: false).dispose();
      expect(await File(audio.path).exists(), true);
      final a = _Adapter(connection(), (_, _) async => _speech('a'));
      final b = _Adapter(connection(), (_, _) async => _speech('b'));
      expect(identical(a.transport.budget, b.transport.budget), true);
      final token = CancelToken();
      final first = await a.transport.budget.uploads.acquire(token);
      var opened = false;
      final queued = b.transport.budget.uploads.acquire(token).then((release) {
        opened = true;
        return release;
      });
      await Future<void>.delayed(Duration.zero);
      expect(opened, false);
      first();
      (await queued)();
      a.transport.budget.limited(Duration.zero);
      expect(b.transport.budget.segments.limit, 1);
      a.close();
      b.close();
      final next = _Adapter(connection(), (_, _) async => _speech('new'));
      addTearDown(next.close);
      expect(next.transport.budget.segments.limit, 2);
    },
  );

  test(
    'known silent leading windows need no file preparation or paid request',
    () async {
      var calls = 0;
      final adapter = _Adapter(connection(), (path, state) async {
        calls++;
        return _speech('after-silence');
      });
      addTearDown(adapter.close);
      final result = await pipeline(
        adapter,
        audio: (start, length, force, progress) async {
          if (start == Duration.zero) return const CloudAsrAudio.silence();
          return prepare(start, length, force, progress);
        },
      ).run(const Duration(seconds: 18));
      expect(calls, 1);
      expect(prepared.length, 1);
      expect(result.single.startTime, const Duration(seconds: 11));
      expect(result.single.index, 1);
      expect(pieces['0:10000000:cloud-v1'], isEmpty);
    },
  );

  test(
    'Google word-timestamp feature limit remains stricter than the generic hour limit',
    () async {
      final google = cloudConnection(CloudAsrProvider.gemini);
      final lengths = <Duration>[];
      final adapter = _Adapter(
        google,
        (_, _) async => cloudReply(CloudAsrProvider.gemini),
      );
      addTearDown(adapter.close);
      await pipeline(
        adapter,
        audio: (start, length, force, progress) async {
          lengths.add(length);
          return prepare(start, length, force, progress);
        },
      ).run(const Duration(minutes: 61));
      expect(lengths.length, 7);
      expect(lengths.every((d) => d <= const Duration(minutes: 10)), true);
      expect(
        lengths.every((d) => d.inSeconds <= google.capabilities.maxSeconds),
        true,
      );
      expect(
        lengths.last.inSeconds,
        72,
        reason: 'Overlaps count toward duration and each slice limit',
      );
    },
  );
}
