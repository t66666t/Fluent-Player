import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';

String encodeStreamingSrt(Iterable<SubtitleItem> cues) {
  String time(Duration value) {
    final ms = value.inMilliseconds;
    return '${(ms ~/ 3600000).toString().padLeft(2, '0')}:'
        '${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:'
        '${(ms ~/ 1000 % 60).toString().padLeft(2, '0')},'
        '${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final out = StringBuffer();
  for (final cue in cues) {
    out.writeln(cue.index);
    out.writeln('${time(cue.startTime)} --> ${time(cue.endTime)}');
    out.writeln(cue.text);
    out.writeln();
  }
  return out.toString();
}

typedef _DecodedStreamJournal = ({
  List<Map<String, dynamic>> records,
  int committed,
  int length,
});

// Keep JSON decoding and word-timing reconstruction off the playback isolate
// when restoring a long job. This closure captures only the journal path.
Future<_DecodedStreamJournal> _readStreamJournal(String path) =>
    Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      final records = <Map<String, dynamic>>[];
      var at = 0;
      while (at < bytes.length) {
        final end = bytes.indexOf(10, at);
        if (end < 0) break;
        final Map<String, dynamic> record;
        try {
          record = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes.sublist(at, end))) as Map,
          );
        } on FormatException {
          break;
        }
        if (record['type'] == 'batch' || record['type'] == 'replace') {
          for (final key in ['primary', 'secondary']) {
            record[key] = (record[key] as List)
                .map((cue) => SubtitleItem.fromTimingJson(cue as Map))
                .toList();
          }
        }
        records.add(record);
        at = end + 1;
      }
      return (records: records, committed: at, length: bytes.length);
    });

/// One writer and one commit record for a primary/translation pair. Recovery
/// touches only an uncommitted suffix; normal appends never read old SRT data.
class StreamingSubtitleStore {
  StreamingSubtitleStore._(this.journal, this.header);
  final File journal;
  final Map<String, dynamic> header;
  var primary = SubtitleCueBuffer(), secondary = SubtitleCueBuffer();
  Map<String, dynamic>? checkpoint;
  bool reconciled = false;
  bool _hasReplacement = false;
  int primaryBytes = 0, secondaryBytes = 0, revision = 0;
  Duration through = Duration.zero;
  SubtitleStreamPhase phase = SubtitleStreamPhase.generating;
  String message = '';
  String? sourceLanguage, targetLanguage;
  List<String> precedingSource = const [];
  final Map<int, String> pendingTranslations = {};
  final Map<int, String> pendingOptimizations = {};
  String optimizationWarning = '';
  Future<void> _writes = Future<void>.value();
  int _journalBytes = 0;
  bool _journalNeedsRepair = false;
  String _outputPath(String value) =>
      header['relativePaths'] == true && !p.isAbsolute(value)
      ? p.normalize(p.join(journal.parent.path, value))
      : value;
  String get primaryPath => _outputPath(header['primaryPath'] as String);
  String? get secondaryPath => header['secondaryPath'] == null
      ? null
      : _outputPath(header['secondaryPath'] as String);
  bool get primaryComplete => header['primaryComplete'] == true;

  static Future<StreamingSubtitleStore> create(
    File journal,
    Map<String, dynamic> header, {
    List<SubtitleItem>? completedPrimary,
  }) async {
    await journal.parent.create(recursive: true);
    final store = StreamingSubtitleStore._(journal, header);
    if (completedPrimary == null) {
      await File(store.primaryPath).writeAsBytes([]);
    } else {
      // The cloud transcript is already committed. Never truncate or rewrite it
      // while its independently generated translation is being appended.
      if (!store.primaryComplete) throw StateError('完整原字幕缺少流式标记');
      store.primaryBytes = await File(store.primaryPath).length();
    }
    if (store.secondaryPath != null) {
      await File(store.secondaryPath!).writeAsBytes([]);
    }
    await store._record({'type': 'header', ...header});
    if (completedPrimary != null) {
      await store._record({
        'type': 'batch',
        'primary': completedPrimary.map((cue) => cue.toTimingJson()).toList(),
        'secondary': <dynamic>[],
        'primaryBytes': store.primaryBytes,
        'secondaryBytes': 0,
        'through': 0,
      });
      store.primary.addAll(completedPrimary);
    }
    return store;
  }

