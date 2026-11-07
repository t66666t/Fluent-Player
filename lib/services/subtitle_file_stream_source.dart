import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import 'streaming_subtitle_store.dart';
import 'subtitle_stream_source.dart';

/// Existing-file processing uses the same append and manual-selection rules
/// as ASR/OCR. The processing journal remains the only checkpoint authority.
class SubtitleFileStreamSource implements SubtitleStreamSource {
  final _updates = StreamController<SubtitleStreamUpdate>.broadcast(sync: true);
  final _starts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  final _states = <String, SubtitleStreamUpdate>{};
  final _suppressed = <String>{};
  final _resume = <String, Future<void> Function()>{};
  String? _active;
  Future<void> Function()? _stop;

  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier(0);
  @override
  bool Function(String)? shouldSelectGeneratedSubtitles;
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => _updates.stream;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts =>
      _starts.stream;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => _states.values;

  void begin(
    StreamingSubtitleStore store, {
    required String videoPath,
    required Future<void> Function() stop,
    required Future<void> Function() resume,
  }) {
    final id = store.header['generationId'] as String;
    _active = id;
    _stop = stop;
    _resume[id] = resume;
    _starts.add((mediaKey: 'subtitle-file:$id', runId: id));
    publish(store, videoPath: videoPath);
  }

  void publish(
    StreamingSubtitleStore store, {
    required String videoPath,
    List<SubtitleItem> primary = const [],
    List<SubtitleItem> secondary = const [],
  }) {
    final id = store.header['generationId'] as String;
    final update = SubtitleStreamUpdate(
      generationId: id,
      mediaKey: 'subtitle-file:$id',
      videoPath: videoPath,
      videoId: null,
      revision: store.revision,
      primaryPath: store.primaryPath,
      secondaryPath: store.secondaryPath,
      primary: store.primary.snapshot,
      secondary: store.secondary.snapshot,
      addedPrimary: primary,
      addedSecondary: secondary,
      primaryBytes: store.primaryBytes,
      secondaryBytes: store.secondaryBytes,
      processedThrough: store.through,
      phase: store.phase,
      message: store.message,
      autoSelectSuppressed: _suppressed.contains('subtitle-file:$id'),
    );
    _states[id] = update;
    _updates.add(update);
    subtitleFilesRevision.value++;
    if (store.phase != SubtitleStreamPhase.generating && _active == id) {
      _active = null;
      _stop = null;
    }
    if (update.complete) {
      _states[id] = update.compact();
      _resume.remove(id);
    }
    while (_states.length > 32) {
      final oldest = _states.values.where((s) => s.complete).firstOrNull;
      if (oldest == null) break;
      forgetStreamForPath(oldest.primaryPath);
    }
  }

  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      _states.values.where((s) => p.equals(s.videoPath, path)).lastOrNull;
  @override
  bool hasSubtitleStreamForVideo(String path, {String? videoId}) =>
      streamForVideo(path, videoId: videoId) != null;
  @override
  SubtitleStreamUpdate? streamForPath(String path) => _states.values
      .where((s) => s.paths.any((value) => p.equals(value, path)))
      .firstOrNull;
  @override
  bool subtitleSelectionOverridden(String mediaKey) =>
      _suppressed.contains(mediaKey);
  @override
  void preserveSubtitleSelection(String path, {String? videoId}) {
    for (final state in _states.values) {
      if (!state.complete && p.equals(state.videoPath, path)) {
        _suppressed.add(state.mediaKey);
      }
    }
  }

  @override
  Future<void> stopStreamForPath(String path) async {
    if (streamForPath(path)?.generationId == _active) await _stop?.call();
  }

  @override
  void resumeStreamForPath(String path) {
    final state = streamForPath(path);
    if (state == null || state.complete || _active != null) return;
    final resume = _resume[state.generationId];
    if (resume != null) {
      unawaited(
        resume().catchError((Object error) {
          debugPrint('字幕处理恢复失败：$error');
        }),
      );
    }
  }

  @override
  void forgetStreamForPath(String path) {
    final state = streamForPath(path);
    if (state == null || state.generationId == _active) return;
    _states.remove(state.generationId);
    _resume.remove(state.generationId);
    _suppressed.remove(state.mediaKey);
    subtitleFilesRevision.value++;
  }

  void dispose() {
    unawaited(_updates.close());
    unawaited(_starts.close());
    subtitleFilesRevision.dispose();
  }
}
