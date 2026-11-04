import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';

Never _retiredCloudBrowser() =>
    throw UnsupportedError('本地版已移除网盘登录、Cookie 获取与网页播放');

/// Compatibility contract for old callers; it never creates a browser or reads credentials.
abstract class CloudDriveLoginClient {
  Future<void> prepare();
  Future<List<CloudDriveCookie>> readCookies({Object? webView});
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies);
  Future<void> reload();
  Future<void> dispose();
  Object? get environment;
}

class CloudDriveLoginBrowser implements CloudDriveLoginClient {
  CloudDriveLoginBrowser(this.provider);
  final CloudDriveProvider provider;
  @override
  Object? get environment => null;
  @override
  Future<void> prepare() async => _retiredCloudBrowser();
  @override
  Future<List<CloudDriveCookie>> readCookies({Object? webView}) async =>
      _retiredCloudBrowser();
  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) =>
      _retiredCloudBrowser();
  @override
  Future<void> reload() async => _retiredCloudBrowser();
  @override
  Future<void> dispose() async {}
}

Future<List<CloudDriveCookie>> readCloudDrivePageCookies({
  required List<String> cookieUrls,
  required Future<dynamic> Function(
    String method,
    Map<String, dynamic> parameters,
  )
  callDevTools,
}) async => _retiredCloudBrowser();

List<CloudDriveCookie> cookiesFromDevToolsPayload(Object? data) =>
    _retiredCloudBrowser();
String cloudDriveLoginFailureMessage() => '本地版已移除网盘与网页登录';
const cloudDriveLoginDesktopUserAgent = '';
