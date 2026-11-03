import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/subtitle_stream.dart';

/// Playback consumes subtitle updates independently of the model producing them.
abstract interface class SubtitleStreamSource {
  Stream<SubtitleStreamUpdate> get subtitleUpdates;
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts;
  ValueListenable<int> get subtitleFilesRevision;
  Iterable<SubtitleStreamUpdate> get subtitleStreams;
  bool Function(String)? get shouldSelectGeneratedSubtitles;
  set shouldSelectGeneratedSubtitles(bool Function(String)? value);
  void preserveSubtitleSelection(String path, {String? videoId});
  bool subtitleSelectionOverridden(String mediaKey);
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId});
  bool hasSubtitleStreamForVideo(String path, {String? videoId});
  SubtitleStreamUpdate? streamForPath(String path);
  Future<void> stopStreamForPath(String path);
  void resumeStreamForPath(String path);
  void forgetStreamForPath(String path);
}

/// A small fan-in adapter. ASR and OCR keep their own tasks and checkpoints;
/// both use the existing playback/list append path and manual-selection rules.
class SubtitleStreamHub implements SubtitleStreamSource {
  SubtitleStreamHub(Iterable<SubtitleStreamSource> sources)
    : sources = List.unmodifiable(sources) {
    for (final source in this.sources) {
      _subscriptions.add(
        source.subtitleUpdates.listen((update) {
          if (_disposed) return;
          _order[update.generationId] = ++_sequence;
          if (_order.length > 128) _order.remove(_order.keys.first);
          _updates.add(update);
        }),
      );
      _subscriptions.add(
        source.subtitleGenerationStarts.listen((start) {
          if (!_disposed) _starts.add(start);
        }),
      );
      source.subtitleFilesRevision.addListener(_filesChanged);
    }
  }
  final List<SubtitleStreamSource> sources;
  final _updates = StreamController<SubtitleStreamUpdate>.broadcast(sync: true);
  final _starts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _order = <String, int>{};
  int _sequence = 0;
  bool _disposed = false;
  void _filesChanged() {
    if (!_disposed) subtitleFilesRevision.value++;
  }

  bool Function(String)? _selection;
  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier<int>(0);
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => _updates.stream;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts =>
      _starts.stream;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams =>
      sources.expand((source) => source.subtitleStreams);
  @override
  bool Function(String)? get shouldSelectGeneratedSubtitles => _selection;
  @override
  set shouldSelectGeneratedSubtitles(bool Function(String)? value) {
    _selection = value;
    for (final source in sources) {
      source.shouldSelectGeneratedSubtitles = value;
    }
  }

  @override
  void preserveSubtitleSelection(String path, {String? videoId}) {
    for (final source in sources) {
      source.preserveSubtitleSelection(path, videoId: videoId);
    }
  }

  @override
  bool subtitleSelectionOverridden(String key) =>
      sources.any((source) => source.subtitleSelectionOverridden(key));
  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) {
    final matches =
        subtitleStreams
            .where(
              (stream) =>
                  stream.videoPath == path ||
                  videoId != null && stream.videoId == videoId,
            )
            .toList()
          ..sort((a, b) {
            if (a.complete != b.complete) return a.complete ? 1 : -1;
            return (_order[b.generationId] ?? 0).compareTo(
              _order[a.generationId] ?? 0,
            );
          });
    return matches.firstOrNull;
  }

  @override
  bool hasSubtitleStreamForVideo(String path, {String? videoId}) => sources.any(
    (source) => source.hasSubtitleStreamForVideo(path, videoId: videoId),
  );
  SubtitleStreamSource? _owner(String path) =>
      sources.where((source) => source.streamForPath(path) != null).firstOrNull;
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      _owner(path)?.streamForPath(path);
  @override
  Future<void> stopStreamForPath(String path) async =>
      await _owner(path)?.stopStreamForPath(path);
  @override
  void resumeStreamForPath(String path) =>
      _owner(path)?.resumeStreamForPath(path);
  @override
  void forgetStreamForPath(String path) {
    _owner(path)?.forgetStreamForPath(path);
    subtitleFilesRevision.value++;
  }

  void dispose() {
    _disposed = true;
    for (final source in sources) {
      source.subtitleFilesRevision.removeListener(_filesChanged);
      if (identical(source.shouldSelectGeneratedSubtitles, _selection)) {
        source.shouldSelectGeneratedSubtitles = null;
      }
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_updates.close());
    unawaited(_starts.close());
    subtitleFilesRevision.dispose();
  }
}
