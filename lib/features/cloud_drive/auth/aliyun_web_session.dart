import 'dart:convert';

import '../models/cloud_drive_models.dart';

/// Read only the signed-in official page's token, never unrelated web storage.
const aliyunSessionCaptureScript = r'''(() => {
  const hosts = ['alipan.com', 'www.alipan.com',
    'aliyundrive.com', 'www.aliyundrive.com'];
  if (location.protocol !== 'https:' || !hosts.includes(location.hostname)) {
    return null;
  }
  return JSON.stringify({origin: location.origin,
    token: localStorage.getItem('token') || sessionStorage.getItem('token')});
})()''';

Map<String, String>? aliyunSecretsFromBrowser(Object? payload) {
  Object? decode(Object? value) {
    for (var i = 0; i < 3 && value is String; i++) {
      if (value.length > 128 * 1024) return null;
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  final envelope = decode(payload);
  if (envelope is! Map) return null;
  final origin = Uri.tryParse('${envelope['origin'] ?? ''}');
  if (origin == null ||
      origin.scheme != 'https' ||
      origin.hasPort && origin.port != 443 ||
      !const {
        'alipan.com',
        'www.alipan.com',
        'aliyundrive.com',
        'www.aliyundrive.com',
      }.contains(origin.host)) {
    return null;
  }
  final token = decode(envelope['token']);
  if (token is! Map) return null;
  final result = <String, String>{};
  for (final key in const [
    'access_token',
    'refresh_token',
    'user_id',
    'default_drive_id',
    'resource_drive_id',
    'backup_drive_id',
    'expire_time',
  ]) {
    final value = token[key];
    if (value is String &&
        value.isNotEmpty &&
        value.length <= 16384 &&
        !RegExp(r'[\r\n]').hasMatch(value)) {
      result[key] = value;
    }
  }
  if (result['refresh_token'] == null) return null;
  return Map.unmodifiable(result);
}

CloudDriveCredential? aliyunCredentialFromBrowser(
  Object? payload, {
  List<CloudDriveCookie> cookies = const [],
}) {
  final secrets = aliyunSecretsFromBrowser(payload);
  return secrets == null
      ? null
      : CloudDriveCredential(
          cookies: cookies,
          secrets: secrets,
          capturedAt: DateTime.now().toUtc(),
        );
}
