import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import 'app_storage_service.dart';
import 'streaming_subtitle_store.dart';

/// A completed extraction block is the resume boundary. Each track has its own
/// journal: an interrupted multi-track commit can resume the lagging track
/// without replaying an already committed prefix into the other track.
class OcrStreamCheckpoint {
  OcrStreamCheckpoint({
    required this.throughMs,
    required this.stableCounts,
    required this.states,
  });
  final int throughMs;
  final Map<int, int> stableCounts;
  final Map<int, Map<String, dynamic>> states;
}

typedef OcrStreamCues =
    List<SubtitleItem> Function(int track, int from, int to);

/// OCR adapts the existing transcript journal instead of creating a second
/// subtitle file format. Only one bounded write may be in flight. The latest
/// completed-block checkpoint replaces earlier unsubmitted checkpoints in RAM.
class OcrSubtitleStream {
  OcrSubtitleStream._(this.directory, this.metadata, this.stores);
  final Directory directory;
  final Map<String, dynamic> metadata;
  final Map<int, StreamingSubtitleStore> stores;
  final _clock = Stopwatch()..start();
  Future<void>? _writing;
  OcrStreamCheckpoint? _latest;
  OcrStreamCues? cuesBetween;
  Future<void> Function()? onCommitted;
  Object? _failure;
  StackTrace? _failureStack;
  int _lastSubmittedMs = 0;
  int _intervalMs = 2000;
  bool _accepting = true;
  bool _hasPublished = false;
  int commitCount = 0, savingUs = 0;

  String get generationId => metadata['generationId'] as String;
  String get fingerprint => metadata['fingerprint'] as String;
  String get mediaKey => 'ocr:$generationId';
  bool get selectionOverridden => metadata['selectionOverridden'] == true;
  bool get complete => stores.values.every(
    (store) => store.reconciled && store.phase == SubtitleStreamPhase.complete,
  );
  int get resumeFromMs =>
      stores.values.map((s) => s.through.inMilliseconds).reduce(math.min);
  List<String> get paths =>
      stores.values.map((store) => store.primaryPath).toList();
  Map<String, dynamic> get request {
    final value = Map<String, dynamic>.from(metadata['request'] as Map);
    if (metadata['videoPathRelativeToRoot'] == true) {
      value['videoPath'] = p.normalize(
        p.join(
          directory.parent.parent.parent.path,
          value['videoPath'] as String,
        ),
      );
    }
    return value;
  }

  static Future<OcrSubtitleStream> create({
    required Directory directory,
    required Map<String, dynamic> metadata,
    required Map<int, String> paths,
  }) async {
    await directory.create(recursive: true);
    final stores = <int, StreamingSubtitleStore>{};
    final startMs = (metadata['request'] as Map)['startMs'] as int;
    for (final entry in paths.entries) {
      final relative = p.relative(entry.value, from: directory.path);
      final store = await StreamingSubtitleStore.create(
        File(p.join(directory.path, 'track_${entry.key}.jsonl')),
        {
          'version': 1,
          'generationId': metadata['generationId'],
          'primaryPath': p.isAbsolute(relative)
              ? relative
              : p.posix.joinAll(p.split(relative)),
          'relativePaths': true,
          'track': entry.key,
        },
      );
      store.through = Duration(milliseconds: startMs);
      stores[entry.key] = store;
    }
    final value = OcrSubtitleStream._(directory, {
      ...metadata,
      'tracks': paths.keys.toList(),
    }, stores);
    await value._saveMetadata();
    return value;
  }

