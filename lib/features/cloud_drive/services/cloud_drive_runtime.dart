import '../../../services/storage_migration_coordinator.dart';
import '../../../services/app_storage_service.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../../services/library_service.dart';
import '../../../services/media_playback_service.dart';
import '../../../services/playlist_manager.dart';
import '../auth/cloud_drive_credential_store.dart';
import '../models/cloud_drive_models.dart';
import '../providers/baidu_cloud_drive_provider.dart';
import '../providers/cloud_drive_provider.dart';
import '../providers/quark_cloud_drive_provider.dart';
import '../providers/uc_cloud_drive_provider.dart';
import '../providers/aliyun_cloud_drive_provider.dart';
import 'cloud_drive_account_repository.dart';
import 'cloud_drive_launch_coordinator.dart';
import 'cloud_drive_playback_service.dart';
import 'cloud_drive_materialization.dart';
import 'cloud_drive_startup.dart';
import 'cloud_drive_thumbnails.dart';

class FileCloudDriveAccountMetadataStore
    implements CloudDriveAccountMetadataStore {
  FileCloudDriveAccountMetadataStore(this.file);

  final File file;

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

/// Process-wide cloud drive services. Startup only reads local account names.
class CloudDriveRuntime {
  CloudDriveRuntime({
    required this.accounts,
    required this.providers,
    required this.playback,
    required this.launch,
  });

  static CloudDriveRuntime? instance;
  static Future<CloudDriveRuntime>? _installing;
  static int _epoch = 0;
  static LibraryService? _library;
  static PlaylistManager? _playlist;
  static MediaPlaybackService? _mediaPlayback;
  static Future<void>? _libraryReady;

  final CloudDriveAccountRepository accounts;
  final CloudDriveProviderRegistry providers;
  final CloudDrivePlaybackService playback;
  final CloudDriveLaunchCoordinator launch;
  CloudDriveMaterialization? materialization;
  CloudDriveThumbnails? thumbnails;

  /// Register before the UI can open a cloud page. Local account loading waits
  /// for the library directory, independently of cache, podcast or media-session
  /// startup. A page or playback opened early shares the same pending future.
  static void beginInstall({
    required LibraryService library,
    required PlaylistManager playlist,
    required MediaPlaybackService mediaPlayback,
    Future<void>? libraryReady,
  }) {
    _library = library;
    _playlist = playlist;
    _mediaPlayback = mediaPlayback;
    _libraryReady = libraryReady;
    CloudDriveStartup.bind(
      pending: _installing,
      retry: () => ensureInstalled().then((_) {}),
    );
    final future = ensureInstalled();
    CloudDriveStartup.bind(
      pending: future.then((_) {}),
      retry: () => ensureInstalled().then((_) {}),
    );
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          debugPrint(
            'Cloud drive init failed: ${redactCloudDriveLog('$error')}',
          );
        },
      ),
    );
  }

  static Future<void> prepareStorageMigration() async {
    ++_epoch;
    final pending = _installing;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final runtime = instance;
    if (runtime != null) {
      await runtime.materialization?.prepareStorageMigration();
      await runtime.shutdown();
    }
  }

  static Future<CloudDriveRuntime> ensureInstalled() {
    if (StorageMigrationCoordinator.maintenance) {
      return Future.error(const StorageUnavailableException('数据目录正在迁移'));
    }
    final current = instance;
    if (current != null) return Future<CloudDriveRuntime>.value(current);
    final pending = _installing;
    if (pending != null) return pending;
    final library = _library;
    final playlist = _playlist;
    final mediaPlayback = _mediaPlayback;
    if (library == null || playlist == null || mediaPlayback == null) {
      return Future<CloudDriveRuntime>.error(
        const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '网盘播放服务尚未初始化',
        ),
      );
    }
    final epoch = _epoch;
    final future = _installNow(
      library: library,
      playlist: playlist,
      mediaPlayback: mediaPlayback,
      epoch: epoch,
      libraryReady: _libraryReady,
    );
    _installing = future;
    // whenComplete creates another failed future on error. Handle the cleanup
    // branch explicitly, while returning the original failure to the caller.
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (identical(_installing, future) && instance == null) {
            _installing = null;
          }
        },
      ),
    );
    return future;
  }

  static Future<void> install({
    required LibraryService library,
    required PlaylistManager playlist,
    required MediaPlaybackService mediaPlayback,
  }) {
    beginInstall(
      library: library,
      playlist: playlist,
      mediaPlayback: mediaPlayback,
    );
    return ensureInstalled().then((_) {});
  }

  static Future<CloudDriveRuntime> _installNow({
    required LibraryService library,
    required PlaylistManager playlist,
    required MediaPlaybackService mediaPlayback,
    required int epoch,
    required Future<void>? libraryReady,
  }) async {
    await libraryReady;
    if (epoch != _epoch) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '网盘播放服务已关闭',
      );
    }
    final root = library.dataRootDirOrNull;
    final metadata = root == null
        ? MemoryCloudDriveAccountMetadataStore()
        : FileCloudDriveAccountMetadataStore(
            AppStorageService.instance.isReady
                ? await AppStorageService.instance.dataRecord(
                    'cloud_drive_accounts.json',
                  )
                : File(p.join(root.path, 'cloud_drive_accounts.json')),
          );
    final accounts = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(),
      metadata: metadata,
    );
    await accounts.load();
    if (epoch != _epoch) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '网盘播放服务已关闭',
      );
    }
    final providers = CloudDriveProviderRegistry([
      BaiduCloudDriveProvider(),
      QuarkCloudDriveProvider(),
      UcCloudDriveProvider(),
      AliyunCloudDriveProvider(),
    ]);
    for (final provider in providers.all) {
      provider.onCredentialRefreshed = accounts.refreshCredential;
    }
    final playback = CloudDrivePlaybackService(
      providers: providers,
      accounts: accounts,
      subtitleCacheRoot: root == null
          ? null
          : AppStorageService.instance.isReady
          ? await AppStorageService.instance.featureDirectory(
              'cloud_drive_subtitles',
            )
          : Directory(p.join(root.path, 'cloud_drive_subtitles')),
    );
    final runtime = CloudDriveRuntime(
      accounts: accounts,
      providers: providers,
      playback: playback,
      launch: CloudDriveLaunchCoordinator(
        library: library,
        playlist: playlist,
        playback: mediaPlayback,
      ),
    );
    mediaPlayback.attachCloudDrivePlayback(playback);
    final materialization = CloudDriveMaterialization(
      providers: providers,
      accounts: accounts,
      cacheRoot: root == null
          ? null
          : AppStorageService.instance.isReady
          ? await AppStorageService.instance.featureDirectory(
              'cloud_drive_material',
            )
          : Directory(p.join(root.path, 'cloud_drive_material')),
    );
    runtime.materialization = materialization;
    library.cloudDriveMaterialization = materialization;
    if (root != null) unawaited(materialization.loadIndex());
    if (epoch != _epoch) {
      await playback.close();
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '网盘播放服务已关闭',
      );
    }
    instance = runtime;
    if (root != null) {
      final thumbnails = CloudDriveThumbnails(
        providers: providers,
        accounts: accounts,
        root: Directory(p.join(root.path, 'thumbnails', 'cloud_drive')),
      );
      runtime.thumbnails = thumbnails;
      library.cloudDriveThumbnails = thumbnails;
      accounts.sessionChanges.addListener(library.refreshCloudDriveThumbnails);
      library.refreshCloudDriveThumbnails();
    }
    return runtime;
  }

  Future<void> shutdown() async {
    launch.dispose();
    _epoch++;
    thumbnails?.close();
    if (_library != null) {
      accounts.sessionChanges.removeListener(
        _library!.refreshCloudDriveThumbnails,
      );
    }
    await playback.close();
    if (identical(instance, this)) {
      instance = null;
      _installing = null;
      _library?.cloudDriveMaterialization = null;
      _library?.cloudDriveThumbnails = null;
    }
  }
}

/// Avoids touching the network during the first frame.
void installCloudDriveRuntimeLater({
  required LibraryService library,
  required PlaylistManager playlist,
  required MediaPlaybackService mediaPlayback,
}) {
  CloudDriveRuntime.beginInstall(
    library: library,
    playlist: playlist,
    mediaPlayback: mediaPlayback,
  );
}
