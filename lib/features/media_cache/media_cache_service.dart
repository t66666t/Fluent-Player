import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/video_item.dart';
import '../../models/media_source_ref.dart';
import '../../models/bilibili_models.dart';
import '../../models/bilibili_download_task.dart';
import '../../models/cloud_drive_source_ref.dart';
import '../../services/app_storage_service.dart';
import '../../services/app_default_settings_trial.dart';
import '../../services/media_materialization_service.dart';
import '../../services/network/network_recovery.dart';
import '../../services/network/network_settings_service.dart';
import '../../services/network/network_models.dart';
import '../../services/storage_audit_models.dart';
import '../../services/storage_audit_service.dart';
import '../../services/storage_migration_coordinator.dart';
import '../cloud_drive/models/cloud_drive_models.dart';
import 'media_cache_backend.dart';
import 'media_cache_models.dart';
import 'media_cache_native.dart';
import 'media_cache_reads.dart';
import 'media_cache_hooks.dart';
import 'media_cache_card_state.dart';

Future<void> _writeMediaCacheSnapshot((String, Object) request) =>
    writeStorageJson(File(request.$1), request.$2);

/// One owner for queue transitions, publication and deletion. Widget lifetime
/// never owns a transfer. All journal writes are serialized immutable snapshots.
class MediaCacheService extends ChangeNotifier with WidgetsBindingObserver {
  MediaCacheService({
    required this.backend,
    this.journal,
    this.observeNetwork = true,
    NetworkSettingsService? networkSettings,
    this.isPathInUse,
    this.onBeforeDelete,
    this.onFilesRemoved,
    this.onChanged,
    DateTime Function()? clock,
  }) : _networkSettings = networkSettings,
       _clock = clock ?? DateTime.now;

  static MediaCacheService? instance;
  static const journalName = 'media_cache.json';
  final MediaCacheBackend backend;
  final File? journal;
  final bool observeNetwork;
  final NetworkSettingsService? _networkSettings;
  final bool Function(String path)? isPathInUse;
  final Future<void> Function(CacheVariant variant)? onBeforeDelete;
  final Future<void> Function(List<String> paths)? onFilesRemoved;
  final void Function()? onChanged;
  final DateTime Function() _clock;
  final List<CacheTask> _tasks = [];
  final Map<String, CacheVariant> _variants = {};
  int _variantRevision = 0;
  int _indexedVariantRevision = -1;
  final Map<String, List<CacheVariant>> _variantsByMedia = {};
  final Map<String, ValueNotifier<MediaCacheCardState>> _cardStates = {};
  final Map<String, Future<void>> _cardChecks = {};
  final Map<String, List<CacheVariant>> _cardCandidates = {};
  final Map<String, List<CacheVariant>> _discoveredCardCandidates = {};
  final Map<String, CacheSource> _cardSources = {};
  Future<dynamic>? _journalRead;
  Future<void>? _cardCatalogRead;

  Future<dynamic> _readJournal() => _journalRead ??= () async {
    _file = journal ?? await AppStorageService.instance.dataRecord(journalName);
    return readStorageJson(_file!);
  }();

  /// Reading a card never activates transfers, rewrites the journal, repairs
  /// completed tasks, or waits for every unrelated file to be validated.
  ValueListenable<MediaCacheCardState> cardStateFor(CacheSource source) {
    final key = _sourceKey(source);
    _cardSources[key] = source;
    var state = _cardStates[key];
    if (state == null) {
      state = ValueNotifier(const MediaCacheCardState());
      _cardStates[key] = state;
      _publishCardStates();
    }
    if (!state.value.ready) unawaited(prepareCardStates([source]));
    return state;
  }

  Future<void> prepareCardStates(Iterable<CacheSource> sources) async {
    for (final source in sources) {
      final key = _sourceKey(source);
      _cardSources[key] = source;
      final existing = _cardChecks[key];
      if (existing != null) {
        await existing;
        continue;
      }
      final operation = _prepareCardState(source);
      _cardChecks[key] = operation;
      try {
        await operation;
      } finally {
        if (identical(_cardChecks[key], operation)) _cardChecks.remove(key);
      }
    }
  }