  static Future<StreamingSubtitleStore> open(File journal) async {
    final decoded = await _readStreamJournal(journal.path);
    StreamingSubtitleStore? store;
    for (final record in decoded.records) {
      if (store == null) {
        if (record['type'] != 'header') throw const FormatException('字幕日志头缺失');
        store = StreamingSubtitleStore._(journal, record);
      } else if (record['type'] == 'batch' || record['type'] == 'replace') {
        if (record['type'] == 'replace') {
          store.primary = SubtitleCueBuffer();
          store.secondary = SubtitleCueBuffer();
          store.reconciled = true;
          store._hasReplacement = true;
        }
        store.primary.addAll((record['primary'] as List).cast<SubtitleItem>());
        store.secondary.addAll(
          (record['secondary'] as List).cast<SubtitleItem>(),
        );
        store.primaryBytes = record['primaryBytes'] as int;
        store.secondaryBytes = record['secondaryBytes'] as int;
        store.through = Duration(milliseconds: record['through'] as int);
        if (record['checkpoint'] is Map) {
          store.checkpoint = Map<String, dynamic>.from(
            record['checkpoint'] as Map,
          );
        }
        store.precedingSource = record['sourceContext'] is List
            ? (record['sourceContext'] as List).cast<String>()
            : store.primary.snapshot
                  .skip(
                    (store.primary.snapshot.length - 2).clamp(
                      0,
                      store.primary.snapshot.length,
                    ),
                  )
                  .map((cue) => cue.text)
                  .toList();
        store.revision++;
        if (record['finalized'] == true) {
          store.reconciled = true;
          store.phase = SubtitleStreamPhase.complete;
        }
        final committed = store.primaryComplete
            ? (record['secondary'] as List).cast<SubtitleItem>()
            : (record['primary'] as List).cast<SubtitleItem>();
        for (final cue in committed) {
          store.pendingTranslations.remove(cue.index);
          store.pendingOptimizations.remove(cue.index);
        }
      } else if (record['type'] == 'optimizations') {
        for (final entry in (record['values'] as Map).entries) {
          store.pendingOptimizations[int.parse(entry.key as String)] =
              entry.value as String;
        }
        store.optimizationWarning =
            record['warning'] as String? ?? store.optimizationWarning;
      } else if (record['type'] == 'translations') {
        for (final entry in (record['values'] as Map).entries) {
          store.pendingTranslations[int.parse(entry.key as String)] =
              entry.value as String;
        }
      } else if (record['type'] == 'state') {
        store.phase = SubtitleStreamPhase.values.byName(
          record['phase'] as String,
        );
        store.message = record['message'] as String? ?? '';
      } else if (record['type'] == 'direction') {
        store.sourceLanguage = record['source'] as String;
        store.targetLanguage = record['target'] as String;
      }
    }
    if (store == null) throw const FormatException('字幕日志为空');
    store._journalBytes = decoded.committed;
    if (decoded.committed < decoded.length) {
      final handle = await journal.open(mode: FileMode.append);
      try {
        await handle.truncate(decoded.committed);
      } finally {
        await handle.close();
      }
    }
    await store._repairFile(
      store.primaryPath,
      store.primaryBytes,
      store.primary.snapshot,
      rewrite: store._hasReplacement,
    );
    if (store.secondaryPath != null) {
      await store._repairFile(
        store.secondaryPath!,
        store.secondaryBytes,
        store.secondary.snapshot,
        rewrite: store._hasReplacement,
      );
    }
    return store;
  }

