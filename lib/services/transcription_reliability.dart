import 'dart:convert';

import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

/// 长音频分段、失败重试和字幕拼接的纯逻辑。
///
/// 单次上传按时长切段；仍被拒绝时再对半切开。已经识别成功的
/// 片段会记下来，重试时不再重新上传。
class TranscriptionTiming {
  /// 每 30 分钟切段，各段首尾相接，不重复提交切点附近的音频。
  /// 某一段若仍被拒绝，会再对半切开。
  static const Duration safeSliceLength = Duration(minutes: 30);
  static const Duration sliceOverlap = Duration.zero;
  static const Duration betweenSlices = Duration(seconds: 5);
  static const Duration tailAbsorb = Duration.zero;

  /// 对半切到这个长度以下就停止。再短只会增加请求次数，救不了服务端拒绝。
  static const Duration minimumSliceLength = Duration(seconds: 70);

  static const int safeSliceMs = 30 * 60 * 1000;
  static const int overlapMs = 0;
  static const int minimumSliceMs = 70 * 1000;
  static const int tailAbsorbMs = 0;

  static Duration durationFromProbe({double? seconds, required int fileBytes}) {
    if (seconds != null && seconds.isFinite && seconds >= 0.4) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    // 时长探测失败时按转码后的 48kbps 估算。高码率原文件会被估得偏长，
    // 多出来的尾段在切音频时发现已经到文件末尾就会停，不会多上传。
    if (fileBytes > 0) {
      final estimatedSeconds = (fileBytes * 8 / 48000).ceil().clamp(
        1,
        12 * 60 * 60,
      );
      return Duration(seconds: estimatedSeconds);
    }
    return const Duration(seconds: 1);
  }

  /// `90:00` 和 `1:02:03` 都能解析。媒体库目前用的是总分钟数，不进位到小时。
  static Duration? parseClockLabel(String label) {
    final parts = label.trim().split(':');
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]);
      final seconds = int.tryParse(parts[1]);
      if (minutes == null || seconds == null || seconds < 0 || seconds >= 60) {
        return null;
      }
      return Duration(minutes: minutes, seconds: seconds);
    }
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final seconds = int.tryParse(parts[2]);
      if (hours == null ||
          minutes == null ||
          seconds == null ||
          minutes < 0 ||
          minutes >= 60 ||
          seconds < 0 ||
          seconds >= 60) {
        return null;
      }
      return Duration(hours: hours, minutes: minutes, seconds: seconds);
    }
    return null;
  }

  /// 整段任务的看门狗。短任务仍保持原来的 30 分钟上限；长任务按时长放宽，
  /// 否则两小时的视频会被 30 分钟上限在正常识别过程中杀掉。
  static Duration watchdogForLabel(String label) {
    final parsed = parseClockLabel(label);
    if (parsed == null || parsed <= Duration.zero) {
      return const Duration(hours: 3);
    }
    final budgetMs =
        (parsed.inMilliseconds * 0.8).round() +
        const Duration(minutes: 25).inMilliseconds;
    final budget = Duration(milliseconds: budgetMs);
    if (budget < const Duration(minutes: 30)) {
      return const Duration(minutes: 30);
    }
    if (budget > const Duration(hours: 6)) {
      return const Duration(hours: 6);
    }
    return budget;
  }

  static int estimateSliceCount(
    Duration duration, {
    Duration sliceLength = safeSliceLength,
    Duration absorbTail = tailAbsorb,
  }) {
    if (sliceLength <= sliceOverlap) {
      throw ArgumentError.value(sliceLength, 'sliceLength');
    }
    if (duration <= sliceLength + absorbTail) return 1;
    final sliceMs = sliceLength.inMilliseconds;
    final end = duration.inMilliseconds;
    var cursor = 0;
    var count = 0;
    while (cursor < end - 400 && count < 100) {
      var length = end - cursor;
      final limit = sliceMs + (cursor == 0 ? 0 : overlapMs);
      if (length > limit) {
        final tail = length - limit;
        length = tail < absorbTail.inMilliseconds ? length : limit;
      }
      count++;
      if (cursor + length >= end - 400) break;
      final next = cursor + length - overlapMs;
      cursor = next > cursor ? next : cursor + length;
    }
    return count < 1 ? 1 : count;
  }

  static String describePlan(Duration duration, int sliceCount) {
    final minutes = (duration.inSeconds / 60).ceil().clamp(1, 9999);
    return '这段大约 $minutes 分钟，将分成 $sliceCount 段识别，避免整段被拒绝';
  }
}

class TranscriptionSlice {
  final Duration start;
  final Duration length;

  /// 旧任务开头与已完成片段重复的时长；新切出的片段始终为零。
  final Duration overlap;

