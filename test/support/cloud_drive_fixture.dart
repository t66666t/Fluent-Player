import 'dart:async';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_launch_coordinator.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';

class CloudFixtureSecrets implements CloudDriveSecretStorage {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class FixtureCloudProvider implements CloudDriveProvider {
  FixtureCloudProvider(this.id, this.directories, {this.pageSize = 2});
  @override
  final String id;
  final Map<String, List<CloudDriveEntry>> directories;
  final int pageSize;
  final calls = <({String account, String parent, String? cursor})>[];
  final failOnce = <String>{};
  final gates = <String, Completer<void>>{};
  @override
  String get displayName => id == 'baidu' ? '百度网盘' : '夸克网盘';
  @override
  Uri get loginUri => Uri.https('example.invalid', '/login');
  @override
  CloudDriveCapabilities get capabilities =>
      CloudDriveCapabilities(pageSize: pageSize, serverDateSort: true);
  @override
  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  }) async {
    calls.add((
      account: request.remoteAccountId,
      parent: request.parentFileId,
      cursor: request.cursor,
    ));
    final pageKey = '${request.parentFileId}|${request.cursor ?? ''}';
    await gates[pageKey]?.future;
    if (failOnce.remove(pageKey)) {
      throw const CloudDriveFailure(CloudDriveFailureKind.network, '测试网络错误');
    }
    final entries = directories[request.parentFileId] ?? const [];
    final start = int.tryParse(request.cursor ?? '') ?? 0;
    final end = (start + pageSize).clamp(0, entries.length);
    return CloudDrivePage(
      entries: entries.sublist(start, end),
      nextCursor: end < entries.length ? '$end' : null,
      hasMore: end < entries.length,
      sort: request.sort,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudDriveEntry cloudEntry(
  String id, {
  String? name,
  CloudDriveEntryKind kind = CloudDriveEntryKind.video,
  String provider = 'baidu',
  String parent = '/',
  int? size,
  DateTime? modified,
}) => CloudDriveEntry(
  providerId: provider,
  accountLocalId: 'test',
  remoteAccountId: 'fixture-$provider',
  driveId: '0',
  fileId: id,
  parentFileId: parent,
  name: name ?? '$id.mp4',
  kind: kind,
  pathHint: kind == CloudDriveEntryKind.folder ? id : '$parent/$id',
  durationMs: kind == CloudDriveEntryKind.video ? 120000 : null,
  size: size,
  modifiedAt: modified,
  revision: 'v1',
);

Future<CloudDriveRuntime> cloudRuntime(
  List<FixtureCloudProvider> fixtures,
) async {
  final registry = CloudDriveProviderRegistry(fixtures);
  final accounts = CloudDriveAccountRepository(
    credentials: CloudDriveCredentialStore(storage: CloudFixtureSecrets()),
    metadata: MemoryCloudDriveAccountMetadataStore(),
  );
  for (final provider in fixtures) {
    await accounts.commitVerified(
      providerId: provider.id,
      remoteAccountId: 'fixture-${provider.id}',
      displayName: '学习账号',
      credential: const CloudDriveCredential(
        cookies: [
          CloudDriveCookie(
            name: 'session',
            value: 'fixture',
            domain: '.example.invalid',
          ),
        ],
      ),
    );
  }
  final library = LibraryService()..resetLibraryForTesting();
  library.writeLibrarySnapshotOverrideForTesting = () async {};
  final playlist = PlaylistManager()..initialize(libraryService: library);
  return CloudDriveRuntime(
    accounts: accounts,
    providers: registry,
    playback: CloudDrivePlaybackService(
      providers: registry,
      accounts: accounts,
    ),
    launch: CloudDriveLaunchCoordinator(
      library: library,
      playlist: playlist,
      playback: MediaPlaybackService(),
    ),
  );
}
