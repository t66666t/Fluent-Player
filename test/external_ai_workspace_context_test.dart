import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_workspace_context.dart';

void main() {
  test('unknown and other surfaces never imply the library root', () {
    final workspace = ExternalAiWorkspaceContext();
    final owner = Object();
    expect(workspace.snapshot.hasCurrentFolder, isFalse);
    for (final view in ExternalAiWorkspaceView.values) {
      if (view == ExternalAiWorkspaceView.libraryRoot ||
          view == ExternalAiWorkspaceView.libraryFolder) {
        continue;
      }
      workspace.publish(owner: owner, viewType: view, folderId: 'stale-folder');
      expect(workspace.snapshot.hasCurrentFolder, isFalse);
      expect(workspace.snapshot.isLibraryRoot, isFalse);
      expect(workspace.snapshot.folderId, isNull);
    }
    workspace.publish(
      owner: owner,
      viewType: ExternalAiWorkspaceView.libraryRoot,
    );
    expect(workspace.snapshot.isLibraryRoot, isTrue);
    expect(workspace.snapshot.hasCurrentFolder, isTrue);
    expect(workspace.snapshot.folderId, isNull);
  });

  test('folder identity requires a nonempty explicit folder ID', () {
    final workspace = ExternalAiWorkspaceContext();
    final owner = Object();
    for (final id in <String?>[null, '']) {
      workspace.publish(
        owner: owner,
        viewType: ExternalAiWorkspaceView.libraryFolder,
        folderId: id,
      );
      expect(workspace.snapshot.viewType, ExternalAiWorkspaceView.unknown);
      expect(workspace.snapshot.hasCurrentFolder, isFalse);
    }
    workspace.publish(
      owner: owner,
      viewType: ExternalAiWorkspaceView.libraryFolder,
      folderId: 'browsed-folder',
    );
    expect(workspace.snapshot.folderId, 'browsed-folder');
    expect(workspace.snapshot.hasCurrentFolder, isTrue);
    expect(workspace.snapshot.isLibraryRoot, isFalse);
  });

  test('old route disposal cannot erase a newer current route', () {
    var now = DateTime.utc(2026, 11, 5);
    final workspace = ExternalAiWorkspaceContext(now: () => now);
    final oldPage = Object();
    final newPage = Object();
    workspace.publish(
      owner: oldPage,
      viewType: ExternalAiWorkspaceView.libraryRoot,
    );
    now = now.add(const Duration(seconds: 1));
    workspace.publish(
      owner: newPage,
      viewType: ExternalAiWorkspaceView.libraryFolder,
      folderId: 'new-folder',
    );
    workspace.clear(oldPage);
    expect(workspace.snapshot.folderId, 'new-folder');
    expect(workspace.snapshot.updatedAt, now);
    workspace.clear(newPage);
    expect(workspace.snapshot.viewType, ExternalAiWorkspaceView.unknown);
    expect(workspace.snapshot.hasCurrentFolder, isFalse);
  });

  test('unchanged rebuilds preserve the navigation timestamp', () {
    var now = DateTime.utc(2026, 11, 5);
    final workspace = ExternalAiWorkspaceContext(now: () => now);
    final owner = Object();
    workspace.publish(
      owner: owner,
      viewType: ExternalAiWorkspaceView.libraryRoot,
    );
    final original = workspace.snapshot.updatedAt;
    now = now.add(const Duration(seconds: 1));
    workspace.publish(
      owner: owner,
      viewType: ExternalAiWorkspaceView.libraryRoot,
    );
    expect(workspace.snapshot.updatedAt, original);
  });
}