  const TranscriptionSlice({
    required this.start,
    required this.length,
    required this.overlap,
  });

  Duration get end => start + length;

  String get taskKey =>
      '${start.inMilliseconds}:${length.inMilliseconds}:words';

  String get rangeLabel => '${_clock(start)}–${_clock(end)}';

  static String _clock(Duration value) {
    final seconds = value.inSeconds;
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final tail = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$tail';
  }

  bool coversEntire(Duration duration) {
    return start == Duration.zero &&
        (duration - length).inMilliseconds.abs() <= 800;
  }
}

class TranscriptionSlicePlanner {
  /// Plans only missing work. Completed pieces and already submitted tasks keep
  /// their original ranges when the default slice length changes.
  static TranscriptionSlice? nextUnfinished({
    required Duration start,
    required Duration duration,
    required TranscriptionTaskCheckpoint checkpoint,
    Duration sliceLength = TranscriptionTiming.safeSliceLength,
    Duration tailAbsorb = TranscriptionTiming.tailAbsorb,
  }) {
    if (sliceLength <= TranscriptionTiming.sliceOverlap) {
      throw ArgumentError.value(sliceLength, 'sliceLength');
    }
    var cursorMs = start.inMilliseconds;
    final endMs = duration.inMilliseconds;
    while (cursorMs < endMs - 400) {
      final saved = checkpoint.pieceStartingAt(cursorMs);
      if (saved != null) {
        cursorMs = cursorAfter(saved.startMs, saved.endMs, endMs);
        continue;
      }
      final pending = checkpoint.pendingSlices(duration);
      for (final slice in pending) {
        if (TranscriptionTaskCheckpoint.startsNearCursor(
              slice.start.inMilliseconds,
              cursorMs,
            ) &&
            slice.end.inMilliseconds > cursorMs + 400) {
          final overlapMs = cursorMs - slice.start.inMilliseconds;
          return TranscriptionSlice(
            start: slice.start,
            length: slice.length,
            overlap: Duration(milliseconds: overlapMs > 0 ? overlapMs : 0),
          );
        }
      }
      final nextSaved = checkpoint.nextPieceAfter(cursorMs);
      var hardEnd = nextSaved == null
          ? endMs
          : nextSaved.startMs + TranscriptionTiming.overlapMs;
      for (final slice in pending) {
        final startMs = slice.start.inMilliseconds;
        if (startMs > cursorMs + 1500 &&
            startMs + TranscriptionTiming.overlapMs < hardEnd) {
          hardEnd = startMs + TranscriptionTiming.overlapMs;
        }
      }
      final overlap = cursorMs == 0 ? 0 : TranscriptionTiming.overlapMs;
      final limit = sliceLength.inMilliseconds + overlap;
      var lengthMs = hardEnd - cursorMs;
      if (lengthMs > limit && lengthMs - limit >= tailAbsorb.inMilliseconds) {
        lengthMs = limit;
      }
      if (lengthMs < 800) {
        cursorMs = hardEnd > cursorMs ? hardEnd : cursorMs + 1000;
        continue;
      }
      return TranscriptionSlice(
        start: Duration(milliseconds: cursorMs),
        length: Duration(milliseconds: lengthMs),
        overlap: Duration(milliseconds: overlap),
      );
    }
    return null;
  }

  static int cursorAfter(int startMs, int endMs, int durationMs) {
    if (endMs >= durationMs - 400) return durationMs;
    final backtracked = endMs - TranscriptionTiming.overlapMs;
    return backtracked > startMs + 1500 ? backtracked : endMs;
  }

  static bool canSplit(TranscriptionSlice slice) {
    return slice.length.inMilliseconds >=
        TranscriptionTiming.minimumSliceMs * 2;
  }

  /// 只有“过长”或“服务端没说原因的拒绝”才继续切。明确的参数/格式错误
  /// 再切也不会成功，只会把风控打得更重。
  static List<TranscriptionSlice>? halvesFor(
    TranscriptionSlice slice,
    GongyiAsrException error,
  ) {
    if (!canSplit(slice)) return null;
    final tooLong = error.kind == GongyiAsrFailureKind.tooLong;
    final vagueFullSlice =
        error.kind == GongyiAsrFailureKind.rejected &&
        slice.length >= TranscriptionTiming.safeSliceLength &&
        TranscriptionUserMessage.isVague(error.message);
    if (!tooLong && !vagueFullSlice) return null;
    return halve(slice);
  }

