import 'package:flutter/foundation.dart';

/// Immutable display state, independent of queue ownership and task objects.
@immutable
class MediaCacheCardState {
  const MediaCacheCardState({
    this.ready = false,
    this.hasCache = false,
    this.active = false,
    this.progress,
  });
  final bool ready;
  final bool hasCache;
  final bool active;
  final double? progress;

  @override
  bool operator ==(Object other) =>
      other is MediaCacheCardState &&
      ready == other.ready &&
      hasCache == other.hasCache &&
      active == other.active &&
      progress == other.progress;
  @override
  int get hashCode => Object.hash(ready, hasCache, active, progress);
}
