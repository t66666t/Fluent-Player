import 'dart:async';

import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';
import 'cloud_drive_account_repository.dart';

class CloudDriveBrowseSnapshot {
  const CloudDriveBrowseSnapshot({
    required this.entries,
    required this.hasMore,
    required this.sort,
    required this.refreshing,
    required this.fromCache,
    this.error,
  });

  final List<CloudDriveEntry> entries;
  final bool hasMore;
  final CloudDriveSort sort;
  final bool refreshing;
  final bool fromCache;
  final CloudDriveFailure? error;
}

class _CacheEntry {
  _CacheEntry(this.page, this.storedAt);

  final CloudDrivePage page;
  final DateTime storedAt;
}

/// Directory state for one screen. Late responses from a previous account,
/// folder or sort are dropped.
class CloudDriveBrowserController {
  CloudDriveBrowserController({
    required CloudDriveProviderRegistry providers,
    required CloudDriveAccountRepository accounts,
    DateTime Function()? clock,
    this.cacheTtl = const Duration(seconds: 60),
    this.cacheLimit = 32,
  }) : _providers = providers,
       _accounts = accounts,
       _clock = clock ?? DateTime.now;

  final CloudDriveProviderRegistry _providers;
  final CloudDriveAccountRepository _accounts;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final int cacheLimit;

  /// Fired when a stale page is shown while a refresh is still running.
  void Function(CloudDriveBrowseSnapshot snapshot)? onStaleCache;

  final Map<String, _CacheEntry> _cache = {};
  final List<String> _cacheOrder = [];

  CloudDriveAccount? account;
  String parentFileId = '/';
  final List<({String id, String name})> breadcrumbs = [];
  CloudDriveSort sort = CloudDriveSort.name;
  var videosOnly = false;
  var _generation = 0;
  String? _cursor;
  var _hasMore = false;
  var _loading = false;
  final List<CloudDriveEntry> _entries = [];

  bool get loading => _loading;
  bool get hasMore => _hasMore;
  String? get cursor => _cursor;

  void close() {
    _generation++;
    _loading = false;
  }

  void clearCache() {
    _cache.clear();
    _cacheOrder.clear();
  }

  Future<CloudDriveBrowseSnapshot> openAccount(
    CloudDriveAccount next, {
    String? directoryId,
  }) async {
    account = next;
    parentFileId = directoryId ?? cloudDriveRootId(next.providerId);
    breadcrumbs
      ..clear()
      ..add((id: parentFileId, name: '全部文件'));
    _entries.clear();
    _cursor = null;
    return refresh();
  }

  Future<CloudDriveBrowseSnapshot> openFolder(CloudDriveEntry folder) async {
    // Baidu lists by directory path. Quark lists by the folder fid.
    parentFileId = folder.providerId == 'baidu'
        ? (folder.pathHint ?? folder.fileId)
        : folder.fileId;
    breadcrumbs.add((id: parentFileId, name: folder.name));
    _entries.clear();
    _cursor = null;
    return refresh();
  }

  Future<CloudDriveBrowseSnapshot> popTo(int index) async {
    if (index < 0 || index >= breadcrumbs.length) {
      return _snapshot(refreshing: false, fromCache: false);
    }
    breadcrumbs.removeRange(index + 1, breadcrumbs.length);
    parentFileId = breadcrumbs.last.id;
    _entries.clear();
    _cursor = null;
    return refresh();
  }

  Future<CloudDriveBrowseSnapshot> setSort(CloudDriveSort next) async {
    if (sort == next) return _snapshot(refreshing: false, fromCache: false);
    sort = next;
    _entries.clear();
    _cursor = null;
    return refresh();
  }

  Future<CloudDriveBrowseSnapshot> refresh() => _load(reset: true);

  Future<CloudDriveBrowseSnapshot> loadMore() => _load(reset: false);

  Future<CloudDriveBrowseSnapshot> _load({required bool reset}) async {
    final current = account;
    final provider = current == null ? null : _providers[current.providerId];
    if (current == null || provider == null) {
      return _snapshot(refreshing: false, fromCache: false);
    }
    if (!reset && (!_hasMore || _loading)) {
      return _snapshot(refreshing: false, fromCache: false);
    }
    final generation = ++_generation;
    final cacheKey = _key(current);
    if (reset) {
      final cached = _cache[cacheKey];
      if (cached != null) {
        _entries
          ..clear()
          ..addAll(_visible(cached.page.entries));
        _cursor = cached.page.nextCursor;
        _hasMore = cached.page.hasMore;
        final fresh = _clock().difference(cached.storedAt) <= cacheTtl;
        if (fresh) {
          return _snapshot(refreshing: false, fromCache: true);
        }
        onStaleCache?.call(_snapshot(refreshing: true, fromCache: true));
      }
    }
    _loading = true;
    try {
      final credential = await _accounts.credentialFor(current);
      if (credential == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.notLoggedIn,
          '需要重新登录后才能读取目录',
        );
      }
      final page = await provider.listChildren(
        CloudDriveListRequest(
          credential: credential,
          accountLocalId: current.localId,
          remoteAccountId: current.remoteAccountId,
          driveId: current.driveId,
          parentFileId: parentFileId,
          cursor: reset ? null : _cursor,
          sort: sort,
          pathHint: parentFileId,
        ),
        cancelToken: generation,
      );
      if (generation != _generation) {
        return _snapshot(refreshing: false, fromCache: false);
      }
      if (reset) {
        _entries
          ..clear()
          ..addAll(_visible(page.entries));
        _remember(cacheKey, page);
      } else {
        final seen = _entries.map((entry) => entry.fileId).toSet();
        for (final entry in _visible(page.entries)) {
          if (seen.add(entry.fileId)) _entries.add(entry);
        }
      }
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _loading = false;
      return _snapshot(refreshing: false, fromCache: false);
    } on CloudDriveFailure catch (error) {
      if (generation != _generation) {
        return _snapshot(refreshing: false, fromCache: false);
      }
      _loading = false;
      return _snapshot(
        refreshing: false,
        fromCache: _entries.isNotEmpty,
        error: error,
      );
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  List<CloudDriveEntry> _visible(List<CloudDriveEntry> entries) {
    final visible = entries.where((entry) {
      if (!videosOnly) return true;
      return entry.kind == CloudDriveEntryKind.folder ||
          entry.kind == CloudDriveEntryKind.video;
    }).toList();
    // Folders stay first. The remaining order is the provider's sort.
    visible.sort((a, b) {
      final aFolder = a.kind == CloudDriveEntryKind.folder ? 0 : 1;
      final bFolder = b.kind == CloudDriveEntryKind.folder ? 0 : 1;
      return aFolder.compareTo(bFolder);
    });
    return visible;
  }

  void _remember(String key, CloudDrivePage page) {
    _cache[key] = _CacheEntry(page, _clock());
    _cacheOrder.remove(key);
    _cacheOrder.add(key);
    while (_cacheOrder.length > cacheLimit) {
      final oldest = _cacheOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }

  String _key(CloudDriveAccount current) =>
      '${current.localId}|$parentFileId|${sort.name}|$videosOnly';

  CloudDriveBrowseSnapshot _snapshot({
    required bool refreshing,
    required bool fromCache,
    CloudDriveFailure? error,
  }) {
    return CloudDriveBrowseSnapshot(
      entries: List.unmodifiable(_entries),
      hasMore: _hasMore,
      sort: sort,
      refreshing: refreshing,
      fromCache: fromCache,
      error: error,
    );
  }
}
