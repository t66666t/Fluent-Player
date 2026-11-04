import 'dart:io';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import '../../models/subtitle_model.dart';
import '../../services/transcription_reliability.dart';
import 'cloud_asr_adapters.dart';
import 'cloud_asr_transport.dart';
import 'cloud_asr_types.dart';

class CloudAsrAudio {
  const CloudAsrAudio(this.path, {this.temporary = true}) : silent = false;
  const CloudAsrAudio.silence() : path = '', temporary = false, silent = true;
  final String path;
  final bool temporary, silent;
  Future<void> dispose() async {
    if (temporary) {
      try {
        await File(path).delete();
      } on FileSystemException {
        /* Already released. */
      }
    }
  }
}

typedef PrepareCloudAsrAudio =
    Future<CloudAsrAudio> Function(
      Duration start,
      Duration length,
      bool forceTranscode,
      void Function(double) progress,
    );

// The preceding slice owns the overlap. Cut only at real word boundaries;
// dropping a whole cue could also drop the new words following that overlap.
List<SubtitleItem> _ownedWords(List<SubtitleItem> cues, Duration overlap) {
  if (overlap == Duration.zero) return cues;
  final result = <SubtitleItem>[];
  for (final cue in cues) {
    final spans = cue.timedSpans
        .where(
          (span) =>
              (span.startTime.inMicroseconds + span.endTime.inMicroseconds) ~/
                  2 >=
              overlap.inMicroseconds,
        )
        .toList();
    if (spans.isEmpty) continue;
    final from = spans.first.textStart;
    result.add(
      cue
          .copyWith(
            text: cue.text.substring(from),
            startTime: spans.first.startTime,
            asrInfo: cue.asrInfo.copyWith(wordBoundaries: []),
            timedSpans: spans
                .map((s) => s.shifted(Duration.zero, textOffset: -from))
                .toList(),
          )
          .trimmed(),
    );
  }
  return result;
}

class _Slice {
  const _Slice(this.start, this.length, this.overlap);
  final Duration start, length, overlap;
  Duration get end => start + length;
  String get key => '${start.inMicroseconds}:${length.inMicroseconds}:cloud-v1';
  List<int> get json => [
    start.inMicroseconds,
    length.inMicroseconds,
    overlap.inMicroseconds,
  ];
  static _Slice fromJson(List<dynamic> value) => _Slice(
    Duration(microseconds: value[0] as int),
    Duration(microseconds: value[1] as int),
    Duration(microseconds: value[2] as int),
  );
}

class _Outcome<T> {
  _Outcome.value(this.value) : error = null, stack = null;
  _Outcome.error(this.error, this.stack) : value = null;
  final T? value;
  final Object? error;
  final StackTrace? stack;
  T unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }

  static Future<_Outcome<T>> capture<T>(Future<T> future) => future.then(
    _Outcome<T>.value,
    onError: (Object e, StackTrace s) => _Outcome<T>.error(e, s),
  );
}

/// Bounded cloud-only pipeline. Existing local/public task formats are untouched.
class CloudAsrPipeline {
  CloudAsrPipeline({
    required this.adapter,
    required this.prepare,
    required this.pieces,
    required this.remote,
    required this.save,
    required this.token,
    required this.progress,
  });
  final CloudAsrAdapter adapter;
  final PrepareCloudAsrAudio prepare;
  final Map<String, dynamic> pieces, remote;
  final SaveCloudAsrState save;
  final CancelToken token;
  final CloudAsrProgress progress;

  Map<String, dynamic> _state(_Slice slice) =>
      remote.putIfAbsent(slice.key, () => <String, dynamic>{})
          as Map<String, dynamic>;

  Future<CloudAsrAudio?> _prepare(_Slice slice, {bool force = false}) async {
    token.throwIfCancellationRequested();
    final state = _state(slice);
    if (pieces.containsKey(slice.key) ||
        state['children'] != null ||
        !adapter.needsAudio(state)) {
      return null;
    }
    final audio = await prepare(
      slice.start,
      slice.length,
      force || state['normalized'] == true,
      (value) => progress(
        'preparing',
        '正在准备 ${slice.start.inMinutes} 分钟处的音频 · ${(value * 100).round()}%',
        null,
      ),
    );
    if (token.isCancelled) {
      await audio.dispose();
      token.throwIfCancellationRequested();
    }
    return audio;
  }

