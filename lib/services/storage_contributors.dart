import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../features/podcasts/podcast_store.dart';
import 'storage_audit_models.dart';
import 'storage_audit_service.dart';
import 'storage_runtime_registry.dart';
import 'temporary_storage_cleanup_models.dart';

/// In-memory protection copied from services that are already running.
///
/// Collecting this must not construct a podcast runtime or a cloud login.
class StorageLiveProtection {
  const StorageLiveProtection({
    this.podcastEpisodeIds = const {},
    this.podcastAssetIds = const {},
    this.cloudDirectories = const {},
    this.artworkBusy = false,
  });

  final Set<String> podcastEpisodeIds;
  final Set<String> podcastAssetIds;
  final Set<String> cloudDirectories;
  final bool artworkBusy;
}

/// A library card that may share a cloud material directory.
class StorageCloudOwnerHint {
  const StorageCloudOwnerHint({
    required this.itemId,
    required this.title,
    required this.providerId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    this.revision = '',
    this.quality = '',
  });

  final String itemId;
  final String title;
  final String providerId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String revision;
  final String quality;
}

class StorageFeatureInspection {
  const StorageFeatureInspection({
    required this.roots,
    required this.verifiedPaths,
    required this.assets,
    required this.warnings,
    required this.sourceVersions,
  });

  final List<StorageRoot> roots;
  final List<String> verifiedPaths;
  final List<StorageAssetDescriptor> assets;
  final List<String> warnings;
  final Map<String, int> sourceVersions;
}

/// Reads local indexes only. Missing files and unreadable indexes are different.
StorageFeatureInspection inspectStorageFeatures({
  required Directory dataRoot,
  Directory? appDataRoot,
  Directory? historicalRoot,
  Directory? systemTemp,
  StorageLiveProtection live = const StorageLiveProtection(),
  List<StorageCloudOwnerHint> cloudOwners = const [],
  List<String>? onlyPaths,
}) {
  // Inventory paths are canonical. Match that spelling when a platform's
  // support/data directory (for example /var on macOS) is an alias.
  dataRoot = _inspectionRoot(dataRoot, onlyPaths)!;
  appDataRoot = _inspectionRoot(appDataRoot, onlyPaths);
  historicalRoot = _inspectionRoot(historicalRoot, onlyPaths);
  if (onlyPaths != null && live.cloudDirectories.isNotEmpty) {
    live = StorageLiveProtection(
      podcastEpisodeIds: live.podcastEpisodeIds,
      podcastAssetIds: live.podcastAssetIds,
      cloudDirectories: {
        for (final path in live.cloudDirectories)
          _inspectionRoot(Directory(path), onlyPaths)!.path,
      },
      artworkBusy: live.artworkBusy,
    );
  }
  final roots = <StorageRoot>[];
  final verified = <String>[];
  final assets = <StorageAssetDescriptor>[];
  final warnings = <String>[];
  final versions = <String, int>{};
  var sawCloud = false;

  void addRoot(StorageRoot root) {
    if (roots.any(
      (existing) => storagePathKey(existing.path) == storagePathKey(root.path),
    )) {
      return;
    }
    roots.add(root);
    verified.add(root.path);
  }

  _inspectMediaCache(
    dataRoot,
    appDataRoot: appDataRoot,
    roots: roots,
    verified: verified,
    assets: assets,
    warnings: warnings,
    versions: versions,
    onlyPaths: onlyPaths,
  );

  final podcast = _inspectionRoot(
    _podcastRoot(
      dataRoot: dataRoot,
      appDataRoot: appDataRoot,
      historicalRoot: historicalRoot,
      warnings: warnings,
    ),
    onlyPaths,
  );
  if (podcast != null && _selectedDirectory(podcast.path, onlyPaths)) {
    addRoot(
      StorageRoot(
        podcast.path,
        '播客数据',
        StorageRootKind.data,
        feature: 'podcast',
      ),
    );
    assets.addAll(
      _podcastAssets(
        podcast,
        live: live,
        warnings: warnings,
        versions: versions,
        onlyPaths: onlyPaths,
      ),
    );
  }

  final artwork = _inspectionRoot(
    _artworkRoot(
      dataRoot: dataRoot,
      appDataRoot: appDataRoot,
      historicalRoot: historicalRoot,
      warnings: warnings,
    ),
    onlyPaths,
  );
  if (artwork != null && _selectedDirectory(artwork.path, onlyPaths)) {
    addRoot(
      StorageRoot(
        artwork.path,
        '统一封面',
        StorageRootKind.data,
        feature: 'artwork',
      ),
    );
    assets.addAll(
      _artworkAssets(
        artwork,
        busy: live.artworkBusy,
        warnings: warnings,
        versions: versions,
      ),
    );
    if (live.artworkBusy) verified.add(p.join(artwork.path, 'staging'));
  }

  final material = _inspectionRoot(
    _knownChild(
      dataRoot,
      'cloud_drive_material',
      evidence: _cloudMaterialEvidence,
    ),
    onlyPaths,
  );
  if (material != null && _selectedDirectory(material.path, onlyPaths)) {
    sawCloud = true;
    addRoot(
      StorageRoot(
        material.path,
        '网盘素材',
        StorageRootKind.data,
        feature: 'cloudMaterial',
      ),
    );
    assets.addAll(
      _cloudMaterialAssets(
        material,
        owners: cloudOwners,
        protected: live.cloudDirectories,
        warnings: warnings,
        onlyPaths: onlyPaths,
      ),
    );
  }
  final subtitles = _inspectionRoot(
    _knownChild(dataRoot, 'cloud_drive_subtitles'),
    onlyPaths,
  );
  if (subtitles != null && _selectedDirectory(subtitles.path, onlyPaths)) {
    sawCloud = true;
    addRoot(
      StorageRoot(
        subtitles.path,
        '网盘字幕缓存',
        StorageRootKind.data,
        feature: 'cloudSubtitles',
      ),
    );
    assets.addAll(
      _cloudSubtitleAssets(subtitles, warnings: warnings, onlyPaths: onlyPaths),
    );
  }
  final accounts = File(p.join(dataRoot.path, 'cloud_drive_accounts.json'));
  if (accounts.existsSync()) {
    sawCloud = true;
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'cloud-accounts',
        origin: StorageOrigin.cloudDrive,
        sourceTags: const [StorageOrigin.cloudDrive],
        category: StorageCategory.metadata,
        policy: StorageCleanupPolicy.featureManaged,
        title: '网盘账号记录',
        paths: [accounts.path, '${accounts.path}.tmp'],
        role: StorageAssetRole.accountMetadata,
        protection: '账号记录不参与缓存清理，本页也不读取登录凭据',
      ),
    );
  }
  if (sawCloud) {
    warnings.add('网盘登录凭据在系统安全存储中，本页不读取内容，也不删除其底层文件。');
  }

  for (final entry in _registryEntries(dataRoot, appDataRoot)) {
    final directory = Directory(entry.path);
    final selectedRoot = _inspectionRoot(directory, onlyPaths)!;
    if (!_selectedDirectory(selectedRoot.path, onlyPaths)) continue;
    if (!directory.existsSync()) continue;
    final login = entry.kind == 'cloudLogin';
    final prefix = login
        ? 'fluent_cloud_drive_login_'
        : 'cloud_drive_subtitles';
    final marker = login ? 'cloud-drive-login/' : 'cloud-drive-subtitles/';
    if (systemTemp != null &&
        !_withinPath(systemTemp.path, directory.path) &&
        storagePathKey(systemTemp.path) != storagePathKey(directory.path)) {
      warnings.add('登记的临时目录不在系统临时目录中，已跳过：${directory.path}');
      continue;
    }
    if (!p.basename(directory.path).startsWith(prefix)) continue;
    if (!ownedTemporaryMarker(directory, marker)) {
      warnings.add('已登记但缺少归属标记，未当作可删除目录：${directory.path}');
      continue;
    }
    verified.add(directory.path);
    final busy =
        StorageRuntimeRegistry.isActive(directory.path) ||
        temporaryLeaseActive(directory);
    if (!login) {
      if (busy) {
        assets.add(
          StorageAssetDescriptor(
            assetKey: 'temp:${storagePathKey(directory.path)}',
            origin: StorageOrigin.cloudDrive,
            sourceTags: const [StorageOrigin.cloudDrive],
            category: StorageCategory.subtitles,
            policy: StorageCleanupPolicy.protected,
            title: '网盘字幕备用临时目录',
            directory: directory.path,
            protected: true,
            role: StorageAssetRole.subtitleBody,
            protection: '字幕正在写入',
          ),
        );
      } else {
        assets.addAll(
          _cloudSubtitleAssets(
            selectedRoot,
            warnings: warnings,
            onlyPaths: onlyPaths,
          ),
        );
      }
      continue;
    }
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'temp:${storagePathKey(directory.path)}',
        origin: StorageOrigin.cloudDrive,
        sourceTags: const [StorageOrigin.cloudDrive],
        category: StorageCategory.workTemp,
        policy: busy
            ? StorageCleanupPolicy.protected
            : StorageCleanupPolicy.regenerableCache,
        title: '网盘登录临时目录',
        directory: directory.path,
        protected: busy,
        deletable: !busy,
        role: StorageAssetRole.loginProfile,
        protection: busy ? '登录页面仍在使用这个临时目录' : null,
        version: busy ? 1 : 0,
      ),
    );
  }

  final checkpointCandidates = <Directory>[
    dataRoot,
    ?appDataRoot,
    ?historicalRoot,
  ];
  for (final root in checkpointCandidates) {
    final file = File(
      p.join(root.path, 'transcription_slice_checkpoints.json'),
    );
    if (!file.existsSync()) continue;
    versions[_tokenKey(file.path)] = _fileToken(file);
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'transcription-checkpoints',
        origin: StorageOrigin.appData,
        sourceTags: const [StorageOrigin.appData],
        category: StorageCategory.metadata,
        policy: StorageCleanupPolicy.featureManaged,
        title: '转写恢复检查点',
        paths: [file.path],
        role: StorageAssetRole.checkpoint,
        protection: '转写恢复数据不参与缓存清理',
      ),
    );
  }
  return StorageFeatureInspection(
    roots: roots,
    verifiedPaths: verified,
    assets: assets,
    warnings: warnings,
    sourceVersions: versions,
  );
}

