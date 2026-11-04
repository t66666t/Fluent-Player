import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/ocr_subtitle_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';

SubtitleItem _cue(int index, {String text = '字幕'}) => SubtitleItem(
  index: index,
  text: '$text $index',
  startTime: Duration(seconds: index * 2),
  endTime: Duration(seconds: index * 2 + 1),
);

Map<String, dynamic> _checkpoint(int count) => {
  'version': 1,
  'stableCount': count,
  'held': <dynamic>[],
  'text': '',
  'startMs': null,
  'lastObservedMs': 5000,
};

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ocr-stream-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<OcrSubtitleStream> create() => OcrSubtitleStream.create(
    directory: Directory('${root.path}/run'),
    metadata: {
      'version': 1,
      'generationId': 'run',
      'fingerprint': 'frozen',
      'request': {'startMs': 0, 'endMs': 2000000},
    },
    paths: {1: '${root.path}/中文.srt', 2: '${root.path}/English.srt'},
  );

  test(
    'slow writer coalesces completed blocks and independently appends regions',
    () async {
      final run = await create();
      final inputs = <int, List<SubtitleItem>>{1: [], 2: []};
      run.cuesBetween = (number, from, to) => inputs[number]!.sublist(from, to);
      final reached = Completer<void>(), release = Completer<void>();
      run.onCommitted = () async {
        if (!reached.isCompleted) {
          reached.complete();
          await release.future;
        }
      };
      OcrStreamCheckpoint snapshot(int block) => OcrStreamCheckpoint(
        throughMs: 5000 + (block - 1) * 15000,
        stableCounts: {for (final e in inputs.entries) e.key: e.value.length},
        states: {
          for (final e in inputs.entries) e.key: _checkpoint(e.value.length),
        },
      );
      inputs[1]!.add(_cue(1));
      run.observe(snapshot(1));
      await reached.future;
      final old = run.stores[1]!.primary.snapshot;
      for (var block = 2; block <= 100; block++) {
        inputs[1]!.add(_cue(block));
        if (block.isEven) inputs[2]!.add(_cue(block ~/ 2, text: 'English'));
        run.observe(snapshot(block));
      }
      release.complete();
      await run.flush();
      expect(run.commitCount, 2);
      expect(old.length, 1);
      expect(run.stores[1]!.primary.snapshot.length, 100);
      expect(run.stores[2]!.primary.snapshot.length, 50);
      final records = const LineSplitter()
          .convert(await run.stores[1]!.journal.readAsString())
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(records.where((r) => r['type'] == 'batch'), hasLength(2));
      expect((records.last['primary'] as List).length, 99);
      await run.pause();
      final restored = await OcrSubtitleStream.open(run.directory);
      expect(restored.stores[1]!.primary.snapshot.length, 100);
      expect(restored.stores[2]!.primary.snapshot.length, 50);
      expect(restored.resumeFromMs, 1490000);
    },
  );

  test(
    'a multi-region interrupted commit resumes at the lagging boundary',
    () async {
      final run = await create();
      await run.stores[1]!.append(
        [_cue(1)],
        [],
        const Duration(seconds: 20),
        checkpoint: _checkpoint(1),
      );
      await run.stores[2]!.append(
        [_cue(1, text: 'English')],
        [],
        const Duration(seconds: 5),
        checkpoint: _checkpoint(1),
      );
      final restored = await OcrSubtitleStream.open(run.directory);
      expect(restored.resumeFromMs, 5000);
      expect(restored.stores[1]!.through, const Duration(seconds: 20));
      expect(restored.stores[2]!.through, const Duration(seconds: 5));
      await File(restored.stores[2]!.primaryPath).writeAsString('');
      await restored.resume();
      expect(
        await File(restored.stores[2]!.primaryPath).readAsString(),
        encodeStreamingSrt([_cue(1, text: 'English')]),
      );
      // A process can also exit between finalizing the two output files.
      await restored.stores[1]!.append(
        [_cue(2)],
        [],
        const Duration(milliseconds: 2000000),
        finalized: true,
      );
      final interruptedFinal = await OcrSubtitleStream.open(run.directory);
      expect(interruptedFinal.stores[1]!.reconciled, isTrue);
      expect(interruptedFinal.resumeFromMs, 5000);
      await interruptedFinal.finish({
        1: [_cue(1), _cue(2)],
        2: [_cue(1, text: 'English'), _cue(2, text: 'English')],
      }, 2000000);
      expect(interruptedFinal.complete, isTrue);
      expect(interruptedFinal.stores[1]!.primary.snapshot.length, 2);
      expect(interruptedFinal.stores[2]!.primary.snapshot.length, 2);
    },
  );

  test(
    'same-process resume discards uncommitted snapshots until a new block completes',
    () async {
      final run = await create();
      run.cuesBetween = (track, from, to) {
        if (track == 2) throw StateError('simulated failed region commit');
        return [_cue(1)];
      };
      run.observe(
        OcrStreamCheckpoint(
          throughMs: 20000,
          stableCounts: {1: 1, 2: 1},
          states: {1: _checkpoint(1), 2: _checkpoint(1)},
        ),
      );
      await expectLater(run.flush(), throwsStateError);
      expect(run.stores[1]!.through.inMilliseconds, 20000);
      expect(run.stores[2]!.through.inMilliseconds, 0);
      await run.resume();
      run.cuesBetween = (_, _, _) => throw StateError('no new completed block');
      await run.pause();
      final restored = await OcrSubtitleStream.open(run.directory);
      expect(restored.stores[1]!.primary.snapshot.length, 1);
      expect(restored.stores[2]!.primary.snapshot, isEmpty);
      expect(restored.resumeFromMs, 0);
    },
  );

  test(
    'final cleanup replaces snapshots and repairs an equal-sized stale file',
    () async {
      final run = await create();
      final store = run.stores[1]!;
      await store.append(
        [_cue(1, text: 'OLD')],
        [],
        const Duration(seconds: 5),
        checkpoint: _checkpoint(1),
      );
      final old = store.primary.snapshot;
      final before = await File(store.primaryPath).readAsBytes();
      await store.replaceAll(
        [_cue(1, text: 'NEW')],
        [],
        const Duration(seconds: 20),
      );
      expect(old.single.text, 'OLD 1');
      expect(store.primary.snapshot.single.text, 'NEW 1');
      expect(isSubtitleAppend(old, store.primary.snapshot), isFalse);
      // Simulate a process exit after its replacement commit but before rename.
      await File(store.primaryPath).writeAsBytes(before, flush: true);
      final restored = await StreamingSubtitleStore.open(store.journal);
      expect(restored.reconciled, isTrue);
      expect(
        await File(store.primaryPath).readAsString(),
        encodeStreamingSrt([_cue(1, text: 'NEW')]),
      );
    },
  );

  test(
    'final output supersedes an unsubmitted checkpoint without an extra disk batch',
    () async {
      final run = await create();
      run.cuesBetween = (_, _, _) => throw StateError('redundant checkpoint');
      // No new stable text to publish yet; this only advances an unsubmitted
      // block's pending recovery state. The final tail can commit it directly.
      run.observe(
        OcrStreamCheckpoint(
          throughMs: 20000,
          stableCounts: {1: 0, 2: 0},
          states: {1: _checkpoint(0), 2: _checkpoint(0)},
        ),
      );
      await run.finish({
        1: [_cue(1)],
        2: [_cue(1, text: 'English')],
      }, 2000000);
      expect(run.complete, isTrue);
      expect(run.commitCount, 0);
      for (final store in run.stores.values) {
        final records = const LineSplitter()
            .convert(await store.journal.readAsString())
            .map((line) => jsonDecode(line) as Map)
            .toList();
        expect(records.map((r) => r['type']), ['header', 'batch']);
        expect(records.last['finalized'], isTrue);
      }
      final restored = await OcrSubtitleStream.open(run.directory);
      expect(restored.complete, isTrue);
      expect(restored.stores[1]!.primary.snapshot.single.text, '字幕 1');
    },
  );

  test(
    'unchanged final prefix appends only the tail and records completion once',
    () async {
      final run = await create();
      await run.stores[1]!.append(
        [_cue(1)],
        [],
        const Duration(seconds: 5),
        checkpoint: _checkpoint(1),
      );
      final prefix = run.stores[1]!.primary.snapshot;
      await run.finish({
        1: [_cue(1), _cue(2)],
        2: [_cue(1, text: 'English')],
      }, 2000000);
      expect(run.complete, isTrue);
      expect(isSubtitleAppend(prefix, run.stores[1]!.primary.snapshot), isTrue);
      final records = const LineSplitter()
          .convert(await run.stores[1]!.journal.readAsString())
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(records.map((r) => r['type']), ['header', 'batch', 'batch']);
      expect(records.last['finalized'], isTrue);
      expect((records.last['primary'] as List).length, 1);
      final restored = await OcrSubtitleStream.open(run.directory);
      expect(restored.complete, isTrue);
      expect(restored.stores[1]!.primary.snapshot.map((cue) => cue.index), [
        1,
        2,
      ]);
    },
  );

  test(
    'OCR journals and private video paths survive an application-data relocation',
    () async {
      final folder = Directory('${root.path}/subtitles/ocr_streams/portable');
      final run = await OcrSubtitleStream.create(
        directory: folder,
        metadata: {
          'version': 1,
          'generationId': 'portable',
          'fingerprint': 'frozen',
          'videoPathRelativeToRoot': true,
          'request': {
            'startMs': 0,
            'endMs': 10000,
            'videoPath': 'media/movie.mp4',
          },
        },
        paths: {1: '${root.path}/subtitles/中文.srt'},
      );
      await run.stores[1]!.append(
        [_cue(1)],
        [],
        const Duration(seconds: 5),
        checkpoint: _checkpoint(1),
      );
      // Both paths are test-owned children of the same temporary parent.
      final destination = Directory('${root.path}-moved');
      expect(destination.parent.path, root.parent.path);
      root = await root.rename(destination.path);
      final restored = await OcrSubtitleStream.open(
        Directory('${root.path}/subtitles/ocr_streams/portable'),
      );
      expect(
        p.normalize(File(restored.paths.single).absolute.path),
        p.normalize(File('${root.path}/subtitles/中文.srt').absolute.path),
      );
      expect(
        restored.request['videoPath'],
        p.normalize(File('${root.path}/media/movie.mp4').absolute.path),
      );
      expect(
        await File(restored.paths.single).readAsString(),
        encodeStreamingSrt([_cue(1)]),
      );
    },
  );
}