  Future<List<SubtitleItem>> _recognize(
    _Slice slice,
    CloudAsrAudio? audio, {
    int depth = 0,
  }) async {
    token.throwIfCancellationRequested();
    final state = _state(slice);
    if (pieces[slice.key] case final List saved) {
      await audio?.dispose();
      if (state['cleaned'] != true) await adapter.cleanup(state, save, token);
      return saved.map((c) => SubtitleItem.fromTimingJson(c as Map)).toList();
    }
    Future<List<SubtitleItem>> children() async {
      final out = <SubtitleItem>[];
      for (final value in state['children'] as List) {
        final child = _Slice.fromJson(value as List);
        out.addAll(
          await _recognize(child, await _prepare(child), depth: depth + 1),
        );
      }
      await adapter.cleanup(state, save, token);
      return out;
    }

    if (state['children'] is List) {
      await audio?.dispose();
      return children();
    }
    if (audio?.silent == true) {
      pieces[slice.key] = <dynamic>[];
      await save();
      return [];
    }
    try {
      final bytes = audio == null ? 0 : await File(audio.path).length();
      final limit = math.min(
        20000000,
        adapter.connection.capabilities.maxBytes,
      );
      if (bytes > limit && state['normalized'] != true) {
        await audio?.dispose();
        state['normalized'] = true;
        audio = await _prepare(slice, force: true);
      }
      final result = await adapter.transcribe(
        filePath: audio?.path,
        duration: slice.length,
        state: state,
        save: save,
        token: token,
        progress: (phase, message, fraction) => progress(
          phase,
          '${slice.start.inMinutes} 分钟处 · $message${fraction == null ? '' : ' · ${(fraction * 100).round()}%'}',
          null,
        ),
      );
      if (result.cues.any(
        (c) =>
            c.startTime >= slice.length + const Duration(seconds: 2) ||
            c.endTime > slice.length + const Duration(seconds: 2),
      )) {
        throw const CloudAsrException('服务时间轴超出当前音频片段，原结果已保留；请核对模型协议');
      }
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: _ownedWords(result.cues, slice.overlap),
        sliceStart: slice.start,
        sliceLength: slice.length,
        overlap: Duration.zero,
      );
      pieces[slice.key] = placed.map((c) => c.toTimingJson()).toList();
      await save();
      await adapter.cleanup(state, save, token);
      return placed;
    } on CloudAsrException catch (error) {
      if (error.format &&
          state['normalized'] != true &&
          state['submitting'] != true &&
          state['taskId'] == null) {
        await audio?.dispose();
        audio = null;
        state['normalized'] = true;
        await save();
        return _recognize(
          slice,
          await _prepare(slice, force: true),
          depth: depth,
        );
      }
      if (!error.tooLarge ||
          state['submitting'] == true ||
          state['taskId'] != null ||
          depth >= 12 ||
          slice.length < const Duration(seconds: 2)) {
        rethrow;
      }
      final half = slice.length.inMicroseconds ~/ 2;
      final overlap = math.min(1000000, half ~/ 4);
      state['children'] = [
        _Slice(
          slice.start,
          Duration(microseconds: half + overlap),
          slice.overlap,
        ).json,
        _Slice(
          slice.start + Duration(microseconds: half),
          Duration(microseconds: slice.length.inMicroseconds - half),
          Duration(
            microseconds: math.max(
              overlap,
              slice.overlap.inMicroseconds - half,
            ),
          ),
        ).json,
      ];
      await save();
      await audio?.dispose();
      audio = null;
      return children();
    } finally {
      await audio?.dispose();
    }
  }

  Future<List<SubtitleItem>> run(
    Duration duration, {
    Future<void> Function(List<SubtitleItem>, Duration)? onStable,
  }) async {
    if (duration <= Duration.zero) throw StateError('音频时长无效');
    final chunk = Duration(
      seconds: math.min(600, adapter.connection.capabilities.maxSeconds),
    );
    if (chunk <= const Duration(seconds: 2)) throw StateError('当前模型的时长限制无效');
    final slices = <_Slice>[];
    for (var start = Duration.zero; start < duration;) {
      final length = Duration(
        microseconds: math.min(
          chunk.inMicroseconds,
          (duration - start).inMicroseconds,
        ),
      );
      slices.add(
        _Slice(
          start,
          length,
          start == Duration.zero ? Duration.zero : const Duration(seconds: 2),
        ),
      );
      if (start + length >= duration) break;
      start += length - const Duration(seconds: 2);
    }
    final active =
        <({_Slice slice, Future<_Outcome<List<SubtitleItem>>> task})>[];
    Future<_Outcome<CloudAsrAudio?>>? prepared;
    final output = <SubtitleItem>[];
    var completed = Duration.zero;
    Future<void> consume() async {
      final next = active.removeAt(0);
      final result = (await next.task).unwrap();
      final indexed = [
        for (var i = 0; i < result.length; i++)
          result[i].copyWith(index: output.length + i + 1),
      ];
      output.addAll(indexed);
      completed = next.slice.end;
      progress(
        'recognizing',
        '已保存 ${completed.inMinutes} / ${duration.inMinutes} 分钟字幕',
        completed.inMicroseconds / duration.inMicroseconds,
      );
      if (onStable != null) await onStable(indexed, completed);
    }

    try {
      prepared = _Outcome.capture(_prepare(slices.first));
      for (var i = 0; i < slices.length; i++) {
        if (active.length >= 2 ||
            active.isNotEmpty && adapter.transport.budget.segments.limit == 1) {
          await consume();
        }
        token.throwIfCancellationRequested();
        final audio = (await prepared!).unwrap();
        prepared = null;
        final slice = slices[i];
        active.add((
          slice: slice,
          task: _Outcome.capture(_recognize(slice, audio)),
        ));
        if (i + 1 < slices.length) {
          prepared = _Outcome.capture(_prepare(slices[i + 1]));
        }
      }
      while (active.isNotEmpty) {
        await consume();
      }
      return TranscriptionSubtitleMerger.finish(output);
    } finally {
      // Observe every worker; another successful slice still keeps its checkpoint.
      for (final worker in active) {
        await worker.task;
      }
      if (prepared != null) {
        final pending = await prepared;
        await pending.value?.dispose();
      }
    }
  }
}