/// Ownership comes from the persistent journal, independently of the running
/// download service. A damaged journal never turns retained media into cache.
void _inspectMediaCache(
  Directory dataRoot, {
  Directory? appDataRoot,
  required List<StorageRoot> roots,
  required List<String> verified,
  required List<StorageAssetDescriptor> assets,
  required List<String> warnings,
  required Map<String, int> versions,
  List<String>? onlyPaths,
}) {
  for (final source in ['bilibili', 'cloud_drive']) {
    final origin = source == 'bilibili'
        ? StorageOrigin.bilibili
        : StorageOrigin.cloudDrive;
    for (final part in ['files', 'tasks']) {
      final base = Directory(p.join(dataRoot.path, 'downloads', source, part));
      for (final directory in [
        base,
        if (source == 'cloud_drive' && part == 'files')
          for (final provider in ['baidu', 'quark', 'uc', 'aliyun'])
            Directory(p.join(base.path, provider)),
      ]) {
        if (!directory.existsSync()) continue;
        List<FileSystemEntity> children;
        try {
          children = _selectedChildren(directory, onlyPaths);
        } on FileSystemException {
          warnings.add('媒体缓存目录暂时无法读取，已保留其中的数据：${directory.path}');
          continue;
        }
        for (final child in children) {
          if (!p.basename(child.path).startsWith('cache_')) continue;
          assets.add(
            StorageAssetDescriptor(
              assetKey: 'media-cache-unindexed:${child.path}',
              origin: origin,
              category: part == 'files'
                  ? StorageCategory.offlineDownloads
                  : StorageCategory.downloadTemp,
              policy: StorageCleanupPolicy.featureManaged,
              title: '媒体缓存（等待核对索引）',
              paths: child is File ? [child.path] : const [],
              directory: child is Directory ? child.path : null,
              role: part == 'files'
                  ? StorageAssetRole.assembledMedia
                  : StorageAssetRole.resumePart,
              protection: '需先在缓存管理中核对归属与续传状态',
            ),
          );
        }
      }
    }
  }
  final candidates = <File>[
    File(p.join(dataRoot.path, 'media_cache.json')),
    if (appDataRoot != null &&
        storagePathKey(appDataRoot.path) != storagePathKey(dataRoot.path))
      File(p.join(appDataRoot.path, 'media_cache.json')),
  ];
  for (final journal in candidates) {
    if (!journal.existsSync() && !File('${journal.path}.bak').existsSync()) {
      continue;
    }
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'media-cache-index:${journal.path}',
        origin: StorageOrigin.appData,
        category: StorageCategory.metadata,
        policy: StorageCleanupPolicy.featureManaged,
        title: '媒体缓存任务与版本索引',
        paths: [journal.path, '${journal.path}.bak', '${journal.path}.next'],
        role: StorageAssetRole.checkpoint,
      ),
    );
    Map? raw;
    for (final file in [journal, File('${journal.path}.bak')]) {
      versions[_tokenKey(file.path)] = _fileToken(file);
      if (!file.existsSync()) continue;
      try {
        final value = jsonDecode(file.readAsStringSync());
        if (value is Map &&
            value['version'] == 1 &&
            value['variants'] is List &&
            value['tasks'] is List) {
          raw = value;
          break;
        }
      } catch (_) {
        /* try the last atomically committed generation */
      }
    }
    if (raw == null) {
      warnings.add('媒体缓存索引无法读取，完整媒体及断点已保留，请先在缓存管理中恢复。');
      continue;
    }
    String? localPath(Map entry, String field) {
      final value = entry[field];
      if (value is! String || !p.isAbsolute(value)) return null;
      final refs = entry['_storagePaths'];
      final ref = refs is Map ? refs[field] : null;
      if (ref is Map &&
          ref['rootId'] == 'data' &&
          ref['relativePath'] is String) {
        final relative = ref['relativePath'] as String;
        if (!p.posix.isAbsolute(relative) &&
            !p.windows.isAbsolute(relative) &&
            !relative.split(RegExp(r'[/\\]')).contains('..')) {
          return p.joinAll([dataRoot.path, ...relative.split('/')]);
        }
      }
      return value;
    }

    void registerExternal(String file) {
      if (_withinPath(dataRoot.path, file)) return;
      final parent = p.dirname(file);
      if (!roots.any((r) => storagePathKey(r.path) == storagePathKey(parent))) {
        roots.add(
          StorageRoot(
            parent,
            '媒体缓存自定义目录',
            StorageRootKind.data,
            scoped: true,
            feature: 'mediaCacheExternal',
          ),
        );
      }
      verified.add(file);
    }

    for (final variant in (raw['variants'] as List).whereType<Map>()) {
      final path = localPath(variant, 'path');
      final source = variant['source'];
      final quality = variant['quality'];
      if (path == null || source is! Map || quality is! Map) continue;
      registerExternal(path);
      final bili =
          (source['ref'] as Map?)?['kind']?.toString().startsWith('bilibili') ==
              true ||
          (source['ref'] as Map?)?['bvid'] != null;
      assets.add(
        StorageAssetDescriptor(
          assetKey: 'media-cache-file:${storagePathKey(path)}',
          origin: bili ? StorageOrigin.bilibili : StorageOrigin.cloudDrive,
          category: StorageCategory.offlineDownloads,
          policy: StorageCleanupPolicy.savedContent,
          title: '${source['title'] ?? '媒体缓存'} · ${quality['label'] ?? ''}',
          paths: [path],
          role: StorageAssetRole.assembledMedia,
          explicitDelete: true,
          ownerIds: ['${source['itemId'] ?? ''}'],
          version: (variant['createdAt'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    for (final task in (raw['tasks'] as List).whereType<Map>()) {
      final directory = localPath(task, 'workDirectory');
      if (directory == null || p.basename(directory) != 'cache_${task['id']}') {
        continue;
      }
      final source = task['source'] as Map?;
      final done = task['state'] == 'completed';
      final bili = (source?['ref'] as Map?)?['bvid'] != null;
      // Task roots are always app-managed, never a user's download folder.
      if (!_withinPath(dataRoot.path, directory) &&
          !(appDataRoot != null && _withinPath(appDataRoot.path, directory))) {
        continue;
      }
      assets.add(
        StorageAssetDescriptor(
          assetKey: 'media-cache-task:${task['id']}',
          origin: bili ? StorageOrigin.bilibili : StorageOrigin.cloudDrive,
          category: StorageCategory.downloadTemp,
          policy: done
              ? StorageCleanupPolicy.regenerableCache
              : StorageCleanupPolicy.featureManaged,
          title: '${source?['title'] ?? '媒体'} · 缓存断点',
          directory: directory,
          role: StorageAssetRole.resumePart,
          explicitDelete: !done,
          deletable: done,
          protection: done ? null : '放弃续传才会删除有效断点',
          ownerIds: ['${task['id']}'],
          version: (task['generation'] as num?)?.toInt() ?? 0,
        ),
      );
    }
  }
}

Directory? _podcastRoot({
  required Directory dataRoot,
  Directory? appDataRoot,
  Directory? historicalRoot,
  required List<String> warnings,
}) {
  final primary = Directory(p.join(dataRoot.path, 'podcasts'));
  final database = File(p.join(primary.path, 'podcasts.sqlite'));
  if (database.existsSync()) return primary;
  for (final root in [appDataRoot, historicalRoot]) {
    if (root == null) continue;
    final candidate = Directory(p.join(root.path, 'podcasts'));
    final file = File(p.join(candidate.path, 'podcasts.sqlite'));
    if (!file.existsSync()) continue;
    if (_databaseTrusted(
      file,
      label: '历史播客目录',
      warnings: warnings,
      supportedVersion: PodcastStore.schemaVersion,
    )) {
      return candidate;
    }
    warnings.add('历史播客目录无法确认属于本应用，已跳过：${candidate.path}');
  }
  return null;
}

Directory? _artworkRoot({
  required Directory dataRoot,
  Directory? appDataRoot,
  Directory? historicalRoot,
  required List<String> warnings,
}) {
  final primary = Directory(p.join(dataRoot.path, 'artwork'));
  if (File(p.join(primary.path, 'index.sqlite')).existsSync()) return primary;
  for (final root in [appDataRoot, historicalRoot]) {
    if (root == null) continue;
    final candidate = Directory(p.join(root.path, 'artwork'));
    final file = File(p.join(candidate.path, 'index.sqlite'));
    if (!file.existsSync()) continue;
    if (_databaseTrusted(
      file,
      label: '历史封面目录',
      warnings: warnings,
      supportedVersion: 99,
      requiredTable: 'blobs',
    )) {
      return candidate;
    }
    warnings.add('历史封面目录无法确认属于本应用，已跳过：${candidate.path}');
  }
  return null;
}

Directory? _knownChild(
  Directory dataRoot,
  String name, {
  bool Function(Directory directory)? evidence,
}) {
  final directory = Directory(p.join(dataRoot.path, name));
  if (!directory.existsSync()) return null;
  if (evidence != null && !evidence(directory)) return null;
  return directory;
}

bool _cloudMaterialEvidence(Directory directory) {
  if (!directory.existsSync()) return false;
  // The library root owns this exact folder even before the first download.
  return p.basename(directory.path) == 'cloud_drive_material';
}

bool _databaseTrusted(
  File file, {
  required String label,
  required List<String> warnings,
  required int supportedVersion,
  String requiredTable = 'records',
}) {
  Database? database;
  try {
    database = sqlite3.open(file.path, mode: OpenMode.readOnly);
    database.execute('PRAGMA query_only=ON');
    final version = database.select('PRAGMA user_version').first.values.first;
    if (version is! int || version > supportedVersion) {
      warnings.add('$label 的数据库版本无法识别，已跳过。');
      return false;
    }
    final tables = database.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [requiredTable],
    );
    return tables.isNotEmpty;
  } catch (error) {
    warnings.add('$label 无法只读核对：$error');
    return false;
  } finally {
    database?.dispose();
  }
}

List<StorageAssetDescriptor> _podcastAssets(
  Directory root, {
  required StorageLiveProtection live,
  required List<String> warnings,
  required Map<String, int> versions,
  List<String>? onlyPaths,
}) {
  final assets = <StorageAssetDescriptor>[];
  final database = File(p.join(root.path, 'podcasts.sqlite'));
  versions[_tokenKey(database.path)] = _fileToken(database);
  for (final suffix in ['.sqlite-wal', '.sqlite-shm']) {
    final auxiliary = File('${database.path}$suffix');
    if (auxiliary.existsSync()) {
      versions[_tokenKey(auxiliary.path)] = _fileToken(auxiliary);
    }
  }
  assets.add(
    StorageAssetDescriptor(
      assetKey: 'podcast-database',
      origin: StorageOrigin.podcast,
      sourceTags: const [StorageOrigin.podcast],
      category: StorageCategory.metadata,
      policy: StorageCleanupPolicy.featureManaged,
      title: '播客数据库',
      paths: [database.path, '${database.path}-wal', '${database.path}-shm'],
      role: StorageAssetRole.database,
      protection: '订阅、目录、设置和听过状态不由缓存清理删除',
    ),
  );
  final records = _readRows(database, warnings, '播客索引');
  if (records == null) {
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'podcast-unreadable',
        origin: StorageOrigin.podcast,
        sourceTags: const [StorageOrigin.podcast],
        category: StorageCategory.other,
        policy: StorageCleanupPolicy.unknown,
        title: '播客索引不可读',
        directory: root.path,
        protected: true,
        protection: '索引无法读取，不能把其中的文件当成无引用缓存',
      ),
    );
    return assets;
  }
  final episodes = <String, Map<String, dynamic>>{};
  final channels = <String, Map<String, dynamic>>{};
  final states = <String, Map<String, dynamic>>{};
  final downloads = <String, Map<String, dynamic>>{};
  final mediaAssets = <Map<String, dynamic>>[];
  final now = DateTime.now().millisecondsSinceEpoch;
  final busyEpisodes = {...live.podcastEpisodeIds};
  final busyAssets = {...live.podcastAssetIds};
  for (final row in records) {
    final kind = row.kind;
    final payload = row.payload;
    switch (kind) {
      case 'episode':
        episodes[row.id] = payload;
      case 'channel':
        channels[row.id] = payload;
      case 'state':
        states[row.id] = payload;
      case 'download':
        downloads[row.id] = payload;
      case 'asset':
        mediaAssets.add(payload);
      case 'assetLease':
      case 'lease':
      case 'mediaUse':
        final until = payload['until'];
        if (until is int && until > now) {
          if (kind == 'assetLease') busyAssets.add(row.id);
          if (kind == 'mediaUse' || kind == 'lease') {
            final episode = row.channel.isNotEmpty
                ? row.channel
                : row.id.replaceFirst(RegExp(r'^download:'), '');
            busyEpisodes.add(episode);
          }
        }
    }
  }
  for (final asset in mediaAssets) {
    final id = asset['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    final directory = Directory(p.join(root.path, 'media', id));
    if (!_selectedDirectory(directory.path, onlyPaths)) continue;
    final episodeId = asset['episodeId']?.toString() ?? '';
    final episode = episodes[episodeId];
    final channelId = episode?['channelId']?.toString() ?? '';
    final channel = channels[channelId];
    final title = _podcastTitle(channel, episode, episodeId);
    final revision = asset['revision'] is int ? asset['revision'] as int : 0;
    final downloaded = asset['downloaded'] == true;
    final retained = states[episodeId]?['retained'] == true;
    final task = downloads[episodeId];
    final sameMedia = task != null && task['mediaUrl'] == asset['url'];
    final status = sameMedia ? task['status']?.toString() : null;
    final unfinished =
        status != null && status.isNotEmpty && status != 'completed';
    final onDisk = directory.existsSync() ? _files(directory) : <File>[];
    final complete = _podcastComplete(asset, onDisk);
    final busy = busyAssets.contains(id) || busyEpisodes.contains(episodeId);
    final broken = downloaded && !complete;
    if (broken) {
      warnings.add('$title 标记为已下载，但文件不完整，不能当作可离线播放。');
    }
    final StorageCategory category;
    final StorageCleanupPolicy policy;
    final bool deletable;
    final bool explicit;
    final String? protection;
    if (busy) {
      category = downloaded
          ? StorageCategory.offlineDownloads
          : unfinished
          ? StorageCategory.downloadTemp
          : StorageCategory.streaming;
      policy = StorageCleanupPolicy.protected;
      deletable = false;
      explicit = false;
      protection = '播放、试听、下载或租约仍在使用';
    } else if (broken) {
      category = StorageCategory.offlineDownloads;
      policy = StorageCleanupPolicy.savedContent;
      deletable = false;
      explicit = true;
      protection = '清单标记已下载，但文件不完整，不能当作可离线播放';
    } else if (downloaded && complete) {
      category = StorageCategory.offlineDownloads;
      policy = StorageCleanupPolicy.savedContent;
      deletable = false;
      explicit = true;
      protection = '删除离线文件后需要重新下载，听过状态会保留';
    } else if (unfinished) {
      category = StorageCategory.downloadTemp;
      policy = StorageCleanupPolicy.featureManaged;
      deletable = false;
      explicit = true;
      protection = '放弃下载才会删除续传数据，当前进度不会按时间清理';
    } else if (retained) {
      category = StorageCategory.streaming;
      policy = StorageCleanupPolicy.protected;
      deletable = false;
      explicit = false;
      protection = '用户保留了这个节目的缓存';
    } else {
      category = StorageCategory.streaming;
      policy = StorageCleanupPolicy.regenerableCache;
      deletable = true;
      explicit = false;
      protection = null;
    }
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'podcast:$id',
        origin: StorageOrigin.podcast,
        sourceTags: const [StorageOrigin.podcast],
        category: category,
        policy: policy,
        title: title,
        directory: directory.path,
        protected: busy,
        protection: protection,
        deletable: deletable,
        explicitDelete: explicit,
        role: StorageAssetRole.mediaSegment,
        version: Object.hash(revision, downloaded, busy, status, retained),
        ownerIds: [if (episodeId.isNotEmpty) episodeId],
        detail: broken ? '文件和下载清单不一致' : channel?['title']?.toString(),
      ),
    );
  }
  final transcripts = Directory(p.join(root.path, 'transcripts'));
  if (transcripts.existsSync()) {
    for (final file in _files(transcripts, onlyPaths: onlyPaths)) {
      final name = p.basename(file.path).toLowerCase();
      if (!name.endsWith('.srt') && !name.endsWith('.vtt')) continue;
      final episodeId = p.basenameWithoutExtension(file.path);
      assets.add(
        StorageAssetDescriptor(
          assetKey: 'podcast-transcript:$episodeId',
          origin: StorageOrigin.podcast,
          sourceTags: const [StorageOrigin.podcast],
          category: StorageCategory.subtitles,
          policy: StorageCleanupPolicy.savedContent,
          title: _podcastTitle(
            channels[episodes[episodeId]?['channelId']?.toString()],
            episodes[episodeId],
            episodeId,
          ),
          paths: [file.path],
          role: StorageAssetRole.subtitleBody,
          subtitleKind: StorageSubtitleKinds.podcastOfficial,
          explicitDelete: true,
          ownerIds: [episodeId],
          protection: '播客官方文稿按已保存字幕删除，不会随缓存清理',
        ),
      );
    }
  }
  return assets;
}

