import 'package:flutter/foundation.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// Requests only the kinds the importer accepts. Android grants audio and
/// visual-media access independently, so a denied kind must not hide the other.
Future<RequestType?> requestImportGalleryAccess({
  TargetPlatform? platform,
}) async {
  final requested = RequestType.video | RequestType.audio;
  PermissionRequestOption option(RequestType type) => PermissionRequestOption(
    androidPermission: AndroidPermission(type: type, mediaLocation: false),
  );
  final state = await PhotoManager.requestPermissionExtend(
    requestOption: option(requested),
  );
  bool allowed(PermissionState value) => value.isAuth || value.isLimited;
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return allowed(state) ? requested : null;
  }

  // A combined Android request may report denied or limited when only one
  // type is granted. Query each type without prompting again, then let the
  // picker query only the media it can actually read.
  final accessible = <RequestType>[];
  for (final type in [RequestType.video, RequestType.audio]) {
    final permission = await PhotoManager.getPermissionState(
      requestOption: option(type),
    );
    if (allowed(permission)) accessible.add(type);
  }
  return accessible.isEmpty ? null : RequestType.fromTypes(accessible);
}
