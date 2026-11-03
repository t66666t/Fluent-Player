import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../platform/linux_application_identity.dart';

enum StoragePlatform { windows, macos, linux, android, ios }

class StorageUnavailableException implements Exception {
  const StorageUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StorageSelectionRequiredException extends StorageUnavailableException {
  StorageSelectionRequiredException(this.directories)
    : super('发现多个历史媒体库，请选择要继续使用的数据目录。原文件不会合并或删除。');
  final List<Directory> directories;
}

/// Additive to legacy absolute-path fields. Only owned local files get a ref.
class StoragePathRef {
  const StoragePathRef(this.rootId, this.relativePath);
  final String rootId;
  final String relativePath;
  Map<String, dynamic> toJson() => {
    'rootId': rootId,
    'relativePath': relativePath,
  };
  static StoragePathRef? fromJson(Object? value) {
    if (value is! Map ||
        value['rootId'] is! String ||
        value['relativePath'] is! String) {
      return null;
    }
    final relative = value['relativePath'] as String;
    if (p.posix.isAbsolute(relative) ||
        p.windows.isAbsolute(relative) ||
        relative.split(RegExp(r'[/\\]')).contains('..')) {
      return null;
    }
    return StoragePathRef(value['rootId'] as String, relative);
  }
}

/// All locations are supplied by the OS. The injectable constructor is also
/// used by upgrade tests; it never reads a developer's real library.
class StorageLocations {
  const StorageLocations({
    required this.platform,
    required this.support,
    required this.documents,
    required this.defaultData,
    required this.executable,
    this.cache,
    this.historical = const [],
  });
  final StoragePlatform platform;
  final Directory support, documents, defaultData, executable;
  final Directory? cache;
  final List<Directory> historical;

  static Future<StorageLocations> system() async {
    final platform = Platform.isWindows
        ? StoragePlatform.windows
        : Platform.isMacOS
        ? StoragePlatform.macos
        : Platform.isLinux
        ? StoragePlatform.linux
        : Platform.isAndroid
        ? StoragePlatform.android
        : StoragePlatform.ios;
    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      if (!Platform.isLinux) rethrow;
      final env = Platform.environment;
      final xdg = env['XDG_DATA_HOME'];
      final home = env['HOME'];
      if (xdg != null && p.isAbsolute(xdg)) {
        support = Directory(p.join(xdg, linuxApplicationId));
      } else if (home != null && p.isAbsolute(home)) {
        support = Directory(
          p.join(home, '.local', 'share', linuxApplicationId),
        );
      } else {
        throw const StorageUnavailableException('无法确定应用持久目录');
      }
    }
    Directory documents;
    try {
      documents = await getApplicationDocumentsDirectory();
    } catch (_) {
      documents = support;
    }
    var defaultData = support;
    if (platform == StoragePlatform.windows) {
      // Native Known Folder lookup, independent of executable/display name.
      final local = await const MethodChannel(
        'com.example.video_player_app/yt_dlp',
      ).invokeMethod<String>('getLocalAppDataPath');
      if (local == null || !p.isAbsolute(local)) {
        throw const StorageUnavailableException('无法读取 Windows 本地应用数据目录');
      }
      defaultData = Directory(p.join(local, 'FluentPlayerCommunity', 'CommunityPlayerData'));
    }
    Directory? cache;
    try {
      cache = await getTemporaryDirectory();
    } catch (_) {
      /* optional */
    }
    final historical = <Directory>[];
    if (platform == StoragePlatform.linux) {
      final env = Platform.environment;
      final home = env['HOME'];
      final xdg = env['XDG_DATA_HOME'];
      final base = xdg != null && p.isAbsolute(xdg)
          ? xdg
          : home == null
          ? null
          : p.join(home, '.local', 'share');
      if (base != null) {
        for (final name in linuxLegacyApplicationIds) {
          historical.add(Directory(p.join(base, name)));
        }
        // An old catalog is authoritative even after the GTK application ID
        // changes. Keep it in place instead of creating an empty replacement.
        Future<bool> hasCatalog(Directory directory) async =>
            await File(
              p.join(directory.path, 'storage/layout.json'),
            ).exists() ||
            await File(
              p.join(directory.path, 'storage/layout.json.bak'),
            ).exists();
        if (!await hasCatalog(support)) {
          for (final legacy in historical) {
            if (await hasCatalog(legacy)) {
              support = legacy;
              break;
            }
          }
        }
      }
    }
    return StorageLocations(
      platform: platform,
      support: support,
      documents: documents,
      defaultData: defaultData,
      cache: cache,
      executable: File(Platform.resolvedExecutable).parent,
      historical: historical,
    );
  }
}