String _podcastTitle(
  Map<String, dynamic>? channel,
  Map<String, dynamic>? episode,
  String episodeId,
) {
  final episodeTitle = episode?['title']?.toString();
  final channelTitle = channel?['title']?.toString();
  if (episodeTitle != null && episodeTitle.isNotEmpty) {
    if (channelTitle != null && channelTitle.isNotEmpty) {
      return '$channelTitle · $episodeTitle';
    }
    return episodeTitle;
  }
  if (episodeId.isEmpty) return '未订阅试听';
  return '未订阅试听 · $episodeId';
}

bool _podcastComplete(Map<String, dynamic> asset, List<File> files) {
  final total = asset['total'];
  final assembled = asset['assembled']?.toString();
  if (assembled != null && assembled.isNotEmpty) {
    final match = files.where((file) => p.basename(file.path) == assembled);
    if (match.isNotEmpty && total is int && match.first.lengthSync() == total) {
      return true;
    }
  }
  final segments = asset['segments'];
  if (segments is! Map || segments.isEmpty || total is! int || total <= 0) {
    return false;
  }
  final revision = asset['revision'] is int ? asset['revision'] as int : 0;
  for (final entry in segments.entries) {
    final expected = entry.value;
    if (expected is! int) return false;
    final name = '$revision-${entry.key}.seg';
    final match = files.where((file) => p.basename(file.path) == name);
    if (match.isEmpty || match.first.lengthSync() != expected) return false;
  }
  return true;
}