  Future<void> _repairFile(
    String path,
    int size,
    List<SubtitleItem> cues, {
    bool rewrite = false,
  }) async {
    final file = File(path);
    if (rewrite) {
      // A final OCR cleanup can alter an earlier line without changing the
      // file length. Its durable replacement record is authoritative on replay.
      final temporary = File('$path.reconcile');
      await temporary.writeAsString(encodeStreamingSrt(cues), flush: true);
      await temporary.rename(path);
    } else if (!await file.exists() || await file.length() < size) {
      await file.writeAsString(encodeStreamingSrt(cues), flush: true);
    } else if (await file.length() > size) {
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(size);
      } finally {
        await handle.close();
      }
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _repairJournalTail() async {
    final handle = await journal.open(mode: FileMode.append);
    try {
      await handle.truncate(_journalBytes);
      _journalNeedsRepair = false;
    } finally {
      await handle.close();
    }
  }

  Future<void> _record(Map<String, dynamic> record) async {
    if (_journalNeedsRepair) await _repairJournalTail();
    final bytes = utf8.encode('${jsonEncode(record)}\n');
    try {
      await journal.writeAsBytes(
        bytes,
        mode: _journalBytes == 0 ? FileMode.write : FileMode.append,
        flush: true,
      );
    } catch (_) {
      _journalNeedsRepair = true;
      try {
        await _repairJournalTail();
      } on FileSystemException {
        // Retry the truncation before the next write or same-process resume.
      }
      rethrow;
    }
    _journalBytes += bytes.length;
  }

  Future<void> direction(String source, String target) => _serial(() async {
    if (targetLanguage != null) return;
    await _record({'type': 'direction', 'source': source, 'target': target});
    sourceLanguage = source;
    targetLanguage = target;
  });

  Future<void> rememberTranslations(Map<int, String> values) =>
      _serial(() async {
        if (values.isEmpty) return;
        await _record({
          'type': 'translations',
          'values': {
            for (final entry in values.entries) '${entry.key}': entry.value,
          },
        });
        pendingTranslations.addAll(values);
      });

  Future<void> rememberOptimizations(
    Map<int, String> values, {
    String? warning,
  }) => _serial(() async {
    if (values.isEmpty) return;
    await _record({
      'type': 'optimizations',
      'values': {
        for (final entry in values.entries) '${entry.key}': entry.value,
      },
      'warning': ?warning,
    });
    pendingOptimizations.addAll(values);
    if (warning != null) optimizationWarning = warning;
  });

  Future<void> append(
    List<SubtitleItem> originals,
    List<SubtitleItem> translations,
    Duration processedThrough, {
    List<String>? sourceContext,
    Map<String, dynamic>? checkpoint,
    bool finalized = false,
  }) => _serial(() async {
    if (primaryComplete
        ? originals.isNotEmpty
        : secondaryPath != null && originals.length != translations.length) {
      throw StateError('原文与译文尚未全部完成');
    }
    final first = utf8.encode(encodeStreamingSrt(originals));
    final second = utf8.encode(encodeStreamingSrt(translations));
    try {
      if (!primaryComplete && first.isNotEmpty) {
        await File(
          primaryPath,
        ).writeAsBytes(first, mode: FileMode.append, flush: true);
      }
      if (secondaryPath != null && second.isNotEmpty) {
        await File(
          secondaryPath!,
        ).writeAsBytes(second, mode: FileMode.append, flush: true);
      }
      await _record({
        'type': 'batch',
        'primary': originals.map((cue) => cue.toTimingJson()).toList(),
        'secondary': translations.map((cue) => cue.toTimingJson()).toList(),
        'primaryBytes': primaryBytes + first.length,
        'secondaryBytes': secondaryBytes + second.length,
        'through': processedThrough.inMilliseconds,
        'sourceContext': ?sourceContext,
        'checkpoint': ?checkpoint,
        if (finalized) 'finalized': true,
      });
    } catch (_) {
      await _repairFile(primaryPath, primaryBytes, primary.snapshot);
      if (secondaryPath != null) {
        await _repairFile(secondaryPath!, secondaryBytes, secondary.snapshot);
      }
      rethrow;
    }
    primary.addAll(originals);
    secondary.addAll(translations);
    primaryBytes += first.length;
    secondaryBytes += second.length;
    through = processedThrough;
    if (checkpoint != null) this.checkpoint = checkpoint;
    precedingSource =
        sourceContext ??
        originals
            .skip((originals.length - 2).clamp(0, originals.length))
            .map((cue) => cue.text)
            .toList();
    revision++;
    if (finalized) {
      reconciled = true;
      phase = SubtitleStreamPhase.complete;
    }
    for (final cue in primaryComplete ? translations : originals) {
      pendingTranslations.remove(cue.index);
      pendingOptimizations.remove(cue.index);
    }
  });

  /// Reconcile provisional OCR output once, preserving its stable file paths.
  /// Commit the recoverable content before replacing an output. A process exit
  /// between those steps is repaired from the journal, including equal sizes.
  Future<void> replaceAll(
    List<SubtitleItem> originals,
    List<SubtitleItem> translations,
    Duration processedThrough,
  ) => _serial(() async {
    if (primaryComplete ||
        secondaryPath != null && originals.length != translations.length) {
      throw StateError('字幕定稿的轨道不匹配');
    }
    final first = utf8.encode(encodeStreamingSrt(originals));
    final second = utf8.encode(encodeStreamingSrt(translations));
    await _record({
      'type': 'replace',
      'primary': originals.map((cue) => cue.toTimingJson()).toList(),
      'secondary': translations.map((cue) => cue.toTimingJson()).toList(),
      'primaryBytes': first.length,
      'secondaryBytes': second.length,
      'through': processedThrough.inMilliseconds,
      'finalized': true,
    });
    primary = SubtitleCueBuffer()..addAll(originals);
    secondary = SubtitleCueBuffer()..addAll(translations);
    primaryBytes = first.length;
    secondaryBytes = second.length;
    through = processedThrough;
    reconciled = true;
    _hasReplacement = true;
    revision++;
    await _repairFile(
      primaryPath,
      primaryBytes,
      primary.snapshot,
      rewrite: true,
    );
    if (secondaryPath != null) {
      await _repairFile(
        secondaryPath!,
        secondaryBytes,
        secondary.snapshot,
        rewrite: true,
      );
    }
    phase = SubtitleStreamPhase.complete;
  });

  Future<void> setPhase(SubtitleStreamPhase value, [String note = '']) =>
      _serial(() async {
        await _record({'type': 'state', 'phase': value.name, 'message': note});
        phase = value;
        message = note;
      });
  Future<void> get drained => _writes;
  Future<void> recoverOutputs() async {
    await drained;
    await _repairJournalTail();
    await _repairFile(
      primaryPath,
      primaryBytes,
      primary.snapshot,
      rewrite: _hasReplacement,
    );
    if (secondaryPath != null) {
      await _repairFile(
        secondaryPath!,
        secondaryBytes,
        secondary.snapshot,
        rewrite: _hasReplacement,
      );
    }
  }
}