  static List<TranscriptionSlice> halve(TranscriptionSlice slice) {
    final firstMs = slice.length.inMilliseconds ~/ 2;
    final secondStart =
        slice.start +
        Duration(milliseconds: firstMs) -
        TranscriptionTiming.sliceOverlap;
    final safeSecondStart = secondStart < slice.start
        ? slice.start
        : secondStart;
    final secondLength = slice.end - safeSecondStart;
    return [
      TranscriptionSlice(
        start: slice.start,
        length: Duration(milliseconds: firstMs),
        overlap: slice.overlap,
      ),
      TranscriptionSlice(
        start: safeSecondStart,
        length: secondLength > Duration.zero
            ? secondLength
            : const Duration(seconds: 1),
        overlap: TranscriptionTiming.sliceOverlap,
      ),
    ];
  }
}

class TranscriptionPieceRecord {
  final int startMs;
  final int lengthMs;
  final List<SubtitleItem> cues;

  const TranscriptionPieceRecord({
    required this.startMs,
    required this.lengthMs,
    required this.cues,
  });

  int get endMs => startMs + lengthMs;

  Map<String, Object?> toJson() => {
    'startMs': startMs,
    'lengthMs': lengthMs,
    'cues': [for (final cue in cues) cue.toTimingJson()],
  };

  static TranscriptionPieceRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final startMs = _asInt(raw['startMs']);
    final lengthMs = _asInt(raw['lengthMs']);
    if (startMs == null || lengthMs == null || lengthMs <= 0) return null;
    final cues = <SubtitleItem>[];
    final rawCues = raw['cues'];
    if (rawCues is List) {
      for (final item in rawCues) {
        if (item is! Map) continue;
        final start = _asInt(item['s']);
        final end = _asInt(item['e']);
        final text = item['t']?.toString().trim() ?? '';
        if (start == null || end == null || end <= start || text.isEmpty) {
          continue;
        }
        cues.add(
          SubtitleItem.fromTimingJson(item).trimmed().copyWith(index: 0),
        );
      }
    }
    return TranscriptionPieceRecord(
      startMs: startMs,
      lengthMs: lengthMs,
      cues: cues,
    );
  }
}

class TranscriptionTaskCheckpoint {
  final int sourceBytes;
  final int sourceModifiedMs;
  final String? sourceIdentity;
  final List<TranscriptionPieceRecord> pieces;
  final Map<String, GongyiAsrTaskCheckpoint> remoteTasks;

  TranscriptionTaskCheckpoint({
    required this.sourceBytes,
    required this.sourceModifiedMs,
    this.sourceIdentity,
    List<TranscriptionPieceRecord>? pieces,
    Map<String, GongyiAsrTaskCheckpoint>? remoteTasks,
  }) : pieces = [...?pieces],
       remoteTasks = {...?remoteTasks};

  factory TranscriptionTaskCheckpoint.empty(
    int bytes,
    int modifiedMs, {
    String? identity,
  }) {
    return TranscriptionTaskCheckpoint(
      sourceBytes: bytes,
      sourceModifiedMs: modifiedMs,
      sourceIdentity: identity,
    );
  }

  bool matches(int bytes, int modifiedMs, {String? identity}) {
    final sizeMatches =
        bytes > 0 &&
        modifiedMs > 0 &&
        bytes == sourceBytes &&
        modifiedMs == sourceModifiedMs;
    if (!sizeMatches) return false;
    // Older checkpoints have no identity and keep the size/mtime reuse path.
    if (identity == null || sourceIdentity == null || sourceIdentity!.isEmpty) {
      return true;
    }
    return identity == sourceIdentity;
  }

  bool get hasProgress =>
      pieces.isNotEmpty ||
      remoteTasks.values.any((task) => task.taskId != null);