List<StorageAssetDescriptor> _artworkAssets(
  Directory root, {
  required bool busy,
  required List<String> warnings,
  required Map<String, int> versions,
}) {
  final assets = <StorageAssetDescriptor>[];
  final database = File(p.join(root.path, 'index.sqlite'));
  versions[_tokenKey(database.path)] = _fileToken(database);
  final rows = _readArtwork(database, warnings);
  if (rows == null) {
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'artwork-unreadable',
        origin: StorageOrigin.shared,
        sourceTags: const [StorageOrigin.shared],
        category: StorageCategory.other,
        policy: StorageCleanupPolicy.unknown,
        title: '封面索引不可读',
        directory: root.path,
        protected: true,
        protection: '封面索引无法读取，不能把图片当成无主缓存',
      ),
    );
    return assets;
  }
  if (busy) {
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'artwork-staging',
        origin: StorageOrigin.shared,
        sourceTags: const [StorageOrigin.shared],
        category: StorageCategory.workTemp,
        policy: StorageCleanupPolicy.protected,
        title: '封面发布',
        directory: p.join(root.path, 'staging'),
        protected: true,
        protection: '封面正在发布',
        role: StorageAssetRole.artworkStaging,
      ),
    );
  }
  for (final blob in rows) {
    final tags = <StorageOrigin>{StorageOrigin.shared, ...blob.tags};
    final regenerable = blob.regenerable && !blob.leased && !busy;
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'artwork:${blob.hash}',
        origin: StorageOrigin.shared,
        sourceTags: tags.toList(),
        category: StorageCategory.thumbnails,
        policy: regenerable
            ? StorageCleanupPolicy.regenerableCache
            : StorageCleanupPolicy.savedContent,
        title: blob.titles.isEmpty ? '共享封面' : blob.titles.join('、'),
        paths: [p.join(root.path, p.joinAll(blob.relative.split('/')))],
        protected: blob.leased || busy,
        deletable: regenerable,
        explicitDelete: !regenerable && !blob.leased && !busy,
        role: StorageAssetRole.artworkBlob,
        ownerIds: blob.ownerIds,
        version: Object.hash(blob.hash, blob.leased, blob.regenerable),
        protection: blob.leased || busy
            ? '封面正在使用或发布'
            : regenerable
            ? null
            : '缺少可重新获取的来源时按封面成果保留',
      ),
    );
  }
  return assets;
}

