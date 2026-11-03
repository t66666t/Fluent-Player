import 'package:flutter/foundation.dart';

/// A request survives popping a library folder on the way to the root surface.
class CloudDriveNavigation {
  CloudDriveNavigation._();

  static final request = ValueNotifier<CloudDriveNavigationRequest?>(null);

  static void viewFolder(String? folderId) {
    request.value = CloudDriveNavigationRequest(
      folderId,
      showImportedFolder: true,
    );
  }

  static void open({String? targetFolderId}) {
    request.value = CloudDriveNavigationRequest(targetFolderId);
  }
}

class CloudDriveNavigationRequest {
  const CloudDriveNavigationRequest(
    this.targetFolderId, {
    this.showImportedFolder = false,
  });
  final bool showImportedFolder;
  final String? targetFolderId;
}