  void addPiece(TranscriptionPieceRecord piece) {
    pieces.removeWhere(
      (existing) => (existing.startMs - piece.startMs).abs() <= 1500,
    );
    pieces.add(piece);
    pieces.sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  /// 旧片段可能比游标早两秒，额外保留原有的 1.5 秒对齐容差。
  /// 仅用来恢复原范围，不会使新片段重新上传这段音频。
  static bool startsNearCursor(int startMs, int cursorMs) {
    final offset = cursorMs - startMs;
    return offset >= -1500 && offset <= 3500;
  }

  /// 游标附近已经完成的片段；到达这段末尾时不再复用同一段。
  TranscriptionPieceRecord? pieceStartingAt(int cursorMs) {
    TranscriptionPieceRecord? best;
    for (final piece in pieces) {
      if (!startsNearCursor(piece.startMs, cursorMs)) continue;
      if (cursorMs >= piece.endMs - 400) continue;
      if (best == null || piece.lengthMs > best.lengthMs) best = piece;
    }
    return best;
  }

  TranscriptionPieceRecord? nextPieceAfter(int cursorMs) {
    TranscriptionPieceRecord? best;
    for (final piece in pieces) {
      if (piece.startMs <= cursorMs + 1500) continue;
      if (best == null || piece.startMs < best.startMs) best = piece;
    }
    return best;
  }

  List<TranscriptionSlice> pendingSlices(Duration duration) {
    final slices = <TranscriptionSlice>[];
    for (final entry in remoteTasks.entries) {
      if (entry.value.taskId?.isNotEmpty != true) continue;
      final parts = entry.key.split(':');
      if (parts.length != 3 || parts[2] != 'words') continue;
      final startMs = int.tryParse(parts[0]);
      final lengthMs = int.tryParse(parts[1]);
      if (startMs == null ||
          lengthMs == null ||
          startMs < 0 ||
          lengthMs < 800) {
        continue;
      }
      if (startMs + lengthMs > duration.inMilliseconds + 800) continue;
      slices.add(
        TranscriptionSlice(
          start: Duration(milliseconds: startMs),
          length: Duration(milliseconds: lengthMs),
          overlap: startMs == 0
              ? Duration.zero
              : TranscriptionTiming.sliceOverlap,
        ),
      );
    }
    slices.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.length.compareTo(a.length);
    });
    return slices;
  }

  Map<String, Object?> toJson() => {
    'bytes': sourceBytes,
    'modifiedMs': sourceModifiedMs,
    if (sourceIdentity != null) 'identity': sourceIdentity,
    'pieces': [for (final piece in pieces) piece.toJson()],
    'remoteTasks': {
      for (final entry in remoteTasks.entries) entry.key: entry.value.toJson(),
    },
  };

  static TranscriptionTaskCheckpoint? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final bytes = _asInt(raw['bytes']);
    final modifiedMs = _asInt(raw['modifiedMs']);
    if (bytes == null || modifiedMs == null) return null;
    final pieces = <TranscriptionPieceRecord>[];
    final rawPieces = raw['pieces'];
    if (rawPieces is List) {
      for (final item in rawPieces) {
        final piece = TranscriptionPieceRecord.tryParse(item);
        if (piece != null) pieces.add(piece);
      }
    }
    pieces.sort((a, b) => a.startMs.compareTo(b.startMs));
    return TranscriptionTaskCheckpoint(
      sourceBytes: bytes,
      sourceModifiedMs: modifiedMs,
      sourceIdentity: raw['identity'] as String?,
      pieces: pieces,
      remoteTasks: {
        if (raw['remoteTasks'] is Map)
          for (final entry in (raw['remoteTasks'] as Map).entries)
            if (entry.value is Map)
              entry.key.toString(): GongyiAsrTaskCheckpoint.fromJson(
                entry.value as Map,
              ),
      },
    );
  }
}

class TranscriptionCheckpointBook {
  final Map<String, TranscriptionTaskCheckpoint> tasks;

  TranscriptionCheckpointBook({Map<String, TranscriptionTaskCheckpoint>? tasks})
    : tasks = {...?tasks};

  static TranscriptionCheckpointBook decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return TranscriptionCheckpointBook();
      final tasksRaw = decoded['tasks'];
      if (tasksRaw is! Map) return TranscriptionCheckpointBook();
      final tasks = <String, TranscriptionTaskCheckpoint>{};
      for (final entry in tasksRaw.entries) {
        final checkpoint = TranscriptionTaskCheckpoint.tryParse(entry.value);
        if (checkpoint != null) tasks[entry.key.toString()] = checkpoint;
      }
      return TranscriptionCheckpointBook(tasks: tasks);
    } catch (_) {
      return TranscriptionCheckpointBook();
    }
  }

  String encode() {
    return jsonEncode({
      'version': 1,
      'tasks': {
        for (final entry in tasks.entries) entry.key: entry.value.toJson(),
      },
    });
  }
}