class _ArtworkBlob {
  _ArtworkBlob({
    required this.hash,
    required this.relative,
    required this.regenerable,
    required this.leased,
    required this.ownerIds,
    required this.titles,
    required this.tags,
  });
  final String hash;
  final String relative;
  final bool regenerable;
  final bool leased;
  final List<String> ownerIds;
  final List<String> titles;
  final Set<StorageOrigin> tags;
}

List<_ArtworkBlob>? _readArtwork(File file, List<String> warnings) {
  if (!file.existsSync()) return <_ArtworkBlob>[];
  Database? database;
  try {
    database = sqlite3.open(file.path, mode: OpenMode.readOnly);
    database.execute('PRAGMA query_only=ON');
    final blobs = database.select(
      'SELECT blob_hash, relative_path FROM blobs WHERE published=1',
    );
    final aliases = database.select(
      'SELECT request_key, blob_hash, adapter, persistent FROM aliases',
    );
    final owners = database.select(
      'SELECT owner_kind, owner_id, request_key FROM owners',
    );
    final leases = database.select('SELECT request_key FROM leases');
    final leased = leases.map((row) => row['request_key'].toString()).toSet();
    final byHash = <String, List<Row>>{};
    for (final alias in aliases) {
      final hash = alias['blob_hash']?.toString() ?? '';
      if (hash.isEmpty) continue;
      byHash.putIfAbsent(hash, () => []).add(alias);
    }
    return [
      for (final blob in blobs)
        _artworkBlob(
          hash: blob['blob_hash'].toString(),
          relative: blob['relative_path'].toString(),
          aliases: byHash[blob['blob_hash'].toString()] ?? const [],
          owners: owners,
          leased: leased,
        ),
    ];
  } catch (error) {
    warnings.add('封面索引无法只读打开，图片暂不可清理：$error');
    return null;
  } finally {
    database?.dispose();
  }
}