  Future<void> _readCardCatalog() => _cardCatalogRead ??= () async {
    final raw = await _readJournal();
    if (raw == null) return;
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('缓存任务记录版本无法识别，已保留原记录');
    }
    final decoded = AppStorageService.instance.decodePaths(raw) as Map;
    for (final row in decoded['variants'] as List? ?? []) {
      final variant = CacheVariant.fromJson(
        Map<String, dynamic>.from(row as Map),
      );
      (_cardCandidates[_sourceKey(variant.source)] ??= []).add(variant);
    }
  }();

  Future<void> _prepareCardState(CacheSource source) async {
    final key = _sourceKey(source);
    final previousWatchPaths = _cardWatchPaths(key);
    final validWatchDirectories = <String>{};
    var available = false;
    try {
      if (!_ready) await _readCardCatalog();
      final candidates = _ready
          ? _mediaVariants(key)
          : _cardCandidates[key] ?? const <CacheVariant>[];
      for (final variant in candidates.toList()) {
        final valid = !variant.pendingDelete && await _valid(variant);
        if (!variant.pendingDelete) variant.available = valid;
        if (valid && !variant.pendingDelete) {
          validWatchDirectories.add(File(variant.path).parent.path);
        }
        if (valid && !variant.pendingDelete && variant.completeMedia) {
          available = true;
          break;
        }
      }
      // Local source manifests are read-only here. Do not register them or
      // call initialize() as the old per-widget discovery path did.
      if (!available && MediaCacheHooks.discover != null) {
        final discovered = await MediaCacheHooks.discover!(source);
        _discoveredCardCandidates[key] = discovered;
        for (final variant in discovered) {
          variant.available = !variant.pendingDelete && await _valid(variant);
          if (variant.available) {
            validWatchDirectories.add(File(variant.path).parent.path);
          }
          if (variant.available && variant.completeMedia && !_blockedCardPath(key, variant.path)) {
            available = true;
            break;
          }
        }
      }
    } catch (_) {
      // Unreadable files cannot earn a completed badge; keep their records.
    }
    if (_closed || _disposed) return;
    final state = _cardStates.putIfAbsent(
      key,
      () => ValueNotifier(const MediaCacheCardState()),
    );
    final previous = state.value;
    state.value = MediaCacheCardState(
      ready: true,
      hasCache: available,
      active: previous.active,
      progress: previous.progress,
    );
    _trimCardStates();
    // Rechecking a visible badge does not usually change its files. Rebuilding
    // the entire visible watch index for every card on route return makes a
    // small folder trigger quadratic path normalization on the UI isolate.
    // Keep validation immediate, and reconcile only changed paths or a lost
    // native watcher for a verified file. Missing/unmounted directories must
    // not force a global rescan for every unrelated card. Visibility/variant
    // revisions still invalidate normally.
    _syncFileWatches(
      force:
          !setEquals(previousWatchPaths, _cardWatchPaths(key)) ||
          validWatchDirectories.any(
            (directory) => !_fileWatches.containsKey(directory),
          ),
    );
  }

  Set<(String, String)> _cardWatchPaths(String key) => {
    for (final variant in [
      ...(_ready
          ? _mediaVariants(key)
          : _cardCandidates[key] ?? const <CacheVariant>[]),
      ...?_discoveredCardCandidates[key],
    ])
      if (!variant.pendingDelete) (_sourceKey(variant.source), variant.path),
  };

  List<CacheVariant> _mediaVariants(String key) {
    if (_indexedVariantRevision != _variantRevision) {
      _variantsByMedia.clear();
      for (final variant in _variants.values) {
        (_variantsByMedia[_sourceKey(variant.source)] ??= []).add(variant);
      }
      _indexedVariantRevision = _variantRevision;
    }
    return _variantsByMedia[key] ?? const <CacheVariant>[];
  }

  bool _blockedCardPath(String key, String path) => _mediaVariants(key).any(
    (v) => v.pendingDelete && AppStorageService.samePath(v.path, path));

  bool _discoveredCardAvailable(String key) =>
      (_discoveredCardCandidates[key] ?? const <CacheVariant>[]).any((v) =>
        v.available && !v.pendingDelete && v.completeMedia && !_blockedCardPath(key, v.path));

  void _publishCardStates() {
    final active = <String, List<CacheTask>>{};
    for (final task in _tasks) {
      if (task.state.running) {
        (active[_sourceKey(task.source)] ??= []).add(task);
      }
    }
    for (final entry in _cardStates.entries) {
      final old = entry.value.value;
      final tasks = active[entry.key] ?? const <CacheTask>[];
      final known = tasks.isNotEmpty && tasks.every((t) => (t.total ?? 0) > 0);
      final progress = known
          ? (tasks.fold<int>(0, (n, t) => n + t.received) /
                    tasks.fold<int>(0, (n, t) => n + t.total!))
                .clamp(0.0, .99)
          : tasks.length == 1
          ? tasks.single.progress
          : null;
      final variants = _mediaVariants(entry.key);
      entry.value.value = MediaCacheCardState(
        ready: old.ready,
        hasCache: _discoveredCardAvailable(entry.key) || (variants.isEmpty
            ? old.hasCache && !_ready
            : variants.any(
                (v) => v.available && !v.pendingDelete && v.completeMedia,
              )),
        active: tasks.isNotEmpty,
        progress: progress,
      );
    }
    _trimCardStates();
  }

  void _trimCardStates() {
    // Bound retained display snapshots; mounted cards keep their notifier.
    if (_cardStates.length > 400) {
      for (final key in _cardStates.keys.toList()) {
        if (_cardStates.length <= 400) break;
        final state = _cardStates[key]!;
        if (!state.hasListeners && !_cardChecks.containsKey(key)) {
          _cardStates.remove(key);
          _cardSources.remove(key);
          if (_discoveredCardCandidates.remove(key)?.isNotEmpty ?? false) {
            _watchRevision = null;
          }
          state.dispose();
        }
      }
    }
  }

  final Map<String, Future<void>> _runs = {};
  final Map<String, CancelToken> _tokens = {};
  final Map<String, int> _leases = {};
  final Map<String, String> _reservations = {};
  final Set<String> _cancelling = {};
  final Map<String, int> _visibleMedia = {};
  final Expando<String> _sourceKeys = Expando<String>('cache media identity');
  final Map<String, StreamSubscription<FileSystemEvent>> _fileWatches = {};
  final Map<String, Set<String>> _watchMedia = {};
  final Map<String, Set<String>> _watchFiles = {};
  final Map<String, Future<void>> _availabilityChecks = {};
  Future<void> _availabilityTail = Future.value();
  final Set<String> _pendingAvailability = {};
  Timer? _availabilityTimer;
  int _visibilityRevision = 0;
  (int, int)? _watchRevision;
  MediaCachePreferences preferences = MediaCachePreferences();
  Future<void>? _initializing;
  Future<void> _writes = Future.value();
  Future<void> _legacyRegistrations = Future.value();
  File? _file;
  Timer? _progressTimer, _persistTimer, _maintenanceTimer;
  StreamSubscription<dynamic>? _connectivity, _network;
  Completer<void>? _maintenanceDone;
  bool _ready = false,
      _closed = false,
      _disposed = false,
      _foreground = true,
      _maintaining = false;
  int _nativeCount = -1;
  int? _storageToken;
  final ValueNotifier<int> storageChanges = ValueNotifier(0);
  String? loadError, persistenceError;

  bool get ready => _ready;
  List<CacheTask> get tasks => List.unmodifiable(_tasks);
  List<CacheVariant> get variants => List.unmodifiable(_variants.values);
  int get runningCount => _tasks.where((t) => t.state.running).length;
  double get bytesPerSecond => _tasks
      .where((t) => t.state.running)
      .fold(0, (sum, t) => sum + t.bytesPerSecond);
  int get cachedBytes {
    final files = <String, int>{};
    for (final variant in _variants.values.where((v) => v.available)) {
      files[storagePathKey(variant.path)] = variant.bytes;
    }
    return files.values.fold(0, (sum, bytes) => sum + bytes);
  }

  Set<String> get protectedPaths => {
    ...CacheFileAccess.readingPaths,
    ...MaterializedMediaLease.pathsInUse,
    for (final v in _variants.values)
      if ((_leases[v.id] ?? 0) > 0 || _inUse(v.path)) v.path,
    for (final t in _tasks)
      if (t.workDirectory != null &&
          (_runs.containsKey(t.id) || _inUse(t.workDirectory!)))
        t.workDirectory!,
  };

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    final missingVariants = <CacheVariant>[];
    try {
      final raw = await _readJournal();
      if (raw != null) {
        if (raw is! Map || raw['version'] != 1) {
          throw const FormatException('缓存任务记录版本无法识别，已保留原记录');
        }
        final json = AppStorageService.instance.decodePaths(raw) as Map;
        preferences = MediaCachePreferences.fromJson(
          Map<String, dynamic>.from(json['preferences'] as Map? ?? {}),
        );
        for (final entry in json['tasks'] as List? ?? []) {
          final task = CacheTask.fromJson(
            Map<String, dynamic>.from(entry as Map),
          );
          if (task.state.running ||
              task.state == CacheTaskState.retrying ||
              task.state == CacheTaskState.waitingSystem) {
            task.state = CacheTaskState.queued;
          }
          _tasks.add(task);
        }
        for (final entry in json['variants'] as List? ?? []) {
          final variant = CacheVariant.fromJson(
            Map<String, dynamic>.from(entry as Map),
          );
          if (await _valid(variant)) {
            _putVariant(variant);
          } else if (!await File(variant.path).parent.exists()) {
            variant.available = false;
            _putVariant(variant);
          } else {
            missingVariants.add(variant);
          }
        }
        for (final task in _tasks) {
          final dir = task.workDirectory;
          if (dir == null || p.basename(dir) != 'cache_${task.id}') continue;
          final rawReceipt = await readStorageJson(
            File(p.join(dir, 'published_variant.json')),
          );
          if (rawReceipt is! Map) continue;
          final receipt =
              AppStorageService.instance.decodePaths(rawReceipt) as Map;
          final variant = CacheVariant.fromJson(
            Map<String, dynamic>.from(receipt),
          );
          final target = File(variant.path);
          final staging = File('${variant.path}.publishing');
          if (variant.source.key == task.source.key &&
              !await target.exists() &&
              variant.bytes > 0 &&
              await staging.exists() &&
              await staging.length() == variant.bytes) {
            await staging.rename(target.path);
          }
          if (variant.source.key == task.source.key && await _valid(variant)) {
            _putVariant(variant);
            task.state = CacheTaskState.completed;
            task.quality = variant.quality;
            task.received = variant.bytes;
            task.total = variant.bytes;
          }
        }
        _repairCompletedTasks();
      }
      _ready = true;
      _journalRead = null;
      _cardCatalogRead = null;
      _cardCandidates.clear();
      for (final variant in missingVariants) {
        await onBeforeDelete?.call(variant);
      }
      if (missingVariants.isNotEmpty) {
        await onFilesRemoved?.call(missingVariants.map((v) => v.path).toList());
      }
      if (observeNetwork) {
        MediaCacheNative.onInterrupted = (manual) {
          if (_closed || _disposed) return;
          for (final task
              in _tasks
                  .where(
                    (t) =>
                        t.state.running ||
                        t.state == CacheTaskState.queued ||
                        t.state == CacheTaskState.retrying,
                  )
                  .toList()) {
            unawaited(
              pause(
                task.id,
                state: manual
                    ? CacheTaskState.paused
                    : CacheTaskState.waitingSystem,
              ),
            );
          }
        };
        WidgetsBinding.instance.addObserver(this);
        _connectivity = Connectivity().onConnectivityChanged.listen((event) {
          final connected = !event.contains(ConnectivityResult.none);
          if (connected) unawaited(_wakeNetwork());
        }, onError: (Object _) {});
      }
      if (observeNetwork || _networkSettings != null) {
        _network = (_networkSettings ?? NetworkSettingsService.instance).changes
            .listen((change) => unawaited(_networkChanged(change)));
      }
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
      _syncMaintenanceTimer();
      await _save();
      _notify();
      _pump();
    } catch (error) {
      loadError = _errorText(error);
      _notify();
      rethrow;
    }
  }

  Future<void> retryInitialization() async {
    if (_ready) return;
    _tasks.clear();
    _variants.clear();
    _variantRevision++;
    _initializing = null;
    _journalRead = null;
    _cardCatalogRead = null;
    _cardCandidates.clear();
    loadError = null;
    await initialize();
  }

  List<CacheVariant> variantsFor(String key) =>
      _mediaVariants(key)
          .where(
            (v) =>
                _sourceKey(v.source) == key && !v.pendingDelete && v.available,
          )
          .toList()
        ..sort(
          (a, b) =>
              (b.quality.id == 'original' ? 100000 : b.quality.height ?? 0)
                  .compareTo(
                    a.quality.id == 'original' ? 100000 : a.quality.height ?? 0,
                  ),
        );
  CacheTask? taskFor(String key, {String? qualityId}) => _tasks
      .where(
        (t) =>
            t.source.key == key &&
            t.unfinished &&
            (qualityId == null ||
                t.requestedQuality == qualityId ||
                t.quality?.id == qualityId),
      )
      .firstOrNull;
  bool hasCache(String key) => _mediaVariants(
    key,
  ).any((v) => v.available && !v.pendingDelete && v.completeMedia);
  bool _inUse(String path) =>
      MaterializedMediaLease.isPathInUse(path) ||
      (MediaCacheHooks.pathInUse?.call(path) ?? false) ||
      (isPathInUse?.call(path) ?? false);

  String _sourceKey(CacheSource source) => _sourceKeys[source] ??= source.key;

  /// Only visible cards and open media dialogs need immediate filesystem
  /// notifications. Shared directories have one watcher, regardless of cards.
  VoidCallback observeMediaAvailability(String key) {
    _visibleMedia[key] = (_visibleMedia[key] ?? 0) + 1;
    _visibilityRevision++;
    _syncFileWatches();
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_visibleMedia[key] ?? 1) - 1;
      if (count <= 0) {
        _visibleMedia.remove(key);
      } else {
        _visibleMedia[key] = count;
      }
      _visibilityRevision++;
      _syncFileWatches();
    };
  }

  Future<void> refreshAvailability({String? mediaKey}) async {
    if (!_ready && mediaKey != null && _cardSources[mediaKey] != null) {
      await prepareCardStates([_cardSources[mediaKey]!]);
      return;
    }
    await initialize();
    if (_closed || _disposed) return;
    final key = mediaKey ?? '*';
    final existing = _availabilityChecks[key];
    if (existing != null) return existing;
    final operation = _availabilityTail.catchError((Object _) {}).then((
      _,
    ) async {
      await _refreshAvailability(mediaKey);
      if (mediaKey != null && !_closed && !_disposed) {
        final source = _variants.values
            .where((v) => v.source.key == mediaKey)
            .firstOrNull
            ?.source;
        if (source != null) await discoverMaterial(source);
      }
    });
    _availabilityTail = operation;
    _availabilityChecks[key] = operation;
    try {
      await operation;
    } finally {
      if (identical(_availabilityChecks[key], operation)) {
        _availabilityChecks.remove(key);
      }
    }
  }

  Future<void> _refreshAvailability(String? mediaKey) async {
    for (final variant
        in (mediaKey == null ? _variants.values : _mediaVariants(mediaKey))
            .toList()) {
      if (_closed || _disposed) return;
      if (variant.pendingDelete ||
          mediaKey != null && _sourceKey(variant.source) != mediaKey) {
        continue;
      }
      final valid = await _valid(variant);
      if (_closed || _disposed) return;
      if (!identical(_variants[variant.id], variant) || variant.pendingDelete) {
        continue;
      }
      if (variant.available != valid) {
        variant.available = valid;
        _notify();
      }
      if (!valid &&
          await File(variant.path).parent.exists() &&
          identical(_variants[variant.id], variant)) {
        await forgetDeletedFiles([variant.path]);
      }
    }
    _syncFileWatches(force: true);
  }

  void _syncFileWatches({bool force = false}) {
    if (_closed || _disposed || !FileSystemEntity.isWatchSupported) return;
    final revision = (_variantRevision, _visibilityRevision);
    if (!force && _watchRevision == revision) return;
    _watchRevision = revision;
    _watchMedia.clear();
    _watchFiles.clear();
    for (final variant in _visibleMedia.keys.expand(
      (key) => <CacheVariant>[
        ...(_ready ? _mediaVariants(key) : _cardCandidates[key] ?? const <CacheVariant>[]),
        ...?_discoveredCardCandidates[key],
      ],
    )) {
      if (variant.pendingDelete ||
          !_visibleMedia.containsKey(_sourceKey(variant.source))) {
        continue;
      }
      final directory = File(variant.path).parent.path;
      (_watchMedia[directory] ??= {}).add(_sourceKey(variant.source));
      (_watchFiles[directory] ??= {}).add(storagePathKey(variant.path));
    }
    for (final directory in _fileWatches.keys.toList()) {
      if (!_watchMedia.containsKey(directory)) {
        unawaited(_fileWatches.remove(directory)!.cancel());
      }
    }
    for (final directory in _watchMedia.keys) {
      if (_fileWatches.containsKey(directory)) continue;
      try {
        late StreamSubscription<FileSystemEvent> subscription;
        void ended() {
          if (identical(_fileWatches[directory], subscription)) {
            _fileWatches.remove(directory);
          }
          _queueAvailabilityCheck(directory);
        }

        subscription = Directory(directory).watch().listen(
          (event) {
            final files = _watchFiles[directory] ?? const <String>{};
            if (files.contains(storagePathKey(event.path)) ||
                AppStorageService.samePath(directory, event.path) ||
                event is FileSystemMoveEvent &&
                    event.destination != null &&
                    files.contains(storagePathKey(event.destination!))) {
              _queueAvailabilityCheck(directory);
            }
          },
          onError: (Object _) {
            // Unavailable volumes/watch limits fall back to reconciliation.
            unawaited(subscription.cancel());
            if (identical(_fileWatches[directory], subscription)) {
              _fileWatches.remove(directory);
            }
          },
          onDone: ended,
        );
        _fileWatches[directory] = subscription;
      } catch (_) {
        // Not all filesystems implement native notifications.
      }
    }
  }

  void _queueAvailabilityCheck(String directory) {
    if (_closed || _disposed) return;
    _pendingAvailability.addAll(_watchMedia[directory] ?? const <String>{});
    _availabilityTimer?.cancel();
    _availabilityTimer = Timer(const Duration(milliseconds: 120), () {
      final keys = _pendingAvailability.toList();
      _pendingAvailability.clear();
      for (final key in keys) {
        unawaited(refreshAvailability(mediaKey: key).catchError((Object _) {}));
      }
    });
  }

  Future<CacheTask?> enqueue(
    CacheSource source, {
    String? qualityId,
    bool skipCached = false,
  }) async {
    await initialize();
    await discoverMaterial(source);
    if (_closed || StorageMigrationCoordinator.maintenance) {
      throw const StorageUnavailableException('存储目录正在迁移');
    }
    if (skipCached && (hasCache(source.key) || taskFor(source.key) != null)) {
      return null;
    }
    if (qualityId != null &&
        variantsFor(
          source.key,
        ).any((v) => v.completeMedia && v.quality.id == qualityId)) {
      return null;
    }
    final existing = taskFor(source.key, qualityId: qualityId);
    if (existing != null) return existing;
    final task = CacheTask(
      id: const Uuid().v4(),
      source: source,
      createdAt: _clock().millisecondsSinceEpoch,
      requestedQuality: qualityId,
      maxHeight: source.kind == MediaType.audio
          ? null
          : preferences.limits[source.provider],
    );
    _tasks.add(task);
    try {
      await _save();
    } catch (_) {
      _tasks.remove(task);
      rethrow;
    }
    _notify();
    _pump();
    return task;
  }

  Future<int> enqueueAll(Iterable<CacheSource> sources) async {
    var added = 0;
    final seen = <String>{};
    for (final source in sources) {
      if (seen.add(source.key) &&
          await enqueue(source, skipCached: true) != null) {
        added++;
      }
    }
    return added;
  }

  Future<void> pause(
    String id, {
    CacheTaskState state = CacheTaskState.paused,
  }) async {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.unfinished) return;
    task.state = state;
    task.generation++;
    task.bytesPerSecond = 0;
    _tokens[id]?.cancel('缓存已暂停');
    _notify();
    await _runs[id];
    await _save();
  }

  Future<void> resume(String id) async {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.unfinished || _closed) return;
    final generation = task.generation;
    await _runs[id];
    if (_closed ||
        !_tasks.contains(task) ||
        !task.unfinished ||
        _cancelling.contains(id) ||
        task.generation != generation) {
      return;
    }
    task.generation++;
    task.state = CacheTaskState.queued;
    task.error = null;
    await _save();
    _notify();
    _pump();
  }

  Future<void> cancel(String id) async {
    if (!_cancelling.add(id)) return;
    try {
      final task = _tasks.where((t) => t.id == id).firstOrNull;
      if (task == null) return;
      await pause(id);
      if (task.workDirectory case final String directory) {
        // Only our per-task directory can be removed, never an inferred parent.
        if (p.basename(directory) == 'cache_${task.id}' && !_inUse(directory)) {
          await MediaCacheNative.directory(directory, forget: true);
          final dir = Directory(directory);
          await CacheFileAccess.mutate(directory, () async {
            if (await dir.exists()) await dir.delete(recursive: true);
          });
        }
      }
      _tasks.remove(task);
      await _save();
      _notify();
    } finally {
      _cancelling.remove(id);
      _pump();
    }
  }

  Future<void> pauseAll() async {
    await Future.wait(
      _tasks.where((t) => t.unfinished).toList().map((t) => pause(t.id)),
    );
  }

  Future<void> resumeAll() async {
    for (final task in _tasks.where((t) => t.unfinished).toList()) {
      if (!task.state.running) await resume(task.id);
    }
  }

  Future<void> updatePreferences() async {
    await _save();
    _notify();
    _pump();
  }

  void _pump() {
    if (!_ready ||
        _closed ||
        _disposed ||
        StorageMigrationCoordinator.maintenance) {
      return;
    }
    for (final task in _tasks.toList()) {
      if (_runs.length >= preferences.parallelTasks) break;
      if (task.state != CacheTaskState.queued ||
          _runs.containsKey(task.id) ||
          _cancelling.contains(task.id)) {
        continue;
      }
      final token = CancelToken();
      _tokens[task.id] = token;
      task.state = CacheTaskState.resolving;
      final generation = ++task.generation;
      // Defer execution until the future is registered, including synchronous
      // fake backends and immediately-cancelled queue entries.
      final operation = Future<void>(() => _run(task, generation, token));
      _runs[task.id] = operation;
      operation.whenComplete(() {
        _runs.remove(task.id);
        _tokens.remove(task.id);
        _notify();
        _pump();
      }).ignore();
    }
    _notify();
  }

  Future<void> _run(CacheTask task, int generation, CancelToken token) async {
    bool current() =>
        !_closed &&
        !token.isCancelled &&
        task.generation == generation &&
        _tasks.contains(task);
    String? assetKey;
    try {
      await _save();
      final plan = await backend.resolve(task, token);
      if (!current()) return;
      task.quality = plan.quality;
      assetKey = cacheDigest(
        '${task.source.key}:${plan.quality.revision}:${plan.quality.id}:${plan.quality.codec}',
      );
      while (_reservations.containsKey(assetKey) &&
          _reservations[assetKey] != task.id) {
        task.state = CacheTaskState.queued;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!current()) return;
      }
      final cached = _variants[assetKey];
      if (cached?.pendingDelete == true) {
        throw StateError('此画质仍在使用并等待删除，结束播放或处理后可重试缓存');
      }
      if (cached != null && !cached.pendingDelete && await _valid(cached)) {
        task.state = CacheTaskState.completed;
        task.received = cached.bytes;
        task.total = cached.bytes;
        task.fraction = 1;
        await _save();
        return;
      }
      _reservations[assetKey] = task.id;
      task.workDirectory = (await backend.taskDirectory(task)).path;
      task.outputDirectory ??= (await backend.outputDirectory(
        task.source,
      )).path;
      if (!current()) return;
      task.state = CacheTaskState.downloading;
      await _save();
      final meter = Stopwatch()..start();
      var lastTime = 0, lastBytes = -1;
      final file = await backend.download(task, plan, preferences, token, (
        update,
      ) {
        if (!current()) return;
        task.state = update.state;
        task.received = update.received;
        task.total = update.total;
        task.fraction = update.fraction;
        final now = meter.elapsedMilliseconds;
        if (lastBytes < 0 || update.received < lastBytes) {
          lastBytes = update.received;
          lastTime = now;
          task.bytesPerSecond = 0;
        } else if (now - lastTime >= 400) {
          final speed = (update.received - lastBytes) * 1000 / (now - lastTime);
          task.bytesPerSecond = task.bytesPerSecond == 0
              ? speed
              : task.bytesPerSecond * .4 + speed * .6;
          lastBytes = update.received;
          lastTime = now;
        }
        if (!task.state.running) task.bytesPerSecond = 0;
        _scheduleProgress();
      });
      if (!current()) return;
      task.state = CacheTaskState.publishing;
      _notify();
      final size = await file.length();
      if (size <= 0) throw const FormatException('缓存文件为空');
      if (!current()) return;
      final output = Directory(task.outputDirectory!);
      // Never silently replace a missing custom/external destination.
      if (!await output.exists()) {
        throw const StorageUnavailableException('缓存目标目录不可用');
      }
      final target = plan.retainInPlace
          ? file
          : File(p.join(output.path, 'cache_$assetKey${plan.extension}'));
      final variant = CacheVariant(
        source: task.source,
        quality: plan.retainInPlace
            ? _variants.values
                      .where(
                        (v) =>
                            v.completeMedia &&
                            v.source.key == task.source.key &&
                            AppStorageService.samePath(v.path, file.path),
                      )
                      .firstOrNull
                      ?.quality ??
                  plan.quality
            : plan.quality,
        path: target.path,
        bytes: size,
        createdAt: _clock().millisecondsSinceEpoch,
        modifiedMicros: (await file.lastModified()).microsecondsSinceEpoch,
      );
      await writeStorageJson(
        File(p.join(task.workDirectory!, 'published_variant.json')),
        AppStorageService.instance.encodePaths(variant.toJson()),
      );
      if (file.path != target.path) {
        final staging = File('${target.path}.publishing');
        if (await staging.exists()) await staging.delete();
        // A rename is cheap on the same volume. Cross-volume custom locations
        // keep the source until the copy's length and publication are complete.
        try {
          await file.rename(staging.path);
        } on FileSystemException {
          await file.copy(staging.path);
        }
        if (await staging.length() != size) {
          throw const FileSystemException('缓存文件保存不完整，原文件已保留');
        }
        if (!current()) {
          if (!await file.exists()) await staging.rename(file.path);
          return;
        }
        if (await target.exists()) await target.delete();
        await staging.rename(target.path);
      }
      if (!current()) {
        if (await target.exists()) await target.delete();
        return;
      }
      _putVariant(variant);
      task.quality = variant.quality;
      task.state = CacheTaskState.completed;
      task.received = size;
      task.total = size;
      task.fraction = 1;
      task.error = null;
      task.bytesPerSecond = 0;
      // Commit ownership before pruning or removing any source material.
      await _save();
      _notify();
      if (file.path != target.path && await file.exists()) await file.delete();
      if (preferences.pruneLower) await _prune(variant);
      await _cleanTaskDirectory(task);
    } catch (error) {
      if (current()) {
        task.bytesPerSecond = 0;
        task.error = _errorText(error);
        if (task.state == CacheTaskState.completed &&
            _variants.containsKey(assetKey)) {
          task.error = '缓存已完成，清理稍后重试：${task.error}';
          return;
        }
        task.state = error is CacheSystemDeferred
            ? CacheTaskState.waitingSystem
            : error is CacheLoginRequired ||
                  error is DioException && error.response?.statusCode == 401 ||
                  error is HttpException &&
                      RegExp(r'HTTP\s+401').hasMatch(error.message) ||
                  error is CloudDriveFailure &&
                      error.kind == CloudDriveFailureKind.notLoggedIn
            ? CacheTaskState.waitingLogin
            : error is StorageUnavailableException || _diskError(error)
            ? CacheTaskState.waitingStorage
            : NetworkRecovery.isTransient(error)
            ? CacheTaskState.waitingNetwork
            : CacheTaskState.failed;
      }
    } finally {
      if (assetKey != null && _reservations[assetKey] == task.id) {
        _reservations.remove(assetKey);
      }
      task.bytesPerSecond = 0;
      try {
        await _save();
      } catch (_) {
        /* surfaced as persistenceError */
      }
      _notify();
    }
  }

  Future<void> _prune(CacheVariant fresh) async {
    if (!fresh.completeMedia) return;
    final height = fresh.quality.resolutionHeight;
    final original = !fresh.source.isBilibili && fresh.quality.id == 'original';
    if ((!original && (height == null || height <= 0)) ||
        fresh.source.kind == MediaType.audio) {
      return;
    }
    for (final old in variantsFor(fresh.source.key)) {
      if (old.id != fresh.id &&
          old.managed &&
          old.quality.revision == fresh.quality.revision &&
          old.quality.id != 'original' &&
          old.quality.resolutionHeight != null &&
          (original || old.quality.resolutionHeight! < height!)) {
        await deleteVariant(old.id);
      }
    }
  }

  Future<void> deleteAll(String mediaKey) async {
    for (final task
        in _tasks
            .where((t) => t.source.key == mediaKey && t.unfinished)
            .toList()) {
      await cancel(task.id);
    }
    for (final v
        in _variants.values.where((v) => v.source.key == mediaKey).toList()) {
      await deleteVariant(v.id);
    }
  }

  Future<void> deleteVariant(String id) async {
    final variant = _variants[id];
    if (variant == null) return;
    variant.pendingDelete = true;
    await _save();
    _notify();
    if ((_leases[id] ?? 0) > 0 || _inUse(variant.path)) {
      return;
    }
    final shared = _variants.values.any(
      (other) =>
          other.id != id &&
          AppStorageService.samePath(other.path, variant.path) &&
          (!other.pendingDelete || (_leases[other.id] ?? 0) > 0),
    );
    if (!shared) {
      await onBeforeDelete?.call(variant);
      final file = File(variant.path);
      if (!await file.parent.exists()) {
        throw const StorageUnavailableException('缓存所在存储位置不可用，恢复后继续删除');
      }
      await CacheFileAccess.mutate(file.path, () async {
        if (await file.exists()) await file.delete();
      });
      await onFilesRemoved?.call([variant.path]);
    }
    _forgetCardPaths({storagePathKey(variant.path)});
    _removeVariant(id);
    _tasks.removeWhere(
      (t) =>
          !t.unfinished &&
          t.source.key == variant.source.key &&
          t.quality?.id == variant.quality.id &&
          t.quality?.codec == variant.quality.codec,
    );
    await _save();
    _notify();
  }

  Future<void> registerLegacy(CacheVariant variant) =>
      registerLegacyBatch(Stream.value(variant));

  final Map<String, Future<void>> _materialDiscovery = {};
  Future<void> discoverMaterial(CacheSource source) async {
    final discover = MediaCacheHooks.discover;
    if (discover == null || _closed || _disposed) return;
    final existing = _materialDiscovery[source.key];
    if (existing != null) return existing;
    final operation = () async {
      final variants = await discover(source);
      if (!_closed && !_disposed) await registerMaterial(variants);
    }();
    _materialDiscovery[source.key] = operation;
    try {
      await operation;
    } catch (error) {
      debugPrint('Reusable media discovery deferred: ${error.runtimeType}');
    } finally {
      _materialDiscovery.remove(source.key);
    }
  }

  /// Register the original sealed files in place. No copy, mux or media probe.
  /// Completion history is not fabricated for feature-owned downloads.
  Future<void> registerMaterial(List<CacheVariant> variants) {
    final operation = _legacyRegistrations.catchError((Object _) {}).then((
      _,
    ) async {
      await initialize();
      if (_closed || _disposed) return;
      var changed = false;
      for (final variant in variants) {
        final revision = _variantRevision;
        if (!await _valid(variant) || _closed || _disposed) continue;
        final previous = _variants[variant.id];
        if (previous != null &&
            (previous.pendingDelete || await _valid(previous))) {
          continue;
        }
        if (revision != _variantRevision ||
            _variants[variant.id]?.pendingDelete == true) {
          continue;
        }
        // Legacy audio manifests may first expose the same sealed file without
        // a stream id. Upgrade that entry when exact track metadata arrives.
        final peers = _variants.values
            .where(
              (v) =>
                  v.id != variant.id &&
                  v.source.key == variant.source.key &&
                  v.content == variant.content &&
                  AppStorageService.samePath(v.path, variant.path),
            )
            .toList();
        if (variant.quality.id == 'audio' &&
            peers.any((v) => v.quality.id != 'audio')) {
          continue;
        }
        for (final peer in peers) {
          if (peer.quality.id == 'audio' && variant.quality.id != 'audio') {
            _removeVariant(peer.id);
          }
        }
        _putVariant(variant);
        changed = true;
      }
      if (changed) {
        await _save();
        _notify();
      }
    });
    _legacyRegistrations = operation;
    return operation;
  }

  Future<MaterializedMediaLease?> acquireMaterial(
    VideoItem item,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    String? qualityId,
    String? codec,
    bool isolatedTrack = false,
  }) async {
    await initialize();
    final source = CacheSource.fromItem(item);
    if (source == null || _closed) return null;
    for (final variant in variantsFor(source.key)) {
      if (isolatedTrack && variant.completeMedia) continue;
      final revision = source.ref.cloudDrive?.revision;
      if (revision != null &&
          revision.isNotEmpty &&
          variant.quality.revision != revision) {
        continue;
      }
      if (qualityId != null && variant.quality.id != qualityId ||
          codec != null && variant.quality.codec != codec ||
          requirement != MediaMaterializationRequirement.audioOnly &&
              !source.isPodcast &&
              targetHeight != null &&
              (variant.quality.resolutionHeight ?? 0) < targetHeight ||
          !variant.completeMedia &&
              variant.content !=
                  switch (requirement) {
                    MediaMaterializationRequirement.videoFrames =>
                      CacheContent.video,
                    MediaMaterializationRequirement.audioOnly =>
                      CacheContent.audio,
                    MediaMaterializationRequirement.completeMedia =>
                      CacheContent.media,
                  }) {
        continue;
      }
      if (!await _valid(variant) ||
          variant.pendingDelete ||
          _closed ||
          !identical(_variants[variant.id], variant)) {
        continue;
      }
      _leases[variant.id] = (_leases[variant.id] ?? 0) + 1;
      return MaterializedMediaLease(
        videoId: item.id,
        audioPath: variant.content == CacheContent.video ? null : variant.path,
        videoPath:
            variant.content == CacheContent.audio ||
                item.type == MediaType.audio
            ? null
            : variant.path,
        completePath: variant.completeMedia ? variant.path : null,
        qualityId: int.tryParse(variant.quality.id),
        width: variant.quality.width,
        height: variant.quality.height,
        retainedOffline: variant.completeMedia,
        onRelease: () async {
          final left = (_leases[variant.id] ?? 1) - 1;
          if (left <= 0) {
            _leases.remove(variant.id);
          } else {
            _leases[variant.id] = left;
          }
          if (variant.pendingDelete) await deleteVariant(variant.id);
          _notify();
        },
      );
    }
    return null;
  }

  void _putVariant(CacheVariant variant) {
    _variants[variant.id] = variant;
    _variantRevision++;
  }

  void _removeVariant(String id) {
    if (_variants.remove(id) != null) _variantRevision++;
  }

  (String, String) _legacyIdentity(CacheVariant variant) => (
    variant.source.key,
    Platform.isWindows
        ? p.normalize(variant.path).toLowerCase()
        : storagePathKey(variant.path),
  );

  /// Keep the single-item validation/upgrade rules, but publish one durable
  /// generation for an import. A failing producer still saves its valid prefix.
  Future<void> registerLegacyBatch(Stream<CacheVariant> variants) {
    final operation = _legacyRegistrations
        .catchError((Object _) {})
        .then((_) => _registerLegacyBatch(variants));
    _legacyRegistrations = operation;
    return operation;
  }

  Future<void> _registerLegacyBatch(Stream<CacheVariant> variants) async {
    await initialize();
    if (_closed) return;
    var changed = false;
    final byPath = <(String, String), List<CacheVariant>>{};
    var indexedRevision = -1;
    try {
      await for (final variant in variants) {
        if (_closed) break;
        if (_variants.containsKey(variant.id) || !await _valid(variant)) {
          continue;
        }
        // A download may publish while filesystem validation is awaiting I/O.
        if (_closed) break;
        if (_variants.containsKey(variant.id)) continue;
        // Ordinary downloads/deletion may mutate the registry between yields.
        // Rebuild only then, and otherwise update this batch's index in O(1).
        if (indexedRevision != _variantRevision) {
          byPath.clear();
          for (final existing in _variants.values) {
            byPath
                .putIfAbsent(_legacyIdentity(existing), () => [])
                .add(existing);
          }
          indexedRevision = _variantRevision;
        }
        final identity = _legacyIdentity(variant);
        final peers = byPath.putIfAbsent(identity, () => []);
        final existing = peers.firstOrNull;
        if (existing != null) {
          if (existing.pendingDelete ||
              existing.quality.id != 'legacy' ||
              variant.quality.id == 'legacy') {
            continue;
          }
          _removeVariant(existing.id);
          peers.removeAt(0);
        }
        _putVariant(variant);
        peers.add(variant);
        indexedRevision = _variantRevision;
        changed = true;
      }
    } finally {
      if (changed) {
        await _save();
        _notify();
      }
    }
  }

  Future<MaterializedMediaLease?> acquire(
    VideoItem item, {
    String? qualityId,
  }) async {
    await initialize();
    if (_closed) return null;
    final source = CacheSource.fromItem(item);
    if (source == null) return null;
    if (source.isBilibili && qualityId == '-1') qualityId = 'legacy';
    for (final variant in variantsFor(source.key)) {
      final revision = source.ref.cloudDrive?.revision;
      if (revision != null &&
          revision.isNotEmpty &&
          variant.quality.revision != revision) {
        continue;
      }
      if (!variant.completeMedia) continue;
      if (qualityId != null && variant.quality.id != qualityId) continue;
      if (!await _valid(variant)) {
        if (await File(variant.path).parent.exists()) {
          await forgetDeletedFiles([variant.path]);
        } else {
          variant.available = false;
          _notify();
        }
        continue;
      }
      if (variant.pendingDelete || !identical(_variants[variant.id], variant)) {
        continue;
      }
      _leases[variant.id] = (_leases[variant.id] ?? 0) + 1;
      _notify();
      return MaterializedMediaLease(
        videoId: item.id,
        retainedOffline: true,
        audioPath: variant.path,
        videoPath: item.type == MediaType.audio ? null : variant.path,
        completePath: variant.path,
        qualityId: int.tryParse(variant.quality.id),
        qualityLabel: variant.quality.label,
        width: variant.quality.width,
        height: variant.quality.height,
        onRelease: () async {
          final left = (_leases[variant.id] ?? 1) - 1;
          if (left <= 0) {
            _leases.remove(variant.id);
          } else {
            _leases[variant.id] = left;
          }
          if (variant.pendingDelete) await deleteVariant(variant.id);
          _notify();
        },
      );
    }
    return null;
  }

  /// A synchronous UI/export projection; acquisition still validates the file
  /// and takes a lease before any reader uses it.
  CacheVariant? completeBilibiliVariant(
    VideoItem item, {
    bool ownedDownload = false,
  }) {
    final source = CacheSource.fromItem(item);
    if (source == null || !source.isBilibili) return null;
    for (final variant in variantsFor(source.key)) {
      if (!variant.completeMedia ||
          variant.bytes <= 0 ||
          (ownedDownload &&
              (item.bilibiliDownloadPath == null ||
                  !AppStorageService.samePath(
                    variant.path,
                    item.bilibiliDownloadPath!,
                  )))) {
        continue;
      }
      try {
        final stat = File(variant.path).statSync();
        if (stat.type == FileSystemEntityType.file &&
            stat.size == variant.bytes) {
          return variant;
        }
      } on FileSystemException {
        // A disconnected custom directory remains in the durable registry.
      }
    }
    return null;
  }

  /// A complete transferable Bilibili/cloud rendition of the card's revision.
  /// Partial playback data and podcast downloads are not export payloads.
  CacheVariant? completeExportVariant(VideoItem item) {
    final source = CacheSource.fromItem(item);
    if (source == null || source.isPodcast) return null;
    final revision = source.ref.cloudDrive?.revision;
    for (final variant in variantsFor(source.key)) {
      if (!variant.completeMedia ||
          variant.bytes <= 0 ||
          (revision != null && revision.isNotEmpty &&
              variant.quality.revision != revision)) {
        continue;
      }
      try {
        final stat = File(variant.path).statSync();
        if (stat.type == FileSystemEntityType.file && stat.size == variant.bytes) {
          return variant;
        }
      } on FileSystemException {
        // Keep unavailable removable-storage records for later recovery.
      }
    }
    return null;
  }

  Future<MaterializedMediaLease?> acquireVariant(
    CacheVariant variant,
    VideoItem item,
  ) async {
    await initialize();
    final revision = item.sourceRef?.cloudDrive?.revision;
    if (_closed ||
        CacheSource.fromItem(item)?.key != variant.source.key ||
        !identical(_variants[variant.id], variant) ||
        variant.pendingDelete ||
        !variant.completeMedia ||
        variant.bytes <= 0 ||
        (revision != null && revision.isNotEmpty &&
            variant.quality.revision != revision) ||
        !await _valid(variant)) {
      return null;
    }
    if (!identical(_variants[variant.id], variant) || variant.pendingDelete) {
      return null;
    }
    _leases[variant.id] = (_leases[variant.id] ?? 0) + 1;
    return MaterializedMediaLease(
      videoId: item.id,
      retainedOffline: true,
      audioPath: variant.path,
      videoPath: item.type == MediaType.audio ? null : variant.path,
      completePath: variant.path,
      qualityId: int.tryParse(variant.quality.id),
      qualityLabel: variant.quality.label,
      width: variant.quality.width,
      height: variant.quality.height,
      onRelease: () async {
        final left = (_leases[variant.id] ?? 1) - 1;
        if (left <= 0) {
          _leases.remove(variant.id);
        } else {
          _leases[variant.id] = left;
        }
        if (variant.pendingDelete) await deleteVariant(variant.id);
        _notify();
      },
    );
  }

  Future<CacheReadSlice?> readBilibili(
    MediaSourceRef source,
    StreamItem stream,
    bool video,
    String? range,
  ) async {
    final key = cacheDigest('bilibili:${source.bvid}:${source.cid}');
    for (final variant in variantsFor(key)) {
      if (variant.content !=
              (video ? CacheContent.video : CacheContent.audio) ||
          variant.quality.id != '${stream.id}' ||
          variant.quality.codec.isEmpty ||
          variant.quality.codec != stream.codecs) {
        continue;
      }
      final slice = await CacheFileAccess.read(
        File(variant.path),
        resourceStart: 0,
        availableBytes: variant.bytes,
        total: variant.bytes,
        range: range,
        completeResource: true,
        contentType: video ? 'video/mp4' : 'audio/mp4',
      );
      if (slice != null) return slice;
    }
    for (final task in _tasks.where(
      (t) => t.source.key == key && !_cancelling.contains(t.id),
    )) {
      final raw = task.resume[video ? 'video' : 'audio'];
      if (raw is! Map || task.workDirectory == null) continue;
      final state = DownloadPartResumeState.fromJson(
        Map<String, dynamic>.from(raw),
      );
      final total = state.totalBytes;
      if (state.streamId != stream.id ||
          state.codecid != stream.codecid ||
          state.codecs != stream.codecs ||
          total == null) {
        continue;
      }
      final files = state.rangeParts.isEmpty
          ? [
              DownloadRangePartState(
                start: 0,
                endInclusive: total - 1,
                downloadedBytes: state.downloadedBytes,
                tempPath: state.tempPath,
              ),
            ]
          : state.rangeParts;
      for (final part in files) {
        final path = part.tempPath;
        if (path == null || !p.isWithin(task.workDirectory!, path)) continue;
        final result = await CacheFileAccess.read(
          File(path),
          resourceStart: part.start,
          availableBytes: part.downloadedBytes,
          total: total,
          range: range,
          allowPrefix: true,
          completeResource: part.start == 0 && part.downloadedBytes == total,
          streamComplete: task.state == CacheTaskState.completed,
          contentType: state.mimeType ?? 'application/octet-stream',
        );
        if (result != null) return result;
      }
    }
    return null;
  }

  Future<CacheReadSlice?> readCloud(
    CloudDrivePlaybackDescriptor source,
    Uri uri,
    String? range,
  ) async {
    final key = cloudDriveSourceKey(
      providerId: source.providerId,
      remoteAccountId: source.remoteAccountId,
      driveId: source.driveId,
      fileId: source.fileId,
    );
    if (source.transport == CloudDriveTransport.progressive &&
        uri == source.upstreamUri) {
      for (final variant in variantsFor(key)) {
        if (!variant.completeMedia ||
            variant.quality.id != source.quality.id ||
            variant.quality.revision != source.revision) {
          continue;
        }
        final slice = await CacheFileAccess.read(
          File(variant.path),
          resourceStart: 0,
          availableBytes: variant.bytes,
          total: variant.bytes,
          range: range,
          completeResource: true,
          contentType: source.mediaKind == CloudDriveMediaKind.audio
              ? 'audio/mp4'
              : 'video/mp4',
        );
        if (slice != null) return slice;
      }
    }
    for (final task in _tasks.where(
      (t) =>
          t.source.key == key &&
          !_cancelling.contains(t.id) &&
          t.quality?.revision == source.revision &&
          t.quality?.id == source.quality.id,
    )) {
      final parts = task.resume['cloudParts'];
      if (parts is! Map || task.workDirectory == null) continue;
      final resource = cacheDigest(
        '${source.revision}\n${source.quality.id}\n$uri',
      );
      for (final entry in parts.entries.where(
        (entry) =>
            entry.key == resource ||
            entry.value is Map && (entry.value as Map)['resource'] == resource,
      )) {
        final raw = entry.value;
        if (raw is! Map ||
            raw['path'] is! String ||
            !p.isWithin(task.workDirectory!, raw['path'] as String)) {
          continue;
        }
        final result = await CacheFileAccess.read(
          File(raw['path'] as String),
          resourceStart: (raw['start'] as num).toInt(),
          availableBytes: (raw['bytes'] as num).toInt(),
          total: (raw['total'] as num).toInt(),
          range: range,
          completeResource: raw['complete'] == true,
          streamComplete: task.state == CacheTaskState.completed,
          allowPrefix: source.transport != CloudDriveTransport.hls,
        );
        if (result != null) return result;
      }
    }
    return null;
  }

  void _forgetCardPaths(Set<String> paths) {
    for (final candidates in _discoveredCardCandidates.values) {
      for (final variant in candidates) {
        if (paths.contains(storagePathKey(variant.path))) variant.available = false;
      }
    }
  }

  Future<void> forgetDeletedFiles(Iterable<String> paths) async {
    final gone = paths.map(storagePathKey).toSet();
    _forgetCardPaths(gone);
    for (final variant
        in _variants.values
            .where((v) => gone.contains(storagePathKey(v.path)))
            .toList()) {
      await onBeforeDelete?.call(variant);
    }
    _variants.removeWhere((_, v) => gone.contains(storagePathKey(v.path)));
    _variantRevision++;
    await onFilesRemoved?.call(paths.toList());
    for (final task in _tasks.where(
      (t) => t.unfinished && t.workDirectory != null,
    )) {
      if (paths.any(
        (path) =>
            p.isWithin(task.workDirectory!, path) ||
            AppStorageService.samePath(task.workDirectory!, path),
      )) {
        task.resume = {};
        task.received = 0;
        task.total = null;
        task.fraction = null;
        task.state = CacheTaskState.paused;
        task.error = '断点已清理，可以重新开始缓存';
      }
    }
    _repairCompletedTasks();
    await _save();
    _notify();
  }

  String? storageDeletionBlockedReason(String path) {
    final key = storagePathKey(path);
    return protectedPaths.any(
          (protected) =>
              storagePathKey(protected) == key || p.isWithin(protected, path),
        )
        ? '媒体正在播放、缓存或供其他任务使用。'
        : null;
  }

  Future<void> prepareStorageDeletion(String path) async {
    if (storageDeletionBlockedReason(path) != null) {
      throw StateError('媒体文件正在使用');
    }
    for (final variant in _variants.values.where(
      (v) => AppStorageService.samePath(v.path, path),
    )) {
      variant.pendingDelete = true;
      await _save();
      _notify();
      if ((_leases[variant.id] ?? 0) > 0 || _inUse(path)) {
        variant.pendingDelete = false;
        await _save();
        _notify();
        throw StateError('媒体刚开始使用，已跳过删除');
      }
      await onBeforeDelete?.call(variant);
    }
  }

  void _repairCompletedTasks() {
    for (final task in _tasks.where(
      (t) => t.state == CacheTaskState.completed,
    )) {
      if (!_variants.values.any(
        (v) =>
            v.completeMedia &&
            v.source.key == task.source.key &&
            v.quality.id == task.quality?.id &&
            v.quality.codec == task.quality?.codec,
      )) {
        task.state = CacheTaskState.failed;
        task.error = '本地缓存已移除，可重新缓存';
        task.fraction = null;
        task.received = 0;
        task.total = null;
      }
    }
  }

  Future<bool> _valid(CacheVariant v) async {
    final file = File(v.path);
    try {
      final stat = await file.stat();
      if (v.bytes <= 0 ||
          stat.type != FileSystemEntityType.file ||
          stat.size != v.bytes) {
        return false;
      }
      v.modifiedMicros = stat.modified.microsecondsSinceEpoch;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  List<StorageAssetDescriptor> get storageAssets {
    final protected = protectedPaths;
    return [
      if (_file != null)
        StorageAssetDescriptor(
          assetKey: 'media-cache-index',
          origin: StorageOrigin.appData,
          category: StorageCategory.metadata,
          policy: StorageCleanupPolicy.featureManaged,
          title: '媒体缓存任务与版本索引',
          paths: [_file!.path, '${_file!.path}.bak', '${_file!.path}.next'],
          role: StorageAssetRole.checkpoint,
        ),
      for (final v in _variants.values)
        StorageAssetDescriptor(
          assetKey: 'media-cache:${v.id}',
          origin: v.source.isPodcast
              ? StorageOrigin.podcast
              : v.source.isBilibili
              ? StorageOrigin.bilibili
              : StorageOrigin.cloudDrive,
          sourceTags: [
            v.source.isPodcast
                ? StorageOrigin.podcast
                : v.source.isBilibili
                ? StorageOrigin.bilibili
                : StorageOrigin.cloudDrive,
          ],
          category: StorageCategory.offlineDownloads,
          policy: protected.contains(v.path)
              ? StorageCleanupPolicy.protected
              : StorageCleanupPolicy.savedContent,
          title: '${v.source.title} · ${v.quality.label}',
          paths: [v.path],
          protected: protected.contains(v.path),
          protection: '正在播放或供其他任务使用',
          role: StorageAssetRole.assembledMedia,
          explicitDelete: true,
          ownerIds: [v.source.itemId],
          version: v.createdAt,
        ),
      for (final t in _tasks)
        if (t.workDirectory != null)
          StorageAssetDescriptor(
            assetKey: 'media-cache-task:${t.id}',
            origin: t.source.isPodcast
                ? StorageOrigin.podcast
                : t.source.isBilibili
                ? StorageOrigin.bilibili
                : StorageOrigin.cloudDrive,
            category: StorageCategory.downloadTemp,
            policy: t.unfinished
                ? StorageCleanupPolicy.featureManaged
                : StorageCleanupPolicy.regenerableCache,
            title: '${t.source.title} · 缓存断点',
            directory: t.workDirectory,
            role: StorageAssetRole.resumePart,
            explicitDelete: t.unfinished,
            protected:
                _runs.containsKey(t.id) ||
                (t.workDirectory != null && _inUse(t.workDirectory!)),
            protection: '缓存任务仍在写入文件',
            deletable: !t.unfinished,
            ownerIds: [t.id],
            version: t.generation,
          ),
    ];
  }

  Future<void> _cleanTaskDirectory(CacheTask task) async {
    final path = task.workDirectory;
    if (path == null ||
        p.basename(path) != 'cache_${task.id}' ||
        _inUse(path)) {
      return;
    }
    final dir = Directory(path);
    try {
      await MediaCacheNative.directory(path, forget: true);
      await CacheFileAccess.mutate(path, () async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
    } on FileSystemException {
      /* idle maintenance retries */
    }
  }

  Future<void> _maintain() async {
    if (_maintaining) return _maintenanceDone?.future;
    _maintaining = true;
    final done = _maintenanceDone = Completer<void>();
    try {
      for (final v in _variants.values.toList()) {
        if (v.pendingDelete) {
          await deleteVariant(v.id);
        }
      }
      await refreshAvailability();
      for (final t in _tasks.where((t) => !t.unfinished).toList()) {
        await _cleanTaskDirectory(t);
      }
      if (_foreground &&
          observeNetwork &&
          !(await Connectivity().checkConnectivity()).contains(
            ConnectivityResult.none,
          )) {
        await _wakeNetwork();
      }
    } catch (_) {
      /* unavailable external storage is not a deletion command */
    } finally {
      _maintaining = false;
      _maintenanceDone = null;
      done.complete();
    }
  }

  Future<void> reconcile() => _maintain();

  void _syncMaintenanceTimer() {
    if (_closed || _disposed || !_foreground) {
      _maintenanceTimer?.cancel();
      _maintenanceTimer = null;
      return;
    }
    _maintenanceTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_closed && _foreground) unawaited(_maintain());
    });
  }

  Future<void> _wakeNetwork({
    Set<NetworkScope>? scopes,
    bool includeSystem = true,
  }) async {
    if (_closed || !_ready) return;
    for (final task in _tasks.toList()) {
      // Recheck after the preceding resume: a user may have paused this task
      // while another transfer was releasing its socket.
      if (scopes != null && !scopes.contains(_scopeFor(task.source))) continue;
      if (task.state == CacheTaskState.waitingNetwork ||
          includeSystem && task.state == CacheTaskState.waitingSystem) {
        await resume(task.id);
      }
    }
  }

  NetworkScope _scopeFor(CacheSource source) => source.isPodcast
      ? NetworkSites.forPodcast(
          Uri.tryParse(source.ref.podcast!.mediaUrl) ?? Uri(),
        )
      : source.isBilibili
      ? NetworkScope.bilibili
      : NetworkScope.cloudDrive;

  Future<void> _networkChanged(NetworkSettingsChange change) async {
    if (_closed || !_ready || change.deviceChanged) return;
    final affected = _tasks
        .where(
          (task) =>
              change.scopes.contains(_scopeFor(task.source)) &&
              const {
                CacheTaskState.resolving,
                CacheTaskState.downloading,
                CacheTaskState.retrying,
              }.contains(task.state),
        )
        .toList();
    // Mark every affected task before awaiting any shutdown, so a later
    // manual pause cannot be overwritten by a stale snapshot of the queue.
    await Future.wait(
      affected.map(
        (task) => pause(task.id, state: CacheTaskState.waitingNetwork),
      ),
    );
    await _wakeNetwork(scopes: change.scopes, includeSystem: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Reconcile the whole cache only while visible. Downloads still finalize
    // and clean their own task directories; leases still finish pending
    // deletions, and targeted filesystem events remain subscribed.
    _syncMaintenanceTimer();
    if (_foreground) {
      unawaited(refreshAvailability().catchError((Object _) {}));
      unawaited(_wakeNetwork());
    }
  }

  Future<void> flush() => _save();
  Future<void> flushPreferencesForTrial() async {
    await _initializing;
    await _save();
  }

  Future<bool> patchPreferencesForTrial(
    Map<String, dynamic> fields,
    bool restoring,
  ) async {
    if (!_ready || _file == null) return false;
    await _writes;
    final current = {'preferences': preferences.toJson()};
    final next = restoring
        ? TrialFieldMask.restore(current, fields, const {'preferences'})
        : TrialFieldMask.apply(current, fields);
    preferences = MediaCachePreferences.fromJson(
      Map<String, dynamic>.from(next['preferences'] as Map? ?? {}),
    );
    await _save();
    _notify();
    return true;
  }

  Future<void> reloadPreferencesForTrial() async {
    if (!_ready || _file == null) return;
    await _writes;
    final raw = await readStorageJson(_file!);
    preferences = MediaCachePreferences.fromJson(
      Map<String, dynamic>.from((raw as Map?)?['preferences'] as Map? ?? {}),
    );
    _notify();
  }

  Future<void> _save() {
    final file = _file;
    if (file == null || !_ready) return Future.value();
    _persistTimer?.cancel();
    _persistTimer = null;
    final snapshot = AppStorageService.instance.encodePaths({
      'version': 1,
      'preferences': preferences.toJson(),
      'tasks': _tasks.map((t) => t.toJson()).toList(),
      'variants': _variants.values.map((v) => v.toJson()).toList(),
    });
    final operation = _writes.catchError((Object _) {}).then((_) async {
      try {
        await compute(_writeMediaCacheSnapshot, (
          file.path,
          snapshot as Object,
        ));
        persistenceError = null;
      } catch (error) {
        persistenceError = _errorText(error);
        _notify();
        rethrow;
      }
    });
    _writes = operation;
    return operation;
  }

  void _scheduleProgress() {
    _progressTimer ??= Timer(const Duration(milliseconds: 250), () {
      _progressTimer = null;
      _notify();
    });
    _persistTimer ??= Timer(const Duration(seconds: 1), () {
      _persistTimer = null;
      unawaited(_save().catchError((Object _) {}));
    });
  }

  void _notify() {
    if (_disposed) return;
    _syncFileWatches();
    if (observeNetwork && _nativeCount != _runs.length) {
      _nativeCount = _runs.length;
      unawaited(MediaCacheNative.setActive(_nativeCount));
    }
    final token = Object.hashAll([
      ...protectedPaths.map(storagePathKey),
      for (final v in _variants.values)
        Object.hash(v.id, v.pendingDelete, v.available),
      for (final t in _tasks)
        Object.hash(
          t.id,
          t.generation,
          t.workDirectory,
          _runs.containsKey(t.id),
        ),
    ]);
    if (token != _storageToken) {
      _storageToken = token;
      storageChanges.value++;
      onChanged?.call();
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _publishCardStates();
    super.notifyListeners();
  }

  static bool _diskError(Object error) =>
      error is FileSystemException &&
      const {
        2,
        3,
        5,
        13,
        19,
        28,
        30,
        39,
        112,
      }.contains(error.osError?.errorCode);
  static String _errorText(Object error) {
    final message = '$error'
        .replaceAll(RegExp(r'https?://[^\s)]+'), '[媒体来源]')
        .replaceAll(
          RegExp(r'(Cookie|Authorization)[^\n]*', caseSensitive: false),
          '',
        );
    return message.substring(0, math.min(220, message.length));
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _availabilityTimer?.cancel();
    await Future.wait(
      _fileWatches.values.map((watch) => watch.cancel()).toList(),
    );
    _fileWatches.clear();
    await Future.wait(_availabilityChecks.values.toList());
    _maintenanceTimer?.cancel();
    for (final task in _tasks.where(
      (t) => t.state.running || t.state == CacheTaskState.queued,
    )) {
      task.state = CacheTaskState.queued;
      task.generation++;
      _tokens[task.id]?.cancel('缓存服务正在关闭');
    }
    await Future.wait(_runs.values.toList());
    await _legacyRegistrations.catchError((Object _) {});
    await _maintenanceDone?.future;
    if (observeNetwork) {
      _nativeCount = 0;
      await MediaCacheNative.setActive(0);
    }
    for (final task in _tasks.where((t) => t.workDirectory != null)) {
      await MediaCacheNative.directory(task.workDirectory!, forget: false);
    }
    await _save();
    await _connectivity?.cancel();
    await _network?.cancel();
    if (observeNetwork) WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void dispose() {
    _disposed = true;
    _closed = true;
    _availabilityTimer?.cancel();
    for (final watch in _fileWatches.values) {
      unawaited(watch.cancel());
    }
    _fileWatches.clear();
    for (final token in _tokens.values) {
      token.cancel('服务已释放');
    }
    _progressTimer?.cancel();
    _persistTimer?.cancel();
    _maintenanceTimer?.cancel();
    unawaited(_connectivity?.cancel());
    unawaited(_network?.cancel());
    if (observeNetwork) WidgetsBinding.instance.removeObserver(this);
    if (identical(instance, this)) instance = null;
    storageChanges.dispose();
    super.dispose();
  }
}