/// 按时间轴走完一整段音频：已完成的片段直接复用，缺口按安全长度上传。
class SliceRecognitionSession {
  static Future<List<SubtitleItem>> run({
    required Duration duration,
    required TranscriptionTaskCheckpoint checkpoint,
    required Future<List<SubtitleItem>> Function(
      TranscriptionSlice slice,
      String? label,
      void Function(double innerProgress, String message) onInner,
    )
    transcribe,
    required void Function(String message, double progress) onProgress,
    required Future<void> Function(TranscriptionPieceRecord piece) onPiece,
    required Future<void> Function(Duration delay, String message) waitBetween,
    required void Function() checkCancelled,
    void Function(String message)? log,
    Duration sliceLength = TranscriptionTiming.safeSliceLength,
    Duration tailAbsorb = TranscriptionTiming.tailAbsorb,
  }) async {
    if (sliceLength <= TranscriptionTiming.sliceOverlap) {
      throw ArgumentError.value(sliceLength, 'sliceLength');
    }
    final endMs = duration.inMilliseconds;
    if (endMs <= 0) {
      throw const GongyiAsrException(GongyiAsrFailureKind.rejected, '待识别音频是空的');
    }

    if (checkpoint.hasProgress) {
      onProgress('继续上次未完成的识别，已完成的片段会直接接着用', 0);
      log?.call(
        '[transcription] resume pieces=${checkpoint.pieces.length} durationMs=$endMs',
      );
    } else {
      final count = TranscriptionTiming.estimateSliceCount(
        duration,
        sliceLength: sliceLength,
        absorbTail: tailAbsorb,
      );
      if (count > 1) {
        onProgress(TranscriptionTiming.describePlan(duration, count), 0);
        log?.call('[transcription] plan slices=$count durationMs=$endMs');
      }
    }

    final placed = <SubtitleItem>[];
    var cursorMs = 0;
    var needWait = false;
    var networkCalls = 0;
    for (var guard = 0; cursorMs < endMs - 400 && guard < 500; guard++) {
      checkCancelled();
      final saved = checkpoint.pieceStartingAt(cursorMs);
      if (saved != null) {
        placed.addAll(saved.cues);
        final nextCursor = TranscriptionSlicePlanner.cursorAfter(
          saved.startMs,
          saved.endMs,
          endMs,
        );
        cursorMs = nextCursor > cursorMs ? nextCursor : saved.endMs;
        if (cursorMs <= saved.startMs) cursorMs = saved.endMs;
        final savedSlice = TranscriptionSlice(
          start: Duration(milliseconds: saved.startMs),
          length: Duration(milliseconds: saved.lengthMs),
          overlap: Duration.zero,
        );
        onProgress(
          '${savedSlice.rangeLabel} · 复用已完成片段，累计 ${placed.length} 条字幕',
          (cursorMs / endMs).clamp(0.0, 1.0),
        );
        continue;
      }

      final slice = TranscriptionSlicePlanner.nextUnfinished(
        start: Duration(milliseconds: cursorMs),
        duration: duration,
        checkpoint: checkpoint,
        sliceLength: sliceLength,
        tailAbsorb: tailAbsorb,
      );
      if (slice == null) break;
      cursorMs = slice.start.inMilliseconds;
      final lengthMs = slice.length.inMilliseconds;
      final label =
          '${_sliceLabel(cursorMs, endMs, sliceLength, tailAbsorb)} · ${slice.rangeLabel}';
      final sliceEndMs = cursorMs + lengthMs;
      void report(double inner, String message) {
        final innerClamped = inner.clamp(0.0, 1.0);
        final cursor = cursorMs + (lengthMs * innerClamped);
        onProgress(message, (cursor / endMs).clamp(0.0, 1.0));
      }

      if (needWait) {
        await waitBetween(
          TranscriptionTiming.betweenSlices,
          '$label · 下一段开始前稍等几秒',
        );
      }
      needWait = true;
      networkCalls++;
      if (networkCalls > 400) {
        throw const GongyiAsrException(
          GongyiAsrFailureKind.rejected,
          '这段内容分段过多，已先停下。可以稍后再试',
        );
      }

      try {
        final cues = await _adapt(
          slice: slice,
          label: label,
          report: (inner, message) => report(inner, '$label · $message'),
          depth: 0,
          checkpoint: checkpoint,
          transcribe: transcribe,
          onPiece: onPiece,
          waitBetween: waitBetween,
          checkCancelled: checkCancelled,
          log: log,
        );
        placed.addAll(cues);
        onProgress(
          '$label · 已完成，累计 ${placed.length} 条字幕',
          (sliceEndMs / endMs).clamp(0.0, 1.0),
        );
      } on TranscriptionSlicePastEnd {
        if (placed.isEmpty && cursorMs == 0) rethrow;
        log?.call('[transcription] reached end at ${cursorMs}ms');
        break;
      }

      final isLast = sliceEndMs >= endMs - 400;
      final nextCursor = isLast
          ? endMs
          : sliceEndMs - TranscriptionTiming.overlapMs;
      cursorMs = nextCursor > cursorMs ? nextCursor : cursorMs + lengthMs;
    }

    return TranscriptionSubtitleMerger.finish(placed);
  }

  static String _sliceLabel(
    int cursorMs,
    int endMs,
    Duration sliceLength,
    Duration tailAbsorb,
  ) {
    final duration = Duration(milliseconds: endMs);
    final total = TranscriptionTiming.estimateSliceCount(
      duration,
      sliceLength: sliceLength,
      absorbTail: tailAbsorb,
    );
    if (total <= 1) return '第 1/1 段';
    final index =
        ((cursorMs + TranscriptionTiming.overlapMs) /
                sliceLength.inMilliseconds)
            .floor() +
        1;
    final shown = index.clamp(1, total);
    return '第 $shown/$total 段';
  }