_ArtworkBlob _artworkBlob({
  required String hash,
  required String relative,
  required List<Row> aliases,
  required ResultSet owners,
  required Set<String> leased,
}) {
  final ownerIds = <String>[];
  final titles = <String>[];
  final tags = <StorageOrigin>{};
  var regenerable = aliases.isNotEmpty;
  var inUse = false;
  for (final alias in aliases) {
    final key = alias['request_key'].toString();
    final persistent = alias['persistent'] == 1;
    final adapter = alias['adapter']?.toString() ?? '';
    if (persistent || adapter.isEmpty || adapter == 'file') regenerable = false;
    if (leased.contains(key)) inUse = true;
    for (final owner in owners) {
      if (owner['request_key'].toString() != key) continue;
      final id = owner['owner_id'].toString();
      final kind = owner['owner_kind'].toString();
      ownerIds.add(id);
      titles.add(id);
      if (kind.toLowerCase().contains('podcast')) {
        tags.add(StorageOrigin.podcast);
      }
    }
  }
  return _ArtworkBlob(
    hash: hash,
    relative: relative.replaceAll('\\', '/'),
    regenerable: regenerable && aliases.isNotEmpty,
    leased: inUse,
    ownerIds: ownerIds.toSet().toList(),
    titles: titles.toSet().toList(),
    tags: tags,
  );
}

List<StorageAssetDescriptor> _cloudMaterialAssets(
  Directory root, {
  required List<StorageCloudOwnerHint> owners,
  required Set<String> protected,
  required List<String> warnings,
  List<String>? onlyPaths,
}) {
  final assets = <StorageAssetDescriptor>[];
  List<Directory> children;
  try {
    children = _selectedChildren(
      root,
      onlyPaths,
    ).whereType<Directory>().toList();
  } catch (error) {
    warnings.add('网盘素材目录无法列出：$error');
    return assets;
  }
  final protectedKeys = protected.map(storagePathKey).toSet();
  for (final directory in children) {
    final manifestFile = File(p.join(directory.path, 'manifest.json'));
    Map<String, dynamic>? manifest;
    if (manifestFile.existsSync()) {
      try {
        final decoded = jsonDecode(manifestFile.readAsStringSync());
        if (decoded is Map &&
            decoded['schema'] == 2 &&
            decoded['kind'] == 'cloudDrive') {
          manifest = Map<String, dynamic>.from(decoded);
        } else {
          warnings.add('网盘素材清单无法识别：${manifestFile.path}');
        }
      } catch (error) {
        warnings.add('网盘素材清单无法读取：${manifestFile.path}（$error）');
      }
    }
    final names = _files(
      directory,
    ).map((file) => p.basename(file.path)).toList();
    final sealedName = manifest?['path']?.toString();
    final sealedFile = sealedName == null
        ? null
        : File(p.join(directory.path, sealedName));
    final expected = manifest?['size'];
    final sealed =
        sealedFile != null &&
        sealedFile.existsSync() &&
        expected is int &&
        sealedFile.lengthSync() == expected;
    final busy = protectedKeys.contains(storagePathKey(directory.path));
    final matched = _matchCloudOwners(manifest, owners);
    final titles = matched
        .map((owner) => owner.title)
        .where((t) => t.isNotEmpty);
    final provider = manifest?['providerId']?.toString() ?? '';
    final quality = manifest?['qualityLabel']?.toString() ?? '';
    final title = titles.isEmpty
        ? [provider, quality].where((part) => part.isNotEmpty).join(' · ')
        : titles.join('、');
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'cloud-material:${storagePathKey(directory.path)}',
        origin: StorageOrigin.cloudDrive,
        sourceTags: const [StorageOrigin.cloudDrive],
        category: sealed
            ? StorageCategory.materialized
            : StorageCategory.downloadTemp,
        policy: busy
            ? StorageCleanupPolicy.protected
            : sealed
            ? StorageCleanupPolicy.regenerableCache
            : StorageCleanupPolicy.featureManaged,
        title: title.isEmpty ? '网盘素材' : title,
        directory: directory.path,
        protected: busy || manifest == null && names.isNotEmpty,
        deletable: !busy && sealed && manifest != null,
        explicitDelete: !busy && !sealed && manifest != null,
        cacheableResidue: !busy && sealed,
        role: sealed
            ? StorageAssetRole.assembledMedia
            : StorageAssetRole.resumePart,
        ownerIds: matched.map((owner) => owner.itemId).toSet().toList(),
        version: Object.hash(
          manifest?['revision'],
          manifest?['representation'],
          sealed,
          busy,
          names.length,
        ),
        protection: busy
            ? '素材正在下载、预览、转写、OCR 或合成'
            : manifest == null
            ? '素材清单缺失，暂不清理'
            : sealed
            ? null
            : '放弃续传才会删除未完成的网盘素材',
        detail: quality.isEmpty ? provider : '$provider · $quality',
      ),
    );
  }
  return assets;
}

List<StorageCloudOwnerHint> _matchCloudOwners(
  Map<String, dynamic>? manifest,
  List<StorageCloudOwnerHint> owners,
) {
  if (manifest == null) return const [];
  final provider = manifest['providerId']?.toString() ?? '';
  final account = manifest['remoteAccountId']?.toString() ?? '';
  final drive = manifest['driveId']?.toString() ?? '';
  final file = manifest['fileId']?.toString() ?? '';
  final itemId = manifest['itemId']?.toString() ?? '';
  return owners
      .where(
        (owner) =>
            owner.itemId == itemId ||
            (owner.providerId == provider &&
                owner.remoteAccountId == account &&
                owner.driveId == drive &&
                owner.fileId == file &&
                file.isNotEmpty),
      )
      .toList();
}

List<StorageAssetDescriptor> _cloudSubtitleAssets(
  Directory root, {
  required List<String> warnings,
  List<String>? onlyPaths,
}) {
  final assets = <StorageAssetDescriptor>[];
  // A selected stamp belongs to its subtitle body; no other subtitle needs
  // to be read or hashed during this cleanup.
  final bodies = onlyPaths
      ?.map(
        (path) => path.endsWith('.stamp')
            ? path.substring(0, path.length - '.stamp'.length)
            : path,
      )
      .toSet()
      .toList();
  for (final file in _files(root, onlyPaths: bodies)) {
    final name = p.basename(file.path).toLowerCase();
    if (name.endsWith('.stamp') || name.endsWith('.partial')) continue;
    final stamp = File('${file.path}.stamp');
    final fresh = _stampMatches(file, stamp);
    final saved = fresh != true;
    assets.add(
      StorageAssetDescriptor(
        assetKey: 'cloud-subtitle:${storagePathKey(file.path)}',
        origin: StorageOrigin.cloudDrive,
        sourceTags: const [StorageOrigin.cloudDrive],
        category: StorageCategory.subtitles,
        policy: saved
            ? StorageCleanupPolicy.savedContent
            : StorageCleanupPolicy.regenerableCache,
        title: '网盘外挂字幕副本',
        paths: [file.path, if (stamp.existsSync()) stamp.path],
        deletable: !saved,
        explicitDelete: saved,
        role: StorageAssetRole.subtitleBody,
        subtitleKind: saved && fresh == null
            ? StorageSubtitleKinds.unverified
            : StorageSubtitleKinds.cloudSidecar,
        protection: saved ? '校验戳缺失或不一致，按用户字幕成果保留' : null,
        detail: fresh == null ? '无法确认是否仍是远程原样副本' : null,
      ),
    );
  }
  return assets;
}

