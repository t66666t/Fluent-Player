/// A temporary decoder join must release its buffer/seek policy on every exit.
/// Callers can supply newer policy values when a user seeks during the join.
class TemporaryPlaybackProperties {
  TemporaryPlaybackProperties({
    required this.read,
    required this.write,
    required this.isCurrent,
    required this.latestPolicy,
  });

  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final bool Function() isCurrent;
  final Map<String, String> Function() latestPolicy;

  Future<T> run<T>(
    Map<String, String> overrides,
    Future<T> Function() work,
  ) async {
    final saved = <String, String>{};
    try {
      for (final key in overrides.keys) {
        saved[key] = await read(key);
        if (!isCurrent()) throw StateError('Playback operation superseded');
      }
      for (final entry in overrides.entries) {
        if (!isCurrent()) throw StateError('Playback operation superseded');
        await write(entry.key, entry.value);
      }
      if (!isCurrent()) throw StateError('Playback operation superseded');
      return await work();
    } finally {
      final restore = {...saved, ...latestPolicy()};
      Object? failure;
      StackTrace? trace;
      for (final entry in restore.entries) {
        if (!isCurrent()) break;
        try {
          await write(entry.key, entry.value);
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
    }
  }
}