  static Future<List<SubtitleItem>> _adapt({
    required TranscriptionSlice slice,
    required String? label,
    required void Function(double inner, String message) report,
    required int depth,
    required TranscriptionTaskCheckpoint checkpoint,
    required Future<List<SubtitleItem>> Function(
      TranscriptionSlice slice,
      String? label,
      void Function(double innerProgress, String message) onInner,
    )
    transcribe,
    required Future<void> Function(TranscriptionPieceRecord piece) onPiece,
    required Future<void> Function(Duration delay, String message) waitBetween,
    required void Function() checkCancelled,
    void Function(String message)? log,
  }) async {
    checkCancelled();
    try {
      final relative = await transcribe(slice, label, report);
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: relative,
        sliceStart: slice.start,
        overlap: slice.overlap,
        sliceLength: slice.length,
      );
      final record = TranscriptionPieceRecord(
        startMs: slice.start.inMilliseconds,
        lengthMs: slice.length.inMilliseconds,
        cues: placed,
      );
      checkpoint.addPiece(record);
      await onPiece(record);
      log?.call(
        '[transcription] piece start=${record.startMs}ms length=${record.lengthMs}ms cues=${placed.length}',
      );
      return placed;
    } on GongyiAsrException catch (error) {
      if (error.kind == GongyiAsrFailureKind.tooLong &&
          slice.overlap > Duration.zero &&
          checkpoint.remoteTasks[slice.taskKey]?.taskId?.isNotEmpty != true) {
        // Re-query legacy ranges intact, but replacement uploads start at the
        // first unfinished position instead of repeating completed audio.
        return _adapt(
          slice: TranscriptionSlice(
            start: slice.start + slice.overlap,
            length: slice.length - slice.overlap,
            overlap: Duration.zero,
          ),
          label: label,
          report: report,
          depth: depth,
          checkpoint: checkpoint,
          transcribe: transcribe,
          onPiece: onPiece,
          waitBetween: waitBetween,
          checkCancelled: checkCancelled,
          log: log,
        );
      }
      final halves = depth >= 4
          ? null
          : TranscriptionSlicePlanner.halvesFor(slice, error);
      if (halves == null) rethrow;
      log?.call(
        '[transcription] split kind=${error.kind} start=${slice.start.inMilliseconds}ms length=${slice.length.inMilliseconds}ms',
      );
      report(0, '这一段仍被拒绝，改成更短的片段继续');
      final out = <SubtitleItem>[];
      for (var i = 0; i < halves.length; i++) {
        checkCancelled();
        if (i > 0) {
          await waitBetween(TranscriptionTiming.betweenSlices, '改成更短的片段后稍等几秒');
        }
        final childLabel = '较短片段 ${i + 1}/${halves.length}';
        out.addAll(
          await _adapt(
            slice: halves[i],
            label: childLabel,
            report: (inner, message) {
              final width = 1 / halves.length;
              report(
                (i + inner.clamp(0.0, 1.0)) * width,
                '$childLabel · ${halves[i].rangeLabel} · $message',
              );
            },
            depth: depth + 1,
            checkpoint: checkpoint,
            transcribe: transcribe,
            onPiece: onPiece,
            waitBetween: waitBetween,
            checkCancelled: checkCancelled,
            log: log,
          ),
        );
        report(
          (i + 1) / halves.length,
          '$childLabel · ${halves[i].rangeLabel} · 已完成，累计 ${out.length} 条字幕',
        );
      }
      return out;
    }
  }
}

/// 切出来的音频已经越过文件末尾。调用方应结束分段，而不是当成失败。
class TranscriptionSlicePastEnd implements Exception {
  const TranscriptionSlicePastEnd();
}

class TranscriptionSubtitleMerger {
  static List<SubtitleItem> placeSlice({
    required List<SubtitleItem> relative,
    required Duration sliceStart,
    required Duration overlap,
    required Duration sliceLength,
  }) {
    final dropBefore = overlap * 0.8;
    final maxEnd = sliceStart + sliceLength + const Duration(milliseconds: 250);
    final placed = <SubtitleItem>[];
    for (final item in relative) {
      final text = item.text.trim();
      if (text.isEmpty) continue;
      final localMid = Duration(
        microseconds:
            (item.startTime.inMicroseconds + item.endTime.inMicroseconds) ~/ 2,
      );
      if (overlap > Duration.zero && localMid < dropBefore) continue;
      var start = sliceStart + item.startTime;
      var end = sliceStart + item.endTime;
      if (start < Duration.zero) start = Duration.zero;
      if (start >= maxEnd) continue;
      if (end > maxEnd) end = maxEnd;
      if (end <= start) continue;
      placed.add(
        item.trimmed().copyWith(
          index: 0,
          startTime: start,
          endTime: end,
          timedSpans: item.trimmed().shiftedSpans(sliceStart, start, end),
        ),
      );
    }
    return placed;
  }