Future<void> writeStorageJson(File file, Object value) async {
  await file.parent.create(recursive: true);
  final next = File('${file.path}.next');
  final previous = File('${file.path}.bak');
  await next.writeAsString(jsonEncode(value), flush: true);
  if (await file.exists()) {
    try {
      jsonDecode(await file.readAsString());
      await file.copy(previous.path);
    } on FormatException {
      /* keep the last readable backup */
    }
  }
  try {
    await next.rename(file.path);
  } on FileSystemException {
    // The last good generation remains recoverable on Windows.
    if (await file.exists()) await file.delete();
    await next.rename(file.path);
  }
}

Future<dynamic> readStorageJson(File file) async {
  var found = false;
  for (final candidate in [file, File('${file.path}.bak')]) {
    if (!await candidate.exists()) continue;
    found = true;
    try {
      return jsonDecode(await candidate.readAsString());
    } on FormatException {
      /* try the previous complete generation */
    }
  }
  if (found) throw StorageUnavailableException('记录和备份无法读取，已保留：${file.path}');
  return null;
}

/// Only path metadata crosses the isolate boundary, never live storage futures
/// or a locations provider that may capture plugin/test state.
class StoragePathEncodingSnapshot {
  StoragePathEncodingSnapshot._(AppStorageService storage)
    : _locations = storage._locations,
      _roots = Map.of(storage.roots),
      _aliases = Map.of(storage.aliases);

  final StorageLocations? _locations;
  final Map<String, Directory> _roots;
  final Map<String, String> _aliases;

  dynamic encodePaths(dynamic value) {
    return _storage().encodePaths(value);
  }

  dynamic decodePaths(dynamic value) => _storage().decodePaths(value);

  /// Only for newly decoded JSON owned by a worker. Avoids retaining a second
  /// complete catalog tree while building its model objects.
  dynamic decodeOwnedJsonPaths(dynamic value) =>
      _storage()._decodeOwnedJsonPaths(value);

  AppStorageService _storage() => AppStorageService()
    .._locations = _locations
    ..roots.addAll(_roots)
    ..aliases.addAll(_aliases);
}

class AppStorageService {
  AppStorageService({Future<StorageLocations> Function()? locations})
    : _locationsProvider = locations ?? StorageLocations.system;
  static AppStorageService instance = AppStorageService();
  final Future<StorageLocations> Function() _locationsProvider;
  Future<void>? _initializing;
  StorageLocations? _locations;
  Directory? _data, _metadata;
  bool get isReady => _data != null;
  bool _unsafeDataRoot(String path) {
    final executable = _locations!.executable.path;
    if (samePath(executable, path) || p.isWithin(executable, path)) return true;
    final segments = p.split(executable);
    for (var i = 0; i + 1 < segments.length; i++) {
      if (segments[i].toLowerCase() == 'build' &&
          {
            'windows',
            'linux',
            'macos',
          }.contains(segments[i + 1].toLowerCase())) {
        final output = p.joinAll(segments.take(i + 1));
        if (samePath(output, path) || p.isWithin(output, path)) return true;
      }
    }
    return _locations!.platform == StoragePlatform.macos &&
        p.split(path).any((part) => part.toLowerCase().endsWith('.app'));
  }

  bool get requiresBootstrapRelocation =>
      isReady && desktop && _unsafeDataRoot(dataDirectory.path);

  bool get desktop =>
      _locations?.platform == StoragePlatform.windows ||
      _locations?.platform == StoragePlatform.macos ||
      _locations?.platform == StoragePlatform.linux;
  Directory get dataDirectory =>
      _data ?? (throw const StorageUnavailableException('存储尚未就绪'));
  Directory get metadataDirectory => _metadata ?? dataDirectory;
  Directory get controlDirectory =>
      Directory(p.join(_locations!.support.path, 'storage'));
  final Map<String, Directory> roots = {};
  final Map<String, String> aliases = {};
  final List<Directory> legacyRoots = [];
  final Map<String, String> _stores = {};
  final List<String> warnings = [];
  bool readOnlyCatalog = false;
  bool _expectLibrary = false;
  Future<void> noteLibraryPersisted() async {
    if (!isReady || _expectLibrary) return;
    _expectLibrary = true;
    try {
      await _saveCatalog();
    } catch (_) {
      _expectLibrary = false;
      rethrow;
    }
  }

  Future<void> _catalogTail = Future<void>.value();
  Map<String, String> get registeredStores => Map.unmodifiable(_stores);
  void resetForRetry() {
    _data = null;
    _metadata = null;
    _initializing = null;
    roots.clear();
    aliases.clear();
    _stores.clear();
    legacyRoots.clear();
    warnings.clear();
    _expectLibrary = false;
  }

