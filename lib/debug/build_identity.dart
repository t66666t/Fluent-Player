import 'dart:io';

/// Short, non-sensitive identifier of the build that is actually running.
///
/// A media log line without this cannot be matched to a Dart artifact, which is
/// exactly how an old `kernel_blob.bin` gets mistaken for the current source.
class BuildIdentity {
  const BuildIdentity._();

  static const String _declared = String.fromEnvironment(
    'VIDEO_PLAYER_BUILD_ID',
    defaultValue: '',
  );

  static const String _revision = String.fromEnvironment(
    'VIDEO_PLAYER_SOURCE_REVISION',
    defaultValue: 'dev',
  );

  static String? _id;

  /// Stable for one executable artifact, changes when it is rebuilt.
  static String get id => _id ??= _resolve();

  /// Best-effort source revision; `dev` when the build did not declare one.
  static String get sourceRevision => _revision;

  static String get label => 'build=$id rev=$sourceRevision';

  static String _resolve() {
    if (_declared.isNotEmpty) return _declared;
    try {
      final executable = File(Platform.resolvedExecutable);
      final stamp = executable.existsSync()
          ? executable.lastModifiedSync().millisecondsSinceEpoch
          : 0;
      return _hash('${Platform.resolvedExecutable}|$stamp');
    } catch (_) {
      return 'unknown';
    }
  }

  static String _hash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