/// Null means the stamp could not be checked. Only a matching small text file
/// is treated as a refetchable remote copy.
bool? _stampMatches(File file, File stamp) {
  if (!stamp.existsSync()) return null;
  try {
    if (file.lengthSync() > 2 * 1024 * 1024) return null;
    final expected = stamp.readAsStringSync().trim().toLowerCase();
    if (expected.isEmpty) return null;
    final actual = sha256.convert(file.readAsBytesSync()).toString();
    return actual == expected;
  } catch (_) {
    return null;
  }
}

class _Record {
  _Record(this.kind, this.id, this.channel, this.payload);
  final String kind;
  final String id;
  final String channel;
  final Map<String, dynamic> payload;
}

List<_Record>? _readRows(File file, List<String> warnings, String label) {
  if (!file.existsSync()) return <_Record>[];
  Database? database;
  try {
    database = sqlite3.open(file.path, mode: OpenMode.readOnly);
    database.execute('PRAGMA query_only=ON');
    final version = database.select('PRAGMA user_version').first.values.first;
    if (version is! int || version > PodcastStore.schemaVersion) {
      warnings.add('$label 来自无法识别的版本，相关文件暂不可清理。');
      return null;
    }
    final table = database.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='records'",
    );
    if (table.isEmpty) {
      warnings.add('$label 没有记录表，不能把目录里的文件当成无引用缓存。');
      return null;
    }
    return database
        .select('SELECT kind, id, channel, payload FROM records')
        .map((row) {
          final decoded = jsonDecode(row['payload'] as String);
          return _Record(
            row['kind'].toString(),
            row['id'].toString(),
            row['channel']?.toString() ?? '',
            decoded is Map
                ? Map<String, dynamic>.from(decoded)
                : <String, dynamic>{},
          );
        })
        .toList();
  } catch (error) {
    warnings.add('$label 无法只读打开，相关文件暂不可清理：$error');
    return null;
  } finally {
    database?.dispose();
  }
}

Directory? _inspectionRoot(Directory? directory, List<String>? onlyPaths) {
  if (directory == null || onlyPaths == null) return directory;
  try {
    return Directory(directory.resolveSymbolicLinksSync());
  } on FileSystemException {
    return directory;
  }
}

bool _selectedDirectory(String directory, List<String>? onlyPaths) =>
    onlyPaths == null || onlyPaths.any((path) => _withinPath(directory, path));

/// Select direct children by path without enumerating unrelated cache folders.
List<FileSystemEntity> _selectedChildren(
  Directory directory,
  List<String>? onlyPaths,
) {
  if (onlyPaths == null) return directory.listSync(followLinks: false);
  final children = <String, FileSystemEntity>{};
  for (final path in onlyPaths) {
    if (!p.isWithin(storagePathKey(directory.path), storagePathKey(path))) {
      continue;
    }
    final first = p.split(p.relative(path, from: directory.path)).first;
    final child = p.join(directory.path, first);
    final type = FileSystemEntity.typeSync(child, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      children[storagePathKey(child)] = Directory(child);
    } else if (type == FileSystemEntityType.file) {
      children[storagePathKey(child)] = File(child);
    }
  }
  return children.values.toList();
}

List<File> _files(Directory directory, {List<String>? onlyPaths}) {
  if (onlyPaths != null) {
    return [
      for (final path in onlyPaths)
        if (_withinPath(directory.path, path) &&
            FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.file)
          File(path),
    ];
  }
  if (!directory.existsSync()) return const [];
  final files = <File>[];
  void walk(Directory current) {
    for (final entity in current.listSync(followLinks: false)) {
      if (entity is File) files.add(entity);
      if (entity is Directory) walk(entity);
    }
  }

  walk(directory);
  return files;
}

List<StorageRuntimeEntry> _registryEntries(
  Directory dataRoot,
  Directory? appDataRoot,
) {
  final files = [
    File(p.join(dataRoot.path, StorageRuntimeRegistry.fileName)),
    if (appDataRoot != null)
      File(p.join(appDataRoot.path, StorageRuntimeRegistry.fileName)),
  ];
  return [for (final file in files) ...StorageRuntimeRegistry.readFile(file)];
}

String _tokenKey(String path) => storagePathKey(path);

int _fileToken(File file) {
  if (!file.existsSync()) return 0;
  final stat = file.statSync();
  return stat.modified.microsecondsSinceEpoch ^ stat.size;
}

/// Updates indexes for files that were actually deleted. It does not delete
/// anything else and does not migrate a database.
Future<List<String>> correctDeletedStorageFiles({
  required Directory dataRoot,
  required List<String> deletedPaths,
  bool skipArtwork = false,
}) async {
  final warnings = <String>[];
  warnings.addAll(await _correctPodcast(dataRoot, deletedPaths));
  if (!skipArtwork) {
    warnings.addAll(await _correctArtwork(dataRoot, deletedPaths));
  }
  return warnings;
}