  Future<void> recoverWithRoot(Directory root) async {
    if (!await root.exists()) throw const StorageUnavailableException('目录不存在');
    if (!await File(p.join(root.path, 'library.json')).exists() &&
        !await File(p.join(root.path, 'library.json.bak')).exists()) {
      throw const StorageUnavailableException('所选目录没有媒体库索引，请选择原有的数据目录');
    }
    _locations ??= await _locationsProvider();
    final recoveredLibrary = await readStorageJson(
      File(p.join(root.path, 'library.json')),
    );
    if (recoveredLibrary is! Map) {
      throw const StorageUnavailableException('所选目录的媒体库索引无法读取，原文件已保留');
    }
    await _probeWritable(root);
    final file = File(p.join(controlDirectory.path, 'layout.json'));
    if (await file.exists()) {
      await file.copy(
        '${file.path}.recovery-${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    await writeStorageJson(file, {
      'version': 1,
      'dataRoot': root.path,
      'metadataRoot': _locations!.platform == StoragePlatform.linux
          ? root.path
          : (_metadata?.path ?? _locations!.documents.path),
    });
    await (await SharedPreferences.getInstance()).setString(
      'largeDataRootPath',
      root.path,
    );
    roots.clear();
    aliases.clear();
    _stores.clear();
    resetForRetry();
    await initialize(configuredRoot: root.path);
  }

  Future<Directory> featureDirectory(String name, {String? marker}) async {
    if (!ownedNames.contains(name)) throw ArgumentError.value(name);
    final remembered = roots['feature:$name'];
    if (remembered != null) {
      if (!await remembered.exists()) {
        throw StorageUnavailableException('历史数据目录不可用：${remembered.path}');
      }
      return remembered;
    }
    final root = await resolveDataRoot();
    for (final base in [root, ...legacyRoots]) {
      final dir = Directory(p.join(base.path, name));
      if (await dir.exists() &&
          (marker == null || await File(p.join(dir.path, marker)).exists())) {
        roots['feature:$name'] = dir;
        if (isReady) await _saveCatalog();
        return dir;
      }
    }
    final dir = Directory(p.join(root.path, name));
    await dir.create(recursive: true);
    roots['feature:$name'] = dir;
    if (isReady) await _saveCatalog();
    return dir;
  }

  Future<File> dataRecord(String name) async {
    if (!ownedNames.contains(name) || p.basename(name) != name) {
      throw ArgumentError.value(name);
    }
    final key = 'data/$name';
    if (_stores[key] != null) return File(restorePath(_stores[key]!));
    final root = await resolveDataRoot();
    var file = File(p.join(root.path, name));
    for (final base in [root, ...legacyRoots]) {
      final candidate = File(p.join(base.path, name));
      if (await candidate.exists()) {
        file = candidate;
        break;
      }
    }
    _stores[key] = file.path;
    if (isReady) await _saveCatalog();
    return file;
  }