  static List<SubtitleItem> finish(List<SubtitleItem> absolute) {
    final sorted = [...absolute]
      ..sort((a, b) {
        final byStart = a.startTime.compareTo(b.startTime);
        if (byStart != 0) return byStart;
        return b.endTime.compareTo(a.endTime);
      });
    final kept = <SubtitleItem>[];
    for (final item in sorted) {
      final text = item.text.trim();
      if (text.isEmpty || item.endTime <= item.startTime) continue;
      if (kept.isEmpty) {
        kept.add(item);
        continue;
      }
      final previous = kept.last;
      final differentSpeakers =
          previous.asrInfo.speaker.isNotEmpty &&
          item.asrInfo.speaker.isNotEmpty &&
          previous.asrInfo.speaker != item.asrInfo.speaker;
      if (!differentSpeakers &&
          _overlaps(previous, item) &&
          _nearDuplicate(previous.text, item.text)) {
        if (text.length > previous.text.trim().length) {
          kept[kept.length - 1] = item;
        }
        continue;
      }
      final gap = item.startTime - previous.endTime;
      if (!differentSpeakers &&
          _sameText(previous.text, text) &&
          gap < const Duration(milliseconds: 400) &&
          gap > const Duration(milliseconds: -200)) {
        final end = item.endTime > previous.endTime
            ? item.endTime
            : previous.endTime;
        kept[kept.length - 1] = previous.copyWith(
          index: 0,
          endTime: end,
          timedSpans: previous.timedSpans.isNotEmpty
              ? previous.timedSpans
              : item.timedSpans,
        );
        continue;
      }
      kept.add(item);
    }
    return [
      for (var i = 0; i < kept.length; i++)
        kept[i].trimmed().copyWith(index: i + 1),
    ];
  }

  static bool _overlaps(SubtitleItem a, SubtitleItem b) {
    final start = a.startTime > b.startTime ? a.startTime : b.startTime;
    final end = a.endTime < b.endTime ? a.endTime : b.endTime;
    return end > start;
  }

  static bool _sameText(String a, String b) => _norm(a) == _norm(b);

  static bool _nearDuplicate(String a, String b) {
    final left = _norm(a);
    final right = _norm(b);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final shorter = left.length <= right.length ? left : right;
    final longer = left.length <= right.length ? right : left;
    if (shorter.length >= 2 && longer.contains(shorter)) return true;
    var shared = 0;
    final limit = shorter.length < longer.length
        ? shorter.length
        : longer.length;
    while (shared < limit && shorter[shared] == longer[shared]) {
      shared++;
    }
    return shared >= 4 && shared >= shorter.length * 0.6;
  }

  static String _norm(String text) {
    return text
        .replaceAll(RegExp(r'''[\s，。！？、,.!?;；:："“”'‘’（）()\[\]【】\-—…]'''), '')
        .toLowerCase();
  }
}

class TranscriptionRetryAdvice {
  final bool shouldRetry;
  final Duration delay;
  final int failureCount;
  final int maxRetries;
  final GongyiAsrFailureKind kind;

  const TranscriptionRetryAdvice._({
    required this.shouldRetry,
    required this.delay,
    required this.failureCount,
    required this.maxRetries,
    required this.kind,
  });

  String waitingMessage(String? sliceLabel) {
    final where = sliceLabel == null || sliceLabel.isEmpty
        ? ''
        : '$sliceLabel · ';
    final reason = switch (kind) {
      GongyiAsrFailureKind.uploadSignature => '音频上传授权校验失败',
      GongyiAsrFailureKind.riskControl => '触发了访问限制',
      GongyiAsrFailureKind.requestRejected => '服务端拒绝了请求，原因尚未确认',
      GongyiAsrFailureKind.networkUnavailable => '网络中断了',
      GongyiAsrFailureKind.transient => '字幕服务暂时没有响应',
      GongyiAsrFailureKind.tooLong => '这段超过了长度限制',
      GongyiAsrFailureKind.rejected => '字幕服务拒绝了这段音频',
    };
    return '$where$reason，即将进行第 $failureCount 次自动重试';
  }
}

class TranscriptionRetryPolicy {
  static const List<Duration> networkDelays = [
    Duration(seconds: 2),
    Duration(seconds: 6),
    Duration(seconds: 15),
  ];
  static const List<Duration> transientDelays = [
    Duration(seconds: 4),
    Duration(seconds: 12),
    Duration(seconds: 30),
  ];
  static const List<Duration> riskDelays = [
    Duration(seconds: 15),
    Duration(seconds: 45),
    Duration(seconds: 90),
  ];

