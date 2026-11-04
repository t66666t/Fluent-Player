import '../models/cloud_drive_models.dart';
import 'cloud_drive_provider.dart';
import 'quark_cloud_drive_provider.dart';

/// UC's desktop file API uses the same file/download contract as Quark.
/// Its verified web video API provides full HLS without probing the large,
/// throttled MP4 tail needed for original-file startup.
class UcCloudDriveProvider extends QuarkCloudDriveProvider {
  UcCloudDriveProvider({super.http});

  static const String providerId = 'uc';
  @override
  String get id => providerId;
  @override
  String get displayName => 'UC网盘';
  @override
  Uri get loginUri => Uri.https('drive.uc.cn', '/');
  @override
  String get apiBase => 'https://pc-api.uc.cn/1/clouddrive';
  @override
  String get clientProduct => 'UCBrowser';
  @override
  String get cookieRoot => 'uc.cn';
  @override
  String get requestUserAgent => QuarkCloudDriveProvider.webUserAgent
      .replaceFirst('quark-cloud-drive', 'uc-cloud-drive');
  @override
  bool get preferTranscodedPlayback => true;
  @override
  bool get supportsOfficialSubtitleApi => false;
  @override
  CloudDriveCapabilities get capabilities => const CloudDriveCapabilities(
    serverDateSort: true,
    transcodedStream: true,
  );

  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) async {
    // A successful authenticated root listing is mandatory. Some UC versions
    // do not expose /account/info; __uid then supplies the stable account id.
    try {
      return await super.verifySession(credential, cancelToken: cancelToken);
    } on CloudDriveFailure catch (error) {
      if (error.kind == CloudDriveFailureKind.rateLimited) rethrow;
    }
    final cookie = credential.cookies
        .where(
          (c) =>
              c.name == '__uid' &&
              c.matches(loginUri) &&
              c.value.isNotEmpty &&
              !{'0', 'null', 'undefined'}.contains(c.value),
        )
        .firstOrNull;
    if (cookie == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '请在 UC 官方页面完成登录',
      );
    }
    await listChildren(
      CloudDriveListRequest(
        credential: credential,
        accountLocalId: '',
        remoteAccountId: cookie.value,
        driveId: '0',
        parentFileId: rootFileId,
      ),
      cancelToken: cancelToken,
    );
    return CloudDriveVerifiedSession(
      remoteAccountId: cookie.value,
      displayName: displayName,
      refreshedCredential: refreshedCredentialFor(credential),
    );
  }
}