Future<List<String>> _correctPodcast(
  Directory dataRoot,
  List<String> deletedPaths,
) async {
  final root = Directory(p.join(dataRoot.path, 'podcasts'));
  final databaseFile = File(p.join(root.path, 'podcasts.sqlite'));
  if (!databaseFile.existsSync()) return const [];
  final mediaRoot = p.join(root.path, 'media');
  final touched = <String, Set<String>>{};
  for (final path in deletedPaths) {
    if (!_withinPath(mediaRoot, path)) continue;
    final relative = p.split(p.relative(path, from: mediaRoot));
    if (relative.length < 2) continue;
    touched.putIfAbsent(relative.first, () => {}).add(p.basename(path));
  }
  if (touched.isEmpty) return const [];
  Database? database;
  try {
    database = sqlite3.open(databaseFile.path);
    final version = database.select('PRAGMA user_version').first.values.first;
    if (version is! int || version > PodcastStore.schemaVersion) {
      return ['播客文件已删除，但数据库版本无法识别，索引未改。'];
    }
    database.execute('BEGIN IMMEDIATE');
    for (final entry in touched.entries) {
      final rows = database.select(
        "SELECT payload, channel FROM records WHERE kind='asset' AND id=?",
        [entry.key],
      );
      if (rows.isEmpty) continue;
      final payload = Map<String, dynamic>.from(
        jsonDecode(rows.first['payload'] as String) as Map,
      );
      final segments = Map<String, dynamic>.from(
        payload['segments'] as Map? ?? {},
      );
      final revision = payload['revision'] is int
          ? payload['revision'] as int
          : 0;
      var changed = false;
      for (final name in entry.value) {
        final segment = RegExp(r'^(\d+)-(\d+)\.seg$').firstMatch(name);
        if (segment != null && int.parse(segment.group(1)!) == revision) {
          segments.remove(segment.group(2));
          changed = true;
        }
        if (payload['assembled'] == name) {
          payload.remove('assembled');
          changed = true;
        }
      }
      if (!changed && payload['downloaded'] != true) continue;
      payload['segments'] = segments;
      payload['downloaded'] = false;
      database.execute(
        "UPDATE records SET payload=? WHERE kind='asset' AND id=?",
        [jsonEncode(payload), entry.key],
      );
      final episodeId = payload['episodeId']?.toString();
      if (episodeId == null) continue;
      final tasks = database.select(
        "SELECT payload, channel FROM records WHERE kind='download' AND id=?",
        [episodeId],
      );
      if (tasks.isEmpty) continue;
      final task = Map<String, dynamic>.from(
        jsonDecode(tasks.first['payload'] as String) as Map,
      );
      if (task['mediaUrl'] != payload['url']) continue;
      task['status'] = 'paused';
      task['automatic'] = false;
      task['received'] = 0;
      task['error'] = '已在存储管理中删除本地文件，不会自动重新下载';
      database.execute(
        "UPDATE records SET payload=? WHERE kind='download' AND id=?",
        [jsonEncode(task), episodeId],
      );
    }
    database.execute('COMMIT');
  } catch (error) {
    try {
      database?.execute('ROLLBACK');
    } catch (_) {}
    return ['播客文件已删除，索引校正失败：$error'];
  } finally {
    database?.dispose();
  }
  return const [];
}

Future<List<String>> _correctArtwork(
  Directory dataRoot,
  List<String> deletedPaths,
) async {
  final root = Directory(p.join(dataRoot.path, 'artwork'));
  final databaseFile = File(p.join(root.path, 'index.sqlite'));
  if (!databaseFile.existsSync()) return const [];
  final deleted = deletedPaths.map(storagePathKey).toSet();
  Database? database;
  try {
    database = sqlite3.open(databaseFile.path);
    final blobs = database.select('SELECT blob_hash, relative_path FROM blobs');
    final hashes = <String>[];
    for (final blob in blobs) {
      final relative = blob['relative_path'].toString();
      final absolute = storagePathKey(
        p.join(root.path, p.joinAll(relative.split('/'))),
      );
      if (deleted.contains(absolute)) hashes.add(blob['blob_hash'].toString());
    }
    if (hashes.isEmpty) return const [];
    database.execute('BEGIN IMMEDIATE');
    for (final hash in hashes) {
      database.execute('DELETE FROM palettes WHERE blob_hash=?', [hash]);
      database.execute('UPDATE aliases SET blob_hash=NULL WHERE blob_hash=?', [
        hash,
      ]);
      database.execute('DELETE FROM blobs WHERE blob_hash=?', [hash]);
    }
    database.execute('COMMIT');
  } catch (error) {
    try {
      database?.execute('ROLLBACK');
    } catch (_) {}
    return ['封面文件已删除，索引校正失败：$error'];
  } finally {
    database?.dispose();
  }
  return const [];
}

bool _withinPath(String root, String path) =>
    storagePathKey(root) == storagePathKey(path) ||
    p.isWithin(storagePathKey(root), storagePathKey(path));

/// Temporary-file dialog shares the same protection rules, limited to residue.
Future<TemporaryStorageCategoryReport> inspectFeatureTemporaryFiles({
  required Directory dataRoot,
  Directory? systemTemp,
}) async {
  final inspection = inspectStorageFeatures(
    dataRoot: dataRoot,
    systemTemp: systemTemp,
  );
  final snapshot = await scanStorageFiles(
    StorageScanInput(
      roots: [
        StorageRoot(dataRoot.path, '媒体库数据', StorageRootKind.data),
        ...inspection.roots,
      ],
      assets: inspection.assets,
      verifiedPaths: inspection.verifiedPaths,
      warnings: inspection.warnings,
      minimumTemporaryAge: const Duration(minutes: 10),
    ),
  );
  final files = snapshot.files.where(_featureTempFile).toList();
  final bytes = files.fold<int>(0, (sum, file) => sum + file.bytes);
  return TemporaryStorageCategoryReport(
    id: 'feature-residue',
    title: '播客与网盘临时残留',
    description: '只包含已失去租约的写入残留、登录崩溃目录和封存后的续传碎片。离线节目、字幕成果和仍可恢复的下载不在这里。',
    fileCount: files.length,
    totalBytes: bytes,
    canClean: files.isNotEmpty,
    note: files.isEmpty
        ? '没有可安全清理的播客或网盘临时残留。完整缓存、离线下载和字幕请到存储空间管理。'
        : '不会清理离线下载、已保存字幕或仍可续传的数据。',
  );
}

Future<int> clearFeatureTemporaryFiles({
  required Directory dataRoot,
  Directory? systemTemp,
}) async {
  final inspection = inspectStorageFeatures(
    dataRoot: dataRoot,
    systemTemp: systemTemp,
  );
  final snapshot = await scanStorageFiles(
    StorageScanInput(
      roots: [
        StorageRoot(dataRoot.path, '媒体库数据', StorageRootKind.data),
        ...inspection.roots,
      ],
      assets: inspection.assets,
      verifiedPaths: inspection.verifiedPaths,
      minimumTemporaryAge: const Duration(minutes: 10),
    ),
  );
  var released = 0;
  for (final file in snapshot.files.where(_featureTempFile)) {
    try {
      final current = File(file.path);
      if (!await current.exists()) continue;
      final stat = await current.stat();
      if (stat.size != file.bytes) continue;
      await current.delete();
      released += stat.size;
    } catch (_) {
      /* A locked residue stays for the next storage scan. */
    }
  }
  return released;
}

bool _featureTempFile(StorageFileEntry file) {
  if (!file.canDelete || file.external) return false;
  if (file.cleanupPolicy != StorageCleanupPolicy.regenerableCache) return false;
  return file.role == StorageAssetRole.resumePart ||
      file.role == StorageAssetRole.partialCommit ||
      file.role == StorageAssetRole.loginProfile ||
      file.role == StorageAssetRole.artworkStaging;
}