  static const String batchPausedMessage =
      '服务端持续拒绝请求，已暂停后面的任务。请查看当前任务的错误详情，已完成的片段会接着用';

  static const Duration batchCooldown = Duration(seconds: 30);

  /// [failureCount] 从 1 开始，表示这一次操作已经失败了几次。
  /// 永久拒绝和“音频过长”不在这里空等：过长交给分段，拒绝直接告诉用户。
  static TranscriptionRetryAdvice advise({
    required GongyiAsrFailureKind kind,
    required int failureCount,
  }) {
    final delays = switch (kind) {
      GongyiAsrFailureKind.networkUnavailable => networkDelays,
      GongyiAsrFailureKind.transient => transientDelays,
      GongyiAsrFailureKind.riskControl => riskDelays,
      _ => const <Duration>[],
    };
    if (failureCount < 1 || failureCount > delays.length) {
      return TranscriptionRetryAdvice._(
        shouldRetry: false,
        delay: Duration.zero,
        failureCount: failureCount,
        maxRetries: delays.length,
        kind: kind,
      );
    }
    return TranscriptionRetryAdvice._(
      shouldRetry: true,
      delay: delays[failureCount - 1],
      failureCount: failureCount,
      maxRetries: delays.length,
      kind: kind,
    );
  }
}

class TranscriptionAttemptRunner {
  static Future<List<SubtitleItem>> run({
    required Future<List<SubtitleItem>> Function() attempt,
    required Future<void> Function(Duration delay) delay,
    required void Function(String message) onWaiting,
    String? sliceLabel,
    void Function(String message)? log,
  }) async {
    var failures = 0;
    while (true) {
      try {
        return await attempt();
      } on GongyiAsrException catch (error) {
        // Result polling owns its retry budget. Do not start another polling
        // cycle after that budget is exhausted; its task ID remains resumable.
        if (error.queryRetryExhausted || error.recoveryExhausted) rethrow;
        failures++;
        final advice = TranscriptionRetryPolicy.advise(
          kind: error.kind,
          failureCount: failures,
        );
        log?.call(
          '[transcription] asr failure kind=${error.kind} count=$failures retry=${advice.shouldRetry} message=${error.message}',
        );
        if (!advice.shouldRetry) rethrow;
        final message = advice.waitingMessage(sliceLabel);
        onWaiting(message);
        await delay(advice.delay);
      }
    }
  }
}

class TranscriptionUserMessage {
  static bool isVague(String message) {
    final text = message.trim();
    if (text.isEmpty) return true;
    const markers = ['没有说明原因', '转录任务失败', '服务端拒绝了这段音频', '字幕服务拒绝了这段音频', '未知错误'];
    if (!markers.any(text.contains)) return false;
    const concrete = ['音轨', '为空', '无声', '不存在', '参数', '格式', '权限'];
    return !concrete.any(text.contains);
  }

  static String describe(Object error) {
    if (error is GongyiAsrException) {
      if (error.queryRetryExhausted || error.recoveryExhausted) {
        return error.message;
      }
      switch (error.kind) {
        case GongyiAsrFailureKind.uploadSignature:
          return error.message;
        case GongyiAsrFailureKind.riskControl:
          return '${error.message}。稍后再点重试，已完成的片段会接着用';
        case GongyiAsrFailureKind.requestRejected:
          return '${error.message}。拒绝原因尚未确认，请检查网络设置后重试';
        case GongyiAsrFailureKind.networkUnavailable:
          return '网络连不上字幕服务，已自动重试多次。检查网络后再点重试';
        case GongyiAsrFailureKind.transient:
          return '字幕服务暂时不稳定，已自动重试多次。稍后再点重试';
        case GongyiAsrFailureKind.tooLong:
          return '分成很短的片段后仍被服务端拒绝。可以稍后再点重试';
        case GongyiAsrFailureKind.rejected:
          if (isVague(error.message)) {
            return '服务端拒绝了这段音频，没有说明原因。可以稍后点重试';
          }
          return _clean(error.message);
      }
    }
    final raw = _clean(error.toString());
    if (raw.contains('无音轨')) return '这个文件没有音轨，无法生成字幕';
    if (raw.contains('为空') || raw.contains('无声') || raw.contains('静音')) {
      return raw;
    }
    if (raw.isEmpty) return '字幕生成失败，可以稍后点重试';
    if (raw.length > 160) return '字幕生成失败：${raw.substring(0, 160)}';
    return raw;
  }

  static String _clean(String raw) {
    var text = raw.trim();
    final prefix = RegExp(r'^(Exception|Bad state|StateError):\s*');
    while (prefix.hasMatch(text)) {
      text = text.replaceFirst(prefix, '');
    }
    text = text.replaceFirst(RegExp(r'^转录失败[:：]\s*'), '');
    return text.trim();
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}
