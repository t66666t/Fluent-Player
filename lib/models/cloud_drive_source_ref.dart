import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Logical identity of one cloud file.
///
/// The hash is the cross-device media identity. It deliberately excludes the
/// local account UUID, cookies, signed URLs and folder names, so logging in
/// again on another install still matches the same file.
class CloudDriveSourceRef {
  static const int currentVersion = 1;
  static const String uriScheme = 'cloud-drive';

  final int version;
  final String providerId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String? pathHint;
  final String? revision;
  final String? preferredQuality;

  const CloudDriveSourceRef({
    this.version = currentVersion,
    required this.providerId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    this.pathHint,
    this.revision,
    this.preferredQuality,
  });

  /// Stable key shared by every login of the same remote account and file.
  String get sourceKey => cloudDriveSourceKey(
    providerId: providerId,
    remoteAccountId: remoteAccountId,
    driveId: driveId,
    fileId: fileId,
  );

  /// Library card id derived only from [sourceKey].
  String get itemId => cloudDriveItemId(sourceKey);

  /// A cache transfer pins a real representation without changing media identity.
  CloudDriveSourceRef copyWithForCache({required String revision, required String quality}) =>
      CloudDriveSourceRef(version: version, providerId: providerId,
        remoteAccountId: remoteAccountId, driveId: driveId, fileId: fileId,
        pathHint: pathHint, revision: revision, preferredQuality: quality);

  /// Marker stored in [VideoItem.path]. Never a CDN URL and never a file path.
  String get logicalUri => cloudDriveLogicalUri(
    providerId: providerId,
    remoteAccountId: remoteAccountId,
    driveId: driveId,
    fileId: fileId,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'providerId': providerId,
    'remoteAccountId': remoteAccountId,
    'driveId': driveId,
    'fileId': fileId,
    'pathHint': pathHint,
    'revision': revision,
    'preferredQuality': preferredQuality,
  };

  factory CloudDriveSourceRef.fromJson(Map<String, dynamic> json) {
    final providerId = _required(json['providerId']);
    final remoteAccountId = _required(json['remoteAccountId']);
    final driveId = _required(json['driveId']);
    final fileId = _required(json['fileId']);
    return CloudDriveSourceRef(
      version: json['version'] is int ? json['version'] as int : currentVersion,
      providerId: providerId,
      remoteAccountId: remoteAccountId,
      driveId: driveId,
      fileId: fileId,
      pathHint: _optional(json['pathHint']),
      revision: _optional(json['revision']),
      preferredQuality: _optional(json['preferredQuality']),
    );
  }

  static CloudDriveSourceRef? fromJsonOrNull(Object? json) {
    if (json is! Map) return null;
    try {
      return CloudDriveSourceRef.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
      return null;
    }
  }
}

String cloudDriveSourceKey({
  required String providerId,
  required String remoteAccountId,
  required String driveId,
  required String fileId,
}) {
  // Length-prefix each field so "|" inside an id cannot shift the boundary.
  final canonical = [
    'v1',
    _prefixed(providerId),
    _prefixed(remoteAccountId),
    _prefixed(driveId),
    _prefixed(fileId),
  ].join('\n');
  return sha256.convert(utf8.encode(canonical)).toString();
}

String cloudDriveItemId(String sourceKey) {
  final hex = sourceKey.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final body = hex.length >= 32 ? hex.substring(0, 32) : hex.padRight(32, '0');
  return 'cd_$body';
}

String cloudDriveLogicalUri({
  required String providerId,
  required String remoteAccountId,
  required String driveId,
  required String fileId,
}) {
  return '${CloudDriveSourceRef.uriScheme}://v1/'
      '${Uri.encodeComponent(providerId)}/'
      '${Uri.encodeComponent(remoteAccountId)}/'
      '${Uri.encodeComponent(driveId)}/'
      '${Uri.encodeComponent(fileId)}';
}

bool isCloudDriveLogicalPath(String path) =>
    path.startsWith('${CloudDriveSourceRef.uriScheme}://');

String _prefixed(String value) => '${utf8.encode(value).length}:$value';

String _required(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) {
    throw const FormatException('网盘来源缺少身份字段');
  }
  return text;
}

String? _optional(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
