/// The visible library surface, independent of the current playback session.
enum ExternalAiWorkspaceView {
  unknown,
  libraryRoot,
  libraryFolder,
  search,
  recent,
  continueLearning,
  bilibili,
  podcasts,
  cloudDrive,
}

class ExternalAiWorkspaceSnapshot {
  const ExternalAiWorkspaceSnapshot({
    this.folderId,
    this.viewType = ExternalAiWorkspaceView.unknown,
    this.updatedAt,
  });

  final String? folderId;
  final ExternalAiWorkspaceView viewType;
  final DateTime? updatedAt;

  /// A null folder ID only means the root when this is explicitly true.
  bool get isLibraryRoot => viewType == ExternalAiWorkspaceView.libraryRoot;

  bool get hasCurrentFolder =>
      isLibraryRoot ||
      (viewType == ExternalAiWorkspaceView.libraryFolder && folderId != null);
}

/// Ephemeral UI context: never stores paths, credentials, or playback state.
///
/// Pages publish only while actually current. Owner identity prevents an old
/// route's delayed disposal from clearing the newly visible route's context.
class ExternalAiWorkspaceContext {
  ExternalAiWorkspaceContext({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static final instance = ExternalAiWorkspaceContext();

  final DateTime Function() _now;
  Object? _owner;
  ExternalAiWorkspaceSnapshot _snapshot = const ExternalAiWorkspaceSnapshot();

  ExternalAiWorkspaceSnapshot get snapshot => _snapshot;

  void publish({
    required Object owner,
    required ExternalAiWorkspaceView viewType,
    String? folderId,
  }) {
    final validFolder = folderId != null && folderId.isNotEmpty;
    final view =
        viewType == ExternalAiWorkspaceView.libraryFolder && !validFolder
        ? ExternalAiWorkspaceView.unknown
        : viewType;
    final id = view == ExternalAiWorkspaceView.libraryFolder ? folderId : null;
    if (identical(_owner, owner) &&
        _snapshot.viewType == view &&
        _snapshot.folderId == id) {
      return;
    }
    _owner = owner;
    _snapshot = ExternalAiWorkspaceSnapshot(
      folderId: id,
      viewType: view,
      updatedAt: _now().toUtc(),
    );
  }

  void clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _snapshot = ExternalAiWorkspaceSnapshot(updatedAt: _now().toUtc());
  }
}