  static Future<OcrSubtitleStream> open(Directory directory) async {
    final raw = await readStorageJson(
      File(p.join(directory.path, 'stream.json')),
    );
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['generationId'] is! String ||
        raw['fingerprint'] is! String ||
        raw['request'] is! Map ||
        (raw['request'] as Map)['startMs'] is! int ||
        (raw['request'] as Map)['endMs'] is! int) {
      throw const FormatException('OCR 字幕恢复记录无效');
    }
    final metadata = Map<String, dynamic>.from(raw);
    final stores = <int, StreamingSubtitleStore>{};
    final numbers = (metadata['tracks'] as List).cast<int>();
    if (numbers.isEmpty ||
        numbers.length > 32 ||
        numbers.toSet().length != numbers.length ||
        numbers.any((number) => number < 1)) {
      throw const FormatException('OCR 字幕区域记录无效');
    }
    for (final number in numbers) {
      final store = await StreamingSubtitleStore.open(
        File(p.join(directory.path, 'track_$number.jsonl')),
      );
      if (store.checkpoint == null && !store.reconciled) {
        store.through = Duration(
          milliseconds: (metadata['request'] as Map)['startMs'] as int,
        );
      }
      final request = metadata['request'] as Map;
      if (store.header['generationId'] != metadata['generationId'] ||
          store.header['track'] != number ||
          store.through.inMilliseconds < (request['startMs'] as int) ||
          store.through.inMilliseconds > (request['endMs'] as int) ||
          (!store.reconciled &&
              store.checkpoint != null &&
              (store.checkpoint!['version'] != 1 ||
                  store.checkpoint!['stableCount'] !=
                      store.primary.snapshot.length ||
                  (store.checkpoint!['held'] as List).length > 1))) {
        throw const FormatException('OCR 字幕与恢复边界不一致');
      }
      stores[number] = store;
    }
    final value = OcrSubtitleStream._(directory, metadata, stores);
    value._hasPublished = stores.values.any(
      (store) => store.primary.snapshot.isNotEmpty,
    );
    return value;
  }

  Future<void> _saveMetadata() =>
      writeStorageJson(File(p.join(directory.path, 'stream.json')), metadata);

  Future<void> preserveSelection() async {
    if (selectionOverridden) return;
    metadata['selectionOverridden'] = true;
    await _saveMetadata();
  }

  void checkFailure() {
    if (_failure != null) Error.throwWithStackTrace(_failure!, _failureStack!);
  }

  void observe(OcrStreamCheckpoint checkpoint) {
    checkFailure();
    if (!_accepting) return;
    _latest = checkpoint;
    final newText = checkpoint.stableCounts.entries.any(
      (entry) => entry.value > stores[entry.key]!.primary.snapshot.length,
    );
    if (_writing == null &&
        ((!_hasPublished && newText) ||
            _clock.elapsedMilliseconds - _lastSubmittedMs >= _intervalMs)) {
      _submit(checkpoint);
    }
  }

  void _submit(OcrStreamCheckpoint checkpoint) {
    _lastSubmittedMs = _clock.elapsedMilliseconds;
    final watch = Stopwatch()..start();
    _writing = _save(checkpoint)
        .catchError((Object error, StackTrace stack) {
          _failure = error;
          _failureStack = stack;
        })
        .whenComplete(() {
          savingUs += watch.elapsedMicroseconds;
          // Slow storage gets larger batches, rather than an ever-growing queue.
          _intervalMs = math
              .max(2000, watch.elapsedMilliseconds * 50)
              .clamp(2000, 10000);
          _writing = null;
        });
  }

  Future<void> _save(OcrStreamCheckpoint checkpoint) async {
    for (final entry in stores.entries) {
      final store = entry.value;
      if (store.reconciled ||
          checkpoint.throughMs <= store.through.inMilliseconds) {
        continue;
      }
      final through = checkpoint.stableCounts[entry.key]!;
      final from = store.primary.snapshot.length;
      if (through < from) throw StateError('OCR 字幕提交顺序不一致');
      final additions = cuesBetween!(entry.key, from, through);
      await store.append(
        additions,
        const [],
        Duration(milliseconds: checkpoint.throughMs),
        checkpoint: checkpoint.states[entry.key],
      );
      _hasPublished |= additions.isNotEmpty;
    }
    commitCount++;
    await onCommitted?.call();
  }

  Future<void> flush() async {
    await _writing;
    checkFailure();
    final latest = _latest;
    if (latest == null ||
        !stores.values.any(
          (store) =>
              !store.reconciled &&
              latest.throughMs > store.through.inMilliseconds,
        )) {
      return;
    }
    _submit(latest);
    await _writing;
    checkFailure();
  }

  Future<void> finish(Map<int, List<SubtitleItem>> results, int endMs) async {
    _accepting = false;
    await _writing;
    checkFailure();
    // Finalized output supersedes an unsubmitted checkpoint. Each track's final
    // batch is itself durable; interruption resumes the remaining tracks from
    // their last committed blocks without an extra checkpoint/SRT flush here.
    _latest = null;
    for (final entry in stores.entries) {
      if (!entry.value.reconciled) {
        final finalCues = results[entry.key]!;
        final prefix = entry.value.primary.snapshot;
        var appendOnly = prefix.length <= finalCues.length;
        for (var i = 0; appendOnly && i < prefix.length; i++) {
          final old = prefix[i], next = finalCues[i];
          appendOnly =
              old.index == next.index &&
              old.startTime == next.startTime &&
              old.endTime == next.endTime &&
              old.text == next.text;
        }
        if (appendOnly) {
          await entry.value.append(
            finalCues.skip(prefix.length).toList(),
            const [],
            Duration(milliseconds: endMs),
            finalized: true,
          );
        } else {
          await entry.value.replaceAll(
            finalCues,
            const [],
            Duration(milliseconds: endMs),
          );
        }
      }
      if (entry.value.phase != SubtitleStreamPhase.complete) {
        await entry.value.setPhase(SubtitleStreamPhase.complete);
      }
    }
    await onCommitted?.call();
  }

  Future<void> pause({bool failed = false}) async {
    _accepting = false;
    await flush();
    for (final store in stores.values) {
      if (store.phase != SubtitleStreamPhase.complete) {
        await store.setPhase(
          failed ? SubtitleStreamPhase.failed : SubtitleStreamPhase.paused,
        );
      }
    }
    await onCommitted?.call();
  }

  Future<void> resume({bool repair = true}) async {
    if (repair) {
      for (final store in stores.values) {
        await store.recoverOutputs();
      }
    }
    _accepting = true;
    _failure = null;
    _failureStack = null;
    _latest = null;
    _clock.reset();
    _lastSubmittedMs = 0;
    for (final store in stores.values) {
      if (!store.reconciled) store.phase = SubtitleStreamPhase.generating;
    }
  }

  void releaseMemory() {
    cuesBetween = null;
    _latest = null;
    for (final store in stores.values) {
      store.primary = SubtitleCueBuffer();
      store.secondary = SubtitleCueBuffer();
    }
  }
}
