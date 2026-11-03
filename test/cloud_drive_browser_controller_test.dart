import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_browser_controller.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';

class _LateProvider extends CloudDriveProvider {
  _LateProvider(this.pages);
  final List<CloudDrivePage> pages;
  int calls = 0;
  int? lastToken;

  @override
  CloudDriveCapabilities get capabilities => const CloudDriveCapabilities();
  @override
  String get displayName => '测试';
  @override
  String get id => 'baidu';
  @override
  Uri get loginUri => Uri.parse('https://example.test');

  @override
  Future<CloudDriveEntry> getFile(CloudDriveFileRequest request, {Object? cancelToken}) {
    throw UnimplementedError();
  }

  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async => const [];

  @override
  List<CloudDriveQualityChoice> qualityPlaceholders(
    CloudDrivePlaybackRequest request,
  ) => const [];

  @override
  Future<List<CloudDriveSubtitleTrack>> discoverSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async => const [];

  @override
  Future<String> readSubtitleText(
    CloudDriveSubtitleReadRequest request, {
    Object? cancelToken,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  }) async {
    lastToken = cancelToken as int?;
    final page = pages[calls.clamp(0, pages.length - 1)];
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return page;
  }
}

CloudDriveEntry _file(String id) => CloudDriveEntry(
  providerId: 'baidu',
  accountLocalId: 'local',
  remoteAccountId: 'uk',
  driveId: '0',
  fileId: id,
  parentFileId: '/',
  name: id,
  kind: CloudDriveEntryKind.video,
);

void main() {
  test('a late directory response is dropped after switching account', () async {
    final provider = _LateProvider([
      CloudDrivePage(
        entries: [_file('old')],
        nextCursor: null,
        hasMore: false,
        sort: CloudDriveSort.name,
      ),
      CloudDrivePage(
        entries: [_file('new')],
        nextCursor: null,
        hasMore: false,
        sort: CloudDriveSort.name,
      ),
    ]);
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: _Memory()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    final first = await accounts.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk',
      displayName: '甲',
      credential: CloudDriveCredential(
        cookies: [
          CloudDriveCookie(name: 'BDUSS', value: 'a', domain: '.baidu.com'),
        ],
      ),
    );
    final browser = CloudDriveBrowserController(
      providers: CloudDriveProviderRegistry([provider]),
      accounts: accounts,
    );
    final opening = browser.openAccount(first);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    browser.close();
    final stale = await opening;
    expect(stale.entries, isEmpty);
    expect(provider.calls, 1);
  });
}

class _Memory implements CloudDriveSecretStorage {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