  RandomAccessFile? _foregroundLease;
  bool get hasForegroundLease => _foregroundLease != null;
  Future<void> acquireForegroundLease() async {
    if (_foregroundLease != null) return;
    _locations ??= await _locationsProvider();
    await controlDirectory.create(recursive: true);
    final handle = await File(
      p.join(controlDirectory.path, 'migration.lock'),
    ).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.shared);
      _foregroundLease = handle;
    } catch (_) {
      await handle.close();
      throw const StorageUnavailableException('数据目录正在迁移，请稍后重试');
    }
  }

  Future<void> releaseForegroundLease() async {
    final handle = _foregroundLease;
    _foregroundLease = null;
    if (handle != null) await handle.close();
  }

  Future<void> initialize({
    String? configuredRoot,
    bool holdLease = false,
  }) async {
    if (holdLease) await acquireForegroundLease();
    try {
      await (_initializing ??= _initialize(configuredRoot));
    } catch (_) {
      await releaseForegroundLease();
      resetForRetry();
      rethrow;
    }
  }

  Future<T> withBackgroundLease<T>(Future<T> Function() action) async {
    _locations ??= await _locationsProvider();
    await controlDirectory.create(recursive: true);
    final handle = await File(
      p.join(controlDirectory.path, 'migration.lock'),
    ).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.shared);
      readOnlyCatalog = true;
      resetForRetry();
      await initialize();
      return await action();
    } finally {
      await handle.close();
    }
  }

  Future<void> _initialize(String? configuredRoot) async {
    final locations = _locations ??= await _locationsProvider();
    await locations.support.create(recursive: true);
    final catalog = File(p.join(controlDirectory.path, 'layout.json'));
    Map? saved;
    if (await catalog.exists() || await File('${catalog.path}.bak').exists()) {
      for (final candidate in [catalog, File('${catalog.path}.bak')]) {
        try {
          final value = jsonDecode(await candidate.readAsString());
          if (value is Map &&
              value['version'] == 1 &&
              value['dataRoot'] is String) {
            saved = value;
            break;
          }
        } catch (_) {
          /* use the last good catalog */
        }
      }
      if (saved == null) {
        throw const StorageUnavailableException('存储登记损坏，已保留原数据，请恢复目录登记');
      }
    }
    legacyRoots.clear();
    for (final candidate in [
      if (configuredRoot?.isNotEmpty == true) Directory(configuredRoot!),
      Directory(p.join(locations.executable.path, 'CommunityPlayerData')),
      locations.support,
      ...locations.historical,
    ]) {
      if (!legacyRoots.any((e) => samePath(e.path, candidate.path))) {
        legacyRoots.add(candidate);
      }
    }
    if (saved?['roots'] is Map) {
      for (final e in (saved!['roots'] as Map).entries) {
        if (e.value is String) {
          roots['${e.key}'] = Directory(_rebaseContainer(e.value as String));
        }
      }
    }
    if (saved?['aliases'] is Map) {
      for (final e in (saved!['aliases'] as Map).entries) {
        if (e.value is String) {
          aliases['${e.key}'] = _rebaseContainer(e.value as String);
        }
      }
    }
    if (saved?['stores'] is Map) {
      for (final e in (saved!['stores'] as Map).entries) {
        if (e.value is String) {
          _stores['${e.key}'] = _rebaseContainer(e.value as String);
        }
      }
    }
    final candidates = <Directory>[];
    for (final root in legacyRoots) {
      if (await File(p.join(root.path, 'library.json')).exists() ||
          await File(p.join(root.path, 'library.json.bak')).exists()) {
        candidates.add(root);
      }
    }
    final remembered = saved?['dataRoot'] as String?;
    final explicit = configuredRoot?.trim();
    Directory selected;
    if (remembered != null) {
      selected = Directory(_rebaseContainer(remembered));
      if (!await selected.exists()) {
        throw StorageUnavailableException('数据目录暂不可用：${selected.path}；已暂停写入');
      }
    } else if (explicit?.isNotEmpty == true) {
      selected = Directory(explicit!);
      if (!await selected.exists()) {
        throw StorageUnavailableException('已配置的数据目录暂不可用：$explicit；请重新连接磁盘');
      }
    } else if (candidates.length > 1) {
      // Do not pick by mtime or merge unrelated user libraries.
      throw StorageSelectionRequiredException(List.unmodifiable(candidates));
    } else {
      selected = candidates.isEmpty ? locations.defaultData : candidates.single;
      await selected.create(recursive: true);
    }
    final hasLibrary =
        await File(p.join(selected.path, 'library.json')).exists() ||
        await File(p.join(selected.path, 'library.json.bak')).exists();
    _expectLibrary = saved?['expectLibrary'] == true || hasLibrary;
    if (saved?['expectLibrary'] == true && !hasLibrary) {
      throw const StorageUnavailableException('媒体库索引缺失，已暂停写入；请恢复备份或选择原目录');
    }
    await _probeWritable(selected);
    _data = selected;
    roots['data'] = selected;
    roots['documents'] = locations.documents;
    roots['support'] = locations.support;
    if (locations.cache != null) roots['legacyCache'] = locations.cache!;
    final rememberedMetadata = saved?['metadataRoot'] as String?;
    _metadata = rememberedMetadata == null
        ? locations.support
        : Directory(_rebaseContainer(rememberedMetadata));
    if (rememberedMetadata == null) {
      final historicalMetadata = locations.platform == StoragePlatform.linux
          ? selected
          : locations.documents;
      for (final name in [
        'library.json',
        '.bilibili_cookies',
        'yt_dlp_cookies',
        'bilibili_download_tasks.json',
        'compose_tasks.json',
        'transcription_slice_checkpoints.json',
        'batch_import_cache',
        'batch_import_cache.json',
        'transcription_queue_cache.json',
        'video_player_app',
      ]) {
        if (await FileSystemEntity.type(
              p.join(historicalMetadata.path, name),
            ) !=
            FileSystemEntityType.notFound) {
          _metadata = historicalMetadata;
          break;
        }
      }
    }
    if (!await _metadata!.exists()) {
      throw const StorageUnavailableException('历史任务记录目录暂不可用');
    }
    roots['metadata'] = _metadata!;
    for (var i = 0; i < legacyRoots.length; i++) {
      roots.putIfAbsent('legacy$i', () => legacyRoots[i]);
    }
    await downloadRecord(
      'web',
      'index.json',
      'web_media_downloads',
      legacyRelative: 'queue_v2/index.json',
    );
    await downloadRecord('douyin', 'tasks.json', 'douyin_downloads');
    await _saveCatalog();
  }

  String _rebaseContainer(String path) {
    if (_locations?.platform != StoragePlatform.ios) return path;
    // iOS may replace the container UUID on update/restore. Match directory
    // boundaries, never an arbitrary basename or a file outside our container.
    for (final marker in [
      '/Documents/',
      '/Library/Application Support/',
      '/Library/Caches/',
    ]) {
      final suffix = marker.substring(0, marker.length - 1);
      final at = path.contains(marker)
          ? path.indexOf(marker)
          : path.endsWith(suffix)
          ? path.length - suffix.length
          : -1;
      if (at < 0 || !path.substring(0, at).contains('/Application/')) continue;
      final base = marker == '/Documents/'
          ? _locations!.documents.path
          : marker == '/Library/Application Support/'
          ? _locations!.support.path
          : _locations!.cache?.path;
      if (base != null) {
        return path.length == at + marker.length - 1
            ? base
            : p.join(base, path.substring(at + marker.length));
      }
    }
    return path;
  }

  Future<Directory> resolveDataRoot({String? configuredRoot}) async {
    if (isReady) return dataDirectory;
    // Standalone services/tests may explicitly supply a root before app startup.
    if (configuredRoot?.trim().isNotEmpty == true) {
      final root = Directory(configuredRoot!);
      await root.create(recursive: true);
      return root;
    }
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs.getString('largeDataRootPath');
    if (configured?.isNotEmpty == true) {
      return resolveDataRoot(configuredRoot: configured);
    }
    final locations = _locations ??= await _locationsProvider();
    final root = locations.defaultData;
    await root.create(recursive: true);
    return root;
  }

  Future<Directory> defaultDataDirectory() async =>
      (_locations ??= await _locationsProvider()).defaultData;
  Future<Directory> downloadFiles(String source) async {
    _validateSource(source);
    final root = await resolveDataRoot();
    final dir = Directory(p.join(root.path, 'downloads', source, 'files'));
    await dir.create(recursive: true);
    if (Platform.isIOS) await _excludeDownloadFromBackup(dir);
    return dir;
  }

  Future<Directory> downloadTasks(String source) async {
    _validateSource(source);
    final root = await resolveDataRoot();
    final dir = Directory(p.join(root.path, 'downloads', source, 'tasks'));
    await dir.create(recursive: true);
    if (Platform.isIOS) await _excludeDownloadFromBackup(dir);
    return dir;
  }

  /// Promote a known resumable artifact, retaining the original until its
  /// owning task explicitly cleans it up. Never overwrite a different file.
  Future<File> retainTaskFile(File source, Directory directory) async {
    if (p.isWithin(directory.path, source.path) || !await source.exists()) {
      return source;
    }
    if (await FileSystemEntity.type(source.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const StorageUnavailableException('续传文件不能经过链接');
    }
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, p.basename(source.path)));
    Future<String> digest(File file) async =>
        (await sha256.bind(file.openRead()).first).toString();
    final hash = await digest(source);
    if (await target.exists()) {
      if (await digest(target) != hash) {
        throw const StorageUnavailableException('续传文件存在冲突，已保留两边的数据');
      }
      return target;
    }
    final partial = File('${target.path}.promoting');
    await source.copy(partial.path);
    final copied = await partial.open(mode: FileMode.append);
    try {
      await copied.flush();
    } finally {
      await copied.close();
    }
    if (await digest(partial) != hash || await digest(source) != hash) {
      throw const StorageUnavailableException('续传文件校验失败，原文件已保留');
    }
    return partial.rename(target.path);
  }

  Future<void> _excludeDownloadFromBackup(Directory dir) async {
    await const MethodChannel(
      'com.example.video_player_app/storage_paths',
    ).invokeMethod<void>('excludeFromBackup', {'path': dir.path});
  }

  Future<Directory> importedMediaDirectory({Directory? dataRoot}) async {
    final base = _locations?.platform == StoragePlatform.ios
        ? _locations!.documents
        : dataRoot ?? await resolveDataRoot();
    final dir = Directory(p.join(base.path, 'imported_media'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> exportDirectory() async {
    final base = Platform.isIOS
        ? await getApplicationDocumentsDirectory()
        : await resolveDataRoot();
    final dir = Directory(p.join(base.path, 'exports', 'composed'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Reuse the actual old record, while new file output uses the new layout.
  Future<File> downloadRecord(
    String source,
    String fileName,
    String legacyFolder, {
    String? legacyRelative,
  }) async {
    final key = '$source/$fileName';
    final stored = _stores[key];
    if (stored != null) return File(restorePath(stored));
    final rootsToCheck = <Directory>[
      await resolveDataRoot(),
      ...legacyRoots,
      if (_locations != null) _locations!.documents,
      if (_locations == null) await getApplicationDocumentsDirectory(),
    ];
    for (final root in rootsToCheck) {
      final file = File(
        p.joinAll([
          root.path,
          legacyFolder,
          ...(legacyRelative ?? fileName).split('/'),
        ]),
      );
      if (await file.exists() || await File('${file.path}.bak').exists()) {
        _stores[key] = file.path;
        if (isReady) await _saveCatalog();
        return file;
      }
    }
    final file = File(p.join((await downloadTasks(source)).path, fileName));
    _stores[key] = file.path;
    if (isReady) await _saveCatalog();
    return file;
  }

  StoragePathRef? reference(String path) {
    if (!p.isAbsolute(path)) return null;
    final entries = roots.entries.toList()
      ..sort((a, b) {
        final length = b.value.path.length.compareTo(a.value.path.length);
        if (length != 0) return length;
        return (a.key == 'data' ? 0 : 1).compareTo(b.key == 'data' ? 0 : 1);
      });
    for (final e in entries) {
      final rootPath = restorePath(e.value.path);
      if (samePath(rootPath, path) || p.isWithin(rootPath, path)) {
        // Desktop Documents is shared. A location alone is not ownership.
        if ((e.key == 'documents' ||
                e.key.startsWith('legacy') ||
                samePath(e.value.path, _locations?.documents.path ?? '')) &&
            desktop &&
            !_knownOwnedRelative(p.relative(path, from: e.value.path))) {
          continue;
        }
        return StoragePathRef(
          e.key,
          p.posix.joinAll(p.split(p.relative(path, from: rootPath))),
        );
      }
    }
    return null;
  }

  String _applyAliases(String value) {
    final pairs = aliases.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    final visited = <String>{};
    while (visited.add(value)) {
      String? next;
      for (final entry in pairs) {
        if (samePath(entry.key, value) || p.isWithin(entry.key, value)) {
          next = p.normalize(
            p.join(entry.value, p.relative(value, from: entry.key)),
          );
          break;
        }
      }
      if (next == null || samePath(value, next)) return value;
      value = next;
    }
    throw const StorageUnavailableException('历史路径登记存在循环，已暂停写入');
  }

  String restorePath(String path, [StoragePathRef? ref]) {
    final mapped = _applyAliases(path);
    if (!samePath(mapped, path)) return mapped;
    if (ref != null && roots[ref.rootId] != null) {
      path = p.joinAll([
        roots[ref.rootId]!.path,
        ...ref.relativePath.split('/'),
      ]);
    }
    return _rebaseContainer(_applyAliases(path));
  }

  /// A schema-aware walk: only declared local path fields/maps are handled.
  /// URLs, titles, remote file IDs and arbitrary text are deliberately excluded.
  dynamic encodePaths(dynamic value) => _mapPaths(value, true);
  dynamic decodePaths(dynamic value) => _mapPaths(value, false);

  StoragePathEncodingSnapshot capturePathEncoding() =>
      StoragePathEncodingSnapshot._(this);

  dynamic _decodeOwnedJsonPaths(dynamic value) {
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        value[i] = _decodeOwnedJsonPaths(value[i]);
      }
      return value;
    }
    if (value is! Map<String, dynamic>) {
      return value is Map ? decodePaths(value) : value;
    }
    final savedRefs = value['_storagePaths'] is Map
        ? value['_storagePaths'] as Map
        : const {};
    for (final key in value.keys) {
      if (key == '_storagePaths' || key == 'sourceRef') continue;
      final item = value[key];
      if (_pathFields.contains(key) && item is String && p.isAbsolute(item)) {
        value[key] = restorePath(item, StoragePathRef.fromJson(savedRefs[key]));
      } else if (_pathMaps.contains(key) && item is Map<String, dynamic>) {
        for (final name in item.keys) {
          final path = item[name];
          item[name] = path is String && p.isAbsolute(path)
              ? restorePath(
                  path,
                  StoragePathRef.fromJson(savedRefs['$key/$name']),
                )
              : _decodeOwnedJsonPaths(path);
        }
      } else if (_pathLists.contains(key) && item is List) {
        for (var i = 0; i < item.length; i++) {
          final path = item[i];
          if (path is String && p.isAbsolute(path)) {
            item[i] = restorePath(
              path,
              StoragePathRef.fromJson(savedRefs['$key/$i']),
            );
          }
        }
      } else {
        value[key] = _decodeOwnedJsonPaths(item);
      }
    }
    return value;
  }

  dynamic _mapPaths(dynamic value, bool encode, [String? field]) {
    if (value is List) {
      return value.map((e) => _mapPaths(e, encode, field)).toList();
    }
    if (value is! Map) return value;
    final map = Map<String, dynamic>.from(value);
    final refs = <String, dynamic>{};
    final savedRefs = map['_storagePaths'] is Map
        ? map['_storagePaths'] as Map
        : const {};
    for (final key in map.keys.toList()) {
      if (key == '_storagePaths' || key == 'sourceRef') continue;
      final item = map[key];
      if (_pathFields.contains(key) && item is String && p.isAbsolute(item)) {
        if (encode) {
          final ref = reference(item);
          if (ref != null) refs[key] = ref.toJson();
        } else {
          map[key] = restorePath(item, StoragePathRef.fromJson(savedRefs[key]));
        }
      } else if (_pathMaps.contains(key) && item is Map) {
        final mapped = <String, dynamic>{};
        for (final e in item.entries) {
          if (e.value is String && p.isAbsolute(e.value as String)) {
            final name = '$key/${e.key}';
            if (encode) {
              mapped['${e.key}'] = e.value;
              final ref = reference(e.value as String);
              if (ref != null) refs[name] = ref.toJson();
            } else {
              mapped['${e.key}'] = restorePath(
                e.value as String,
                StoragePathRef.fromJson(savedRefs[name]),
              );
            }
          } else {
            mapped['${e.key}'] = _mapPaths(e.value, encode);
          }
        }
        map[key] = mapped;
      } else if (_pathLists.contains(key) && item is List) {
        map[key] = [
          for (var i = 0; i < item.length; i++)
            if (item[i] is String && p.isAbsolute(item[i] as String))
              encode
                  ? item[i]
                  : restorePath(
                      item[i] as String,
                      StoragePathRef.fromJson(savedRefs['$key/$i']),
                    )
            else
              item[i],
        ];
        if (encode) {
          for (var i = 0; i < item.length; i++) {
            final ref = item[i] is String ? reference(item[i] as String) : null;
            if (ref != null) refs['$key/$i'] = ref.toJson();
          }
        }
      } else {
        map[key] = _mapPaths(item, encode, key);
      }
    }
    if (encode && refs.isNotEmpty) map['_storagePaths'] = refs;
    return map;
  }

  static const _pathFields = {
    'path',
    'file',
    'output',
    'outputPath',
    'importedOutputPath',
    'thumbnailPath',
    'subtitlePath',
    'secondarySubtitlePath',
    'danmakuPath',
    'playbackPath',
    'bilibiliDownloadPath',
    'wordTimingPath',
    'tempPath',
    'directory',
    'partial',
    'completedOutput',
    'localPath',
    'audioPath',
    'videoPath',
    'sourcePath',
    'targetPath',
    'materialPath',
    'coverPath',
    'outputDir',
    'outputDirectory',
    'workDirectory',
    'preparedFile',
    'legacyPath',
    'thumbnail',
    'cookiesFilePath',
    'taskThumbnailPath',
    'spritePath',
    'primarySubtitlePath',
    'resultSrtPath',
    'translatedSrtPath',
    'transcriptPath',
  };
  static const _pathMaps = {
    'additionalSubtitles',
    'extraSubtitles',
    'localSubtitles',
    'completedTracks',
    'recycledAdditionalSubtitles',
    'recycledExtraSubtitles',
    'recycledLocalSubtitles',
  };
  static const _pathLists = {
    'selectedSubtitlePaths',
    'recycledSelectedSubtitlePaths',
    'cleanupFiles',
    'outputPaths',
    'producedPaths',
    'spritePaths',
  };
  static const ownedNames = {
    'media_cache.json',
    'media_cache.json.bak',
    'media_cache.json.next',
    'library.json',
    'library.json.bak',
    'library.json.tmp',
    'bilibili_watch_playlist.json',
    'bilibili_download_tasks.json',
    'compose_tasks.json',
    'transcription_slice_checkpoints.json',
    'transcription_queue_cache.json',
    'transient_cards.json',
    'batch_import_state.json',
    'batch_import_cache.json',
    'storage_runtime_registry.json',
    'downloads',
    'imported_videos',
    'imported_media',
    'podcasts',
    'artwork',
    'cloud_drive_material',
    'cloud_drive_subtitles',
    'cloud_drive_accounts.json',
    'thumbnails',
    'subtitles',
    'danmaku',
    'bilibili_stream_cache',
    'bilibili_videoshots',
    'chapter_thumbnails',
    'compatible_audio',
    'douyin_downloads',
    'web_media_downloads',
    'yt_dlp_downloads',
    'yt_dlp_cookies',
    'yt_dlp_task_thumbnails',
    'imported_archives',
    'ocr_models',
    'local_models',
    'model_center.json',
    'model_jobs',
    'ocr_temp',
    'portable_transfer',
    'exports',
    'video_player_app',
    'batch_import_cache',
  };
  static bool _knownOwnedRelative(String relative) =>
      ownedNames.contains(p.split(relative).firstOrNull);
  bool owns(String path) => reference(path) != null;
  static bool samePath(String a, String b) => Platform.isWindows
      ? p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase()
      : p.equals(a, b);
  static void _validateSource(String source) {
    if (!const {
      'web',
      'bilibili',
      'douyin',
      'yt_dlp',
      'cloud_drive',
    }.contains(source)) {
      throw ArgumentError.value(source);
    }
  }

  static Future<void> _probeWritable(Directory dir) async {
    final probe = File(
      p.join(
        dir.path,
        '.storage-probe-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('', flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
  }

  Future<void> validateNewRoot(
    Directory target, {
    bool resumeOwnedTarget = false,
  }) async {
    if (!desktop) throw const StorageUnavailableException('移动端使用系统管理的应用目录');
    if (!p.isAbsolute(target.path)) {
      throw const StorageUnavailableException('请选择绝对路径');
    }
    final normalized = p.normalize(target.absolute.path);
    if (_unsafeDataRoot(normalized)) {
      throw const StorageUnavailableException('数据目录必须位于构建输出和程序包之外');
    }
    if (samePath(normalized, dataDirectory.path)) return;
    if (p.isWithin(dataDirectory.path, normalized) ||
        p.isWithin(normalized, dataDirectory.path)) {
      throw const StorageUnavailableException('新旧数据目录不能互相包含');
    }
    if (!resumeOwnedTarget &&
        await File(p.join(normalized, 'library.json')).exists()) {
      throw const StorageUnavailableException('目标已有媒体库，请选择空目录；不会覆盖或合并另一套数据');
    }
    if (await FileSystemEntity.type(normalized, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const StorageUnavailableException('数据目录不能是符号链接');
    }
    await target.create(recursive: true);
    final resolved = await target.resolveSymbolicLinks();
    if (!samePath(resolved, normalized)) {
      // System-provided roots may themselves be aliases (notably /var ->
      // /private/var on macOS). Allow that known prefix, never a link inside it.
      var systemAlias = false;
      final home =
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      for (final base in [
        _locations!.support,
        _locations!.documents,
        Directory.systemTemp,
        if (home != null && p.isAbsolute(home)) Directory(home),
      ]) {
        if (!samePath(base.path, normalized) &&
            !p.isWithin(base.path, normalized)) {
          continue;
        }
        if (!await base.exists()) continue;
        final expected = p.join(
          await base.resolveSymbolicLinks(),
          p.relative(normalized, from: base.path),
        );
        if (samePath(expected, resolved)) {
          systemAlias = true;
          break;
        }
      }
      if (!systemAlias) {
        throw const StorageUnavailableException('请选择不经过目录链接的数据位置');
      }
    }
    final actualSource = await dataDirectory.resolveSymbolicLinks();
    if (!samePath(normalized, dataDirectory.path) &&
        (samePath(actualSource, resolved) ||
            p.isWithin(actualSource, resolved) ||
            p.isWithin(resolved, actualSource))) {
      throw const StorageUnavailableException('新旧目录的实际位置不能互相包含');
    }
    await _probeWritable(target);
  }

  Future<void> commitRoot(
    Directory target,
    Map<String, String> pathAliases,
  ) async {
    final old = dataDirectory;
    final previousAliases = Map<String, String>.of(aliases);
    final previousRoots = Map<String, Directory>.of(roots);
    final previousStores = Map<String, String>.of(_stores);
    aliases.addAll(pathAliases);
    for (final e in roots.entries.toList()) {
      if (e.key == 'data') {
        roots[e.key] = target;
      } else if (e.key.startsWith('feature:') || e.key.startsWith('legacy')) {
        roots[e.key] = Directory(restorePath(e.value.path));
      }
    }
    for (final e in _stores.entries.toList()) {
      final restored = restorePath(e.value);
      _stores[e.key] =
          samePath(restored, e.value) && p.isWithin(old.path, e.value)
          ? p.join(target.path, p.relative(e.value, from: old.path))
          : restored;
    }
    _data = target;
    try {
      await _saveCatalog();
    } catch (_) {
      _data = old;
      aliases
        ..clear()
        ..addAll(previousAliases);
      roots
        ..clear()
        ..addAll(previousRoots);
      _stores
        ..clear()
        ..addAll(previousStores);
      rethrow;
    }
  }

  Future<void> _saveCatalog() {
    if (readOnlyCatalog) return Future<void>.value();
    final operation = _catalogTail
        .catchError((Object _) {})
        .then(
          (_) => writeStorageJson(
            File(p.join(controlDirectory.path, 'layout.json')),
            {
              'version': 1,
              'dataRoot': dataDirectory.path,
              'metadataRoot': metadataDirectory.path,
              'expectLibrary': _expectLibrary,
              'roots': {for (final e in roots.entries) e.key: e.value.path},
              'aliases': aliases,
              'stores': _stores,
            },
          ),
        );
    _catalogTail = operation;
    return operation;
  }
}
