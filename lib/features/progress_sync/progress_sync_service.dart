import 'package:video_player_app/utils/app_branding.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../models/media_source_ref.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../models/podcast_source_ref.dart';
import '../podcasts/podcast_runtime.dart';
import '../podcasts/podcast_models.dart';
import '../podcasts/podcast_sync_codec.dart';
import '../../services/community_media_input.dart';
import '../../services/library_service.dart';
import '../../utils/serial_task_queue.dart';
import 'progress_sync_lan.dart';
import 'progress_sync_models.dart';
import 'progress_sync_store.dart';
import 'progress_sync_webdav.dart';
import '../portable_transfer/portable_folder_transfer.dart';
import '../portable_transfer/legacy_download_export_policy.dart';
import 'folder_transfer_models.dart';
import 'folder_transfer_service.dart';
import 'folder_sync_models.dart';
import 'folder_sync_state.dart';
import 'folder_sync_coordinator.dart';

class _SyncGroup {
  _SyncGroup({
    required this.id,
    required this.name,
    required this.key,
    this.collectionId,
    this.fromDevice = '',
    this.lastSyncedAt,
    Set<String>? peers,
    this.settings = const FolderSyncSettings(),
    Map<String, int>? settingsClock,
    Map<String, int>? settingsConflictClock,
    this.awaitingCatalog = false,
    this.catalogCount = 0,
  }) : peers = peers ?? {},
       settingsClock = settingsClock ?? {},
       settingsConflictClock = settingsConflictClock ?? {};
  final String id;
  String name;
  final List<int> key;
  String? collectionId;
  String fromDevice;
  DateTime? lastSyncedAt;
  final Set<String> peers;
  FolderSyncSettings settings;
  final Map<String, int> settingsClock, settingsConflictClock;
  bool awaitingCatalog;
  int catalogCount;
  Map<String, dynamic> toJson() => {
    'edition': kApplicationId,
    'id': id,
    'name': name,
    'key': base64Encode(key),
    'collectionId': collectionId,
    'fromDevice': fromDevice,
    'lastSyncedAt': lastSyncedAt?.millisecondsSinceEpoch,
    'peers': peers.toList(),
    'settings': settings.toJson(),
    'settingsClock': settingsClock,
    'settingsConflictClock': settingsConflictClock,
    'awaitingCatalog': awaitingCatalog,
    'catalogCount': catalogCount,
  };
  factory _SyncGroup.fromJson(
    Map<String, dynamic> j, {
    bool allowLegacyLocal = false,
  }) {
    if (j['edition'] != kApplicationId &&
        !(allowLegacyLocal && j['edition'] == null)) {
      throw const FormatException('同步信息属于其他版本或需要重新生成');
    }
    final key = base64Decode(j['key'] as String);
    if (key.length != 32 || (j['id'] as String).length > 100) {
      throw const FormatException('同步码无效');
    }
    return _SyncGroup(
      id: j['id'] as String,
      name: (j['name'] as String).substring(
        0,
        min(200, (j['name'] as String).length),
      ),
      key: key,
      collectionId: j['collectionId'] as String?,
      fromDevice: j['fromDevice'] as String? ?? '',
      lastSyncedAt: j['lastSyncedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (j['lastSyncedAt'] as num).toInt(),
            )
          : null,
      peers: (j['peers'] as List?)?.whereType<String>().toSet(),
      settings: FolderSyncSettings.fromJson(
        Map<String, dynamic>.from(j['settings'] as Map? ?? {}),
      ),
      settingsClock: Map<String, int>.from(j['settingsClock'] as Map? ?? {}),
      settingsConflictClock: Map<String, int>.from(
        j['settingsConflictClock'] as Map? ?? {},
      ),
      awaitingCatalog: j['awaitingCatalog'] == true,
      catalogCount: (j['catalogCount'] as int? ?? 0).clamp(0, 200000),
    );
  }
}

class _PodcastSyncEpisode {
  const _PodcastSyncEpisode(this.episode, this.adapter);
  final PodcastEpisode episode;
  final VideoItem? adapter;
}

/// One local-first merge engine, used by both peer-to-peer and WebDAV routes.
/// Remote changes never seek the active player or replace the library snapshot.
class ProgressSyncService extends ChangeNotifier with WidgetsBindingObserver {
  ProgressSyncService({
    required this.library,
    String? Function()? activeMediaId,
    ProgressSyncStore? store,
    this.enableNetwork = true,
  }) : _activeMediaId = activeMediaId ?? (() => null),
       _store = store ?? FileProgressSyncStore();
  final LibraryService library;
  final String? Function() _activeMediaId;
  final ProgressSyncStore _store;
  final bool enableNetwork;
  final SerialTaskQueue _operations = SerialTaskQueue();
  final Map<String, _SyncGroup> _groups = {};
  final Map<String, SyncProgressEvent> _events = {};
  final Map<String, Map<String, dynamic>> _envelopes = {};
  final Map<String, String> _trustedKeys = {}, _pairedNames = {};
  final Map<String, Map<String, String>> _mediaKeys = {};
  final Map<String, Map<String, _PodcastSyncEpisode>> _podcastEpisodes = {};
  final Map<String, Set<String>> _excludedNodes = {},
      _excludedProgressKeys = {};
  final Map<String, Map<String, dynamic>> _fingerprints = {};
  final Map<String, String> _localSignatures = {};
  final Map<String, Map<String, int>> _localClocks = {};
  int _sequence = 0;
  final Set<String> _webDavKnown = {}, _pruneRemote = {};
  int _trustRevision = 0;
  final _cipher = AesGcm.with256bits();
  String _deviceId = '', _deviceName = '';
  List<int> _privateKey = [];
  bool _initialized = false,
      _storageLoadFailed = false,
      _enabled = false,
      _busy = false,
      _disposed = false,
      _applying = false;
  String _status = '开启后，自动同步已关联文件夹的进度';
  String? _error, _webDavStatus, _connectionAddress;
  DateTime? _lastSyncedAt;
  Future<void>? _initializing;
  Future<void>? _syncing;
  bool _syncAgain = false;
  Timer? _timer, _captureTimer;
  ProgressSyncLan? _lan;
  ProgressSyncWebDav? _webDav;
  ProgressSyncWebDavConfig? _webDavConfig;
  FolderTransferService? _folderTransfer;
  Map<String, dynamic>? _savedFolderTransfers;
  late final FolderSyncCoordinator _folders = FolderSyncCoordinator(
    library: library,
    deviceId: _deviceId,
    deviceName: _deviceName,
    contentKey: _contentKey,
    rootImportBlocked: _folderRootIsImporting,
  );

  bool _folderRootIsImporting(String rootId) => folderTransfers.any(
    (task) =>
        task.syncOptions['importStarted'] == true &&
        (task.targetCollectionId == rootId ||
            task.syncOptions['targetCollectionId'] == rootId),
  );
  final Map<String, Map<String, dynamic>> _folderEnvelopes = {};
  final Map<String, int> _podcastPeerVersions = {};
  final Map<String, Map<String, dynamic>> _podcastEnvelopes = {};
  final Set<String> _pausedFolderFiles = {};
  final Set<String> _revokedFolderGroups = {};
  bool _requestingFolderFiles = false;
  Timer? _folderChangeTimer;
  PodcastRuntime? _observedPodcast;

  List<FolderTransferTask> get folderTransfers {
    if (_folderTransfer != null) return _folderTransfer!.tasks;
    final result = <FolderTransferTask>[];
    for (final raw in _savedFolderTransfers?['tasks'] as List? ?? []) {
      try {
        result.add(
          FolderTransferTask.fromJson(Map<String, dynamic>.from(raw as Map)),
        );
      } catch (_) {
        /* One damaged historical task does not hide the others. */
      }
    }
    return result;
  }

  bool get initialized => _initialized;

  /// Read only the global switch for an initial-settings export. Do not call
  /// init(): it creates a device identity and can start discovery/sync.
  Future<Map<String, dynamic>> exportSettingsSnapshot() async => {
    'enabled': _initialized && !_storageLoadFailed
        ? _enabled
        : (await _store.read())?['enabled'] == true,
  };
  String get deviceId => _deviceId;
  bool get enabled => _enabled;
  bool get busy => _busy;
  String get deviceName => _deviceName;
  String get status => _status;
  String? get error => _error;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  ProgressSyncLan? get lan => _lan;
  String? get connectionAddress => _connectionAddress;
  Map<String, String> get pairedDevices => Map.unmodifiable(_pairedNames);
  ProgressSyncWebDavConfig? get webDavConfig => _webDavConfig;
  String? get webDavStatus => _webDavStatus;
  List<SyncLocalFolder> get localFolders {
    final result = <SyncLocalFolder>[];
    final seen = <String>{};
    void walk(VideoCollection folder, String prefix) {
      if (!seen.add(folder.id) || folder.isRecycled) return;
      final label = prefix.isEmpty ? folder.name : '$prefix / ${folder.name}';
      result.add(
        SyncLocalFolder(
          id: folder.id,
          name: label,
          mediaCount: library.mediaInFolderTree(folder.id).length,
        ),
      );
      for (final id in folder.childrenIds) {
        final child = library.getCollection(id);
        if (child != null) walk(child, label);
      }
    }

    for (final folder in library.collections) {
      walk(folder, '');
    }
    return result;
  }

  List<SyncFolderBinding> get bindings => [
    for (final group in _groups.values)
      if (group.collectionId != null)
        SyncFolderBinding(
          groupId: group.id,
          collectionId: group.collectionId!,
          name: library.getCollection(group.collectionId!)?.name ?? group.name,
          matchedCount: (_mediaKeys[group.id] ?? {}).values.toSet().length,
          lastSyncedAt: group.lastSyncedAt,
          mode: group.settings.mode,
          conflictCount: _folders
              .state(group.id, settings: group.settings)
              .issues
              .length,
          pendingCount: _folders.missingCount(group.id),
          status: _pausedFolderFiles.contains(group.id) ? '文件传输已暂停' : '',
        ),
  ];
  List<SyncFolderInvitation> get invitations => [
    for (final group in _groups.values)
      if (group.collectionId == null)
        SyncFolderInvitation(
          groupId: group.id,
          name: group.name,
          fromDevice: group.fromDevice,
          mediaCount: _events.values
              .where((e) => e.groupId == group.id)
              .map((e) => e.mediaKey)
              .toSet()
              .length,
        ),
  ];
  List<SyncProgressConflict> get conflicts {
    final result = <SyncProgressConflict>[];
    for (final group in _groups.values.where((g) => g.collectionId != null)) {
      final keys = (_mediaKeys[group.id] ?? {}).values.toSet();
      for (final key in keys) {
        final heads = _heads(group.id, key);
        if (heads.length > 1 &&
            heads.map((e) => _semanticSignature(e.value)).toSet().length > 1) {
          result.add(
            SyncProgressConflict(
              id: '${group.id}|$key',
              title: heads.first.title,
              choices: heads,
            ),
          );
        }
      }
    }
    return result;
  }

  String _semanticSignature(SyncProgressValue v) =>
      '${v.positionMs}|${v.completed}|${v.continueEnrolled}';

  Future<void> init() => _initializing ??= _init();
  Future<void> _init() async {
    try {
      final saved = await _store.read();
      if (saved != null && saved['version'] != 1) {
        throw const FormatException('同步数据版本不受支持');
      }
      _deviceId = saved?['deviceId'] as String? ?? const Uuid().v4();
      _deviceName = saved?['deviceName'] as String? ?? _defaultName();
      _folders.restore(
        Map<String, dynamic>.from(saved?['folderCatalogs'] as Map? ?? {}),
      );
      _pausedFolderFiles.addAll(
        (saved?['pausedFolderFiles'] as List? ?? []).whereType<String>(),
      );
      _revokedFolderGroups.addAll(
        (saved?['revokedFolderGroups'] as List? ?? []).whereType<String>(),
      );
      _pruneRemote.addAll(
        (saved?['pruneRemote'] as List? ?? []).whereType<String>().where(
          (id) => id.isNotEmpty && id.length <= 256,
        ),
      );
      if (saved?['folderTransfers'] case final Map state) {
        _savedFolderTransfers = Map<String, dynamic>.from(state);
      }
      _enabled = saved?['enabled'] == true;
      if (saved?['privateKey'] case final String key) {
        _privateKey = base64Decode(key);
      } else {
        _privateKey = await (await X25519().newKeyPair())
            .extractPrivateKeyBytes();
      }
      if (saved != null) {
        _sequence = (saved['sequence'] as num?)?.toInt() ?? 0;
        _localSignatures.addAll(
          Map<String, String>.from(saved['localSignatures'] as Map? ?? {}),
        );
        for (final entry in (saved['localClocks'] as Map? ?? {}).entries) {
          _localClocks[entry.key as String] = Map<String, int>.from(
            entry.value as Map,
          );
        }
        _trustedKeys.addAll(
          Map<String, String>.from(saved['trustedKeys'] as Map? ?? {}),
        );
        _pairedNames.addAll(
          Map<String, String>.from(saved['pairedNames'] as Map? ?? {}),
        );
        _pairedNames.removeWhere((id, _) => !_trustedKeys.containsKey(id));
        for (final id in _trustedKeys.keys) {
          _pairedNames.putIfAbsent(id, () => '我的设备');
        }
        for (final value in saved['groups'] as List? ?? []) {
          final g = _SyncGroup.fromJson(
            Map<String, dynamic>.from(value as Map),
            allowLegacyLocal: true,
          );
          _groups[g.id] = g;
        }
        for (final value in saved['fingerprints'] as List? ?? []) {
          final m = Map<String, dynamic>.from(value as Map);
          _fingerprints[m['id'] as String] = m;
        }
        for (final value in saved['envelopes'] as List? ?? []) {
          await _receiveEnvelope(
            Map<String, dynamic>.from(value as Map),
            allowLegacyLocal: true,
          );
        }
        if (saved['webDav'] case final Map config) {
          _webDavConfig = ProgressSyncWebDavConfig(
            url: config['url'] as String,
            username: config['username'] as String,
            password: config['password'] as String,
          );
          _webDav = ProgressSyncWebDav(config: _webDavConfig!);
        }
      }
      for (final group in _groups.values) {
        await _cancelForbiddenFolderTransfers(group);
      }
      _initialized = true;
      library.addProgressObserver(_onProgress);
      library.addListener(_onLibraryChanged);
      library.activityRevision.addListener(_onLibraryChanged);
      _observedPodcast = PodcastRuntime.instance
        ..addListener(_onPodcastChanged);
      WidgetsBinding.instance.addObserver(this);
      if (_enabled) {
        await _start();
      }
      await _persist();
    } catch (_) {
      _storageLoadFailed = true;
      _enabled = false;
      _timer?.cancel();
      await _lan?.stop();
      _error = '无法读取同步记录，请检查系统凭据存储后重试';
      _status = '同步暂不可用';
      _initialized = true;
    }
    _notify();
  }

  static String _defaultName() {
    final host = Platform.localHostname.trim();
    final device = host.isEmpty
        ? '我的${Platform.operatingSystem}设备'
        : host.substring(0, min(40, host.length));
    return '$device · $kAppDisplayName';
  }

  void _requireStorage() {
    if (_storageLoadFailed) {
      throw const FormatException('同步记录暂不可用，请重启应用后重试');
    }
  }

  Future<void> _persist() {
    _requireStorage();
    return _store.write({
      'version': 1,
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'privateKey': base64Encode(_privateKey),
      'enabled': _enabled,
      'trustedKeys': _trustedKeys,
      'sequence': _sequence,
      'localSignatures': _localSignatures,
      'localClocks': _localClocks,
      'pairedNames': _pairedNames,
      'groups': _groups.values.map((g) => g.toJson()).toList(),
      'envelopes': _envelopes.values.toList(),
      'fingerprints': _fingerprints.values.toList(),
      'folderCatalogs': _folders.toJson(),
      'pausedFolderFiles': _pausedFolderFiles.toList(),
      'revokedFolderGroups': _revokedFolderGroups.toList(),
      'pruneRemote': _pruneRemote.toList(),
      if (_folderTransfer != null || _savedFolderTransfers != null)
        'folderTransfers': _folderTransfer?.toJson() ?? _savedFolderTransfers,
      if (_webDavConfig case final c?)
        'webDav': {
          'url': c.url,
          'username': c.username,
          'password': c.password,
        },
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    await init();
    _requireStorage();
    if (_enabled == value) return;
    _enabled = value;
    _error = null;
    await _persist();
    if (value) {
      await _start();
    } else {
      _trustRevision++;
      _timer?.cancel();
      await _folderTransfer?.pause();
      await _lan?.stop();
      _status = '同步已关闭';
    }
    _notify();
  }

  Future<void> renameDevice(String name) async {
    await init();
    _requireStorage();
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 40) {
      throw const FormatException('设备名称请使用 1–40 个字');
    }
    _deviceName = trimmed;
    await _persist();
    if (_enabled) {
      _trustRevision++;
      await _folderTransfer?.pause();
      await _lan?.stop();
      _lan?.dispose();
      _lan = null;
      await _start();
    }
    _notify();
  }

  ProgressSyncLan _ensureLan() => _lan ??= ProgressSyncLan(
    deviceId: _deviceId,
    deviceName: _deviceName,
    privateKeyBytes: Uint8List.fromList(_privateKey),
    trustedPeerPublicKeys: _trustedKeys,
    onTrustChanged: (keys) async {
      _trustRevision++;
      final removed = _trustedKeys.keys
          .where((id) => !keys.containsKey(id))
          .toSet();
      _trustedKeys
        ..clear()
        ..addAll(keys);
      for (final peer in _lan?.nearbyDevices ?? <LanSyncDevice>[]) {
        if (keys.containsKey(peer.id)) _pairedNames[peer.id] = peer.name;
      }
      _pairedNames.removeWhere((id, _) => !keys.containsKey(id));
      for (final group in _groups.values) {
        group.peers.removeWhere((id) => !keys.containsKey(id));
      }
      for (final task in _folderTransfer?.tasks ?? <FolderTransferTask>[]) {
        if (removed.contains(task.peerId) && (task.isActive || task.canRetry)) {
          await _folderTransfer!.cancel(task.id);
        }
      }
      await _persist();
      _notify();
    },
    onReadChanges: (peerId) => _operations.enqueue(() => _outgoing(peerId)),
    onChanges: (peerId, changes) {
      final revision = _trustRevision;
      return _operations.enqueue(
        () => _receive(peerId, changes, trustRevision: revision),
      );
    },
  )..addListener(_notify);

  FolderTransferService _ensureFolderTransfer() {
    final lan = _ensureLan();
    _folderTransfer ??= FolderTransferService(
      library: library,
      lan: lan,
      buildLink: _buildTransferredFolderLink,
      receiveLink: _receiveTransferredFolderLink,
      persistState: _persist,
      peerNames: () => _pairedNames,
      knownContentKeys: _transferContentKeys,
      sourceFingerprints: _transferSourceFingerprints,
      receivePolicy: _receiveFolderPolicy,
      stableIds: (collectionId) =>
          _catalogForCollection(collectionId)?.localBindings ?? {},
      localIds: (collectionId) =>
          _catalogForCollection(collectionId)?.nodeBindings ?? {},
      suppressedIds: (collectionId) {
        final catalog = _catalogForCollection(collectionId);
        if (catalog == null) return {};
        return {
          for (final event in catalog.activeEvents)
            if (catalog.isSuppressed(event.node.id)) event.node.id,
        };
      },
      protectedIds: _protectedIncomingFolderNodes,
      syncMetadata: (collectionId) => {
        'events':
            _catalogForCollection(collectionId)?.activeEvents
                .where(
                  (event) =>
                      !(_excludedNodes[_groupForCollection(collectionId)?.id] ??
                              const <String>{})
                          .contains(event.node.id),
                )
                .map((e) => e.toJson())
                .toList() ??
            [],
      },
      onImported: _adoptTransferredFolder,
      prepareCatalog: (collectionId, peerId) async {
        await _buildTransferredFolderLink(collectionId, peerId, {});
      },
      savedState: _savedFolderTransfers,
    )..addListener(_notify);
    lan.onControl = (peerId, method, payload) => method.startsWith('sync.')
        ? _handleFolderControl(peerId, method, payload)
        : _folderTransfer!.handleControl(peerId, method, payload);
    return _folderTransfer!;
  }

  Future<void> _start() async {
    _timer?.cancel();
    if (enableNetwork) {
      _ensureLan();
      try {
        await _lan!.start();
        await _ensureFolderTransfer().start(lan: _lan);
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        int interfaceRank(NetworkInterface i) {
          final name = i.name.toLowerCase();
          if (RegExp(r'wi-?fi|wlan|^en0$|^wlp').hasMatch(name)) return 0;
          if (RegExp(
            r'vmware|vmnet|virtual|vpn|tun|tap|loopback',
          ).hasMatch(name)) {
            return 3;
          }
          return 1;
        }

        interfaces.sort((a, b) => interfaceRank(a).compareTo(interfaceRank(b)));
        final addresses = interfaces
            .expand((i) => i.addresses)
            .where((a) => !a.isLoopback)
            .toList();
        if (addresses.isNotEmpty) {
          _connectionAddress = '${addresses.first.address}:${_lan!.port}';
        }
      } catch (_) {
        _error = '局域网暂不可用，可稍后重试或使用已有存储';
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(syncNow());
    });
    _status = '等待已关联设备上线';
    unawaited(syncNow());
  }

  Future<void> discover() async {
    await init();
    if (!_enabled) await setEnabled(true);
    await _lan?.discover();
    _notify();
  }

  Future<void> connectAddress(String address) async {
    if (!_enabled) await setEnabled(true);
    await _lan?.connectAddress(address);
    _notify();
  }

  /// One request for both "receive a new folder" and "link a folder I have".
  /// The receiver chooses; this call only publishes the request.
  Future<void> proposeFolderSync(String peerId, String collectionId) =>
      sendFolder(collectionId, peerId);

  Future<void> acceptFolderSync(
    String proposalId, {
    required FolderSyncAcceptChoice choice,
    String? existingCollectionId,
    String? destinationParentId,
  }) async {
    await init();
    _requireStorage();
    if (!_enabled) await setEnabled(true);
    if (choice == FolderSyncAcceptChoice.linkExisting) {
      if (existingCollectionId == null || existingCollectionId.isEmpty) {
        throw const FormatException('请选择要关联的文件夹');
      }
      await _ensureFolderTransfer().accept(
        proposalId,
        existingCollectionId: existingCollectionId,
      );
      return;
    }
    _validateNewFolderParent(destinationParentId);
    await _ensureFolderTransfer().accept(
      proposalId,
      destinationParentId: destinationParentId,
    );
  }

  Future<void> sendFolder(String collectionId, String peerId) async {
    await init();
    _requireStorage();
    if (!_trustedKeys.containsKey(peerId)) {
      throw const FormatException('请先连接另一台设备');
    }
    if (!_groups.values.any((g) => g.collectionId == collectionId)) {
      // Resolve folder-scope restrictions before preparing a large package.
      _checkNoOverlap(collectionId);
    }
    if (!_enabled) await setEnabled(true);
    if (_folderTransfer == null) throw const FormatException('局域网暂不可用');
    final group = _groupForCollection(collectionId);
    await _folderTransfer!.sendFolder(
      collectionId,
      peerId,
      syncOptions: {
        if (group?.peers.contains(peerId) == true) ...{
          'groupId': group!.id,
          'automatic': true,
          'includeSidecars': group.settings.includeSidecars,
          'minFreeBytes': group.settings.minFreeBytes,
        },
      },
    );
  }

  Future<void> acceptFolderTransfer(
    String id, {
    String? destinationParentId,
  }) async {
    await init();
    _requireStorage();
    if (!_enabled) await setEnabled(true);
    _validateNewFolderParent(destinationParentId);
    await _ensureFolderTransfer().accept(
      id,
      destinationParentId: destinationParentId,
    );
  }

  void _validateNewFolderParent(String? parentId) {
    if (parentId == null) return;
    final parent = library.getCollection(parentId);
    if (parent == null || parent.isRecycled) {
      throw const FormatException('保存位置已不存在，请重新选择');
    }
    final roots = _groups.values
        .map((group) => group.collectionId)
        .whereType<String>()
        .toSet();
    final seen = <String>{};
    String? cursor = parentId;
    while (cursor != null && seen.add(cursor)) {
      if (roots.contains(cursor)) {
        throw const FormatException('不能接收到已关联的文件夹内，请选择其他保存位置');
      }
      cursor = library.getCollection(cursor)?.parentId;
    }
  }

  Future<void> rejectFolderTransfer(String id) async {
    await init();
    _requireStorage();
    await _ensureFolderTransfer().reject(id);
  }

  Future<void> cancelFolderTransfer(String id) async {
    await init();
    _requireStorage();
    final task = folderTransfers.where((task) => task.id == id).firstOrNull;
    if (task?.syncOptions['automatic'] == true &&
        task?.syncOptions['groupId'] is String) {
      _pausedFolderFiles.add(task!.syncOptions['groupId'] as String);
    }
    await _ensureFolderTransfer().cancel(id);
  }

  Future<void> retryFolderTransfer(String id) async {
    await init();
    _requireStorage();
    if (!_enabled) await setEnabled(true);
    await _ensureFolderTransfer().retry(id);
  }

  Future<void> dismissFolderTransfer(String id) async {
    await init();
    _requireStorage();
    await _ensureFolderTransfer().dismiss(id);
  }

  Future<void> _seedTransferFingerprints(
    Map<String, PortableFolderFingerprint> fingerprints,
  ) async {
    for (final entry in fingerprints.entries) {
      final item = library.getVideo(entry.key), value = entry.value;
      if (item == null ||
          (item.bilibiliDownloadPath ?? item.path) != value.path ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value.sha256)) {
        continue;
      }
      final stat = await File(value.path).stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != value.size ||
          stat.modified.millisecondsSinceEpoch != value.modifiedMs) {
        continue;
      }
      _fingerprints[item.id] = {
        'id': item.id,
        'path': value.path,
        'size': value.size,
        'modified': value.modifiedMs,
        'key': 'sha256:${value.size}:${value.sha256}',
      };
    }
  }

  Future<Set<String>> _transferContentKeys(String collectionId) =>
      _operations.enqueue(() async {
        final result = <String>{};
        for (final item in library.mediaInFolderTree(collectionId)) {
          if (item.isRecycled || item.isTransient) continue;
          final path = item.bilibiliDownloadPath ?? item.path;
          final stat = await File(path).stat();
          final cached = _fingerprints[item.id];
          final key =
              cached?['path'] == path &&
                  cached?['size'] == stat.size &&
                  cached?['modified'] == stat.modified.millisecondsSinceEpoch
              ? (cached?['key'] as String?)
              : null;
          if (key != null && key.startsWith('sha256:')) result.add(key);
        }
        await _persist();
        return result;
      });

  Map<String, PortableFolderFingerprint> _transferSourceFingerprints(
    String collectionId,
  ) => {
    for (final item in library.mediaInFolderTree(collectionId))
      if (_fingerprints[item.id] case final data?)
        if (data['path'] is String &&
            data['size'] is int &&
            data['modified'] is int &&
            data['key'] is String &&
            (data['key'] as String).startsWith('sha256:'))
          item.id: PortableFolderFingerprint(
            path: data['path'] as String,
            size: data['size'] as int,
            modifiedMs: data['modified'] as int,
            sha256: (data['key'] as String).split(':').last,
          ),
  };

  Future<Map<String, dynamic>> _buildTransferredFolderLink(
    String collectionId,
    String peerId,
    Map<String, PortableFolderFingerprint> fingerprints,
  ) async {
    await _operations.enqueue(() => _seedTransferFingerprints(fingerprints));
    await createFolderBinding(collectionId);
    return _operations.enqueue(() async {
      final group = _groups.values.firstWhere(
        (g) => g.collectionId == collectionId,
      );
      group.peers.add(peerId);
      await _indexGroup(group);
      await _captureGroup(group);
      await _persist();
      return {
        'version': 1,
        'group': {
          'edition': kApplicationId,
          'id': group.id,
          'name': group.name,
          'key': base64Encode(group.key),
          'fromDevice': _deviceName,
          'settings': group.settings.toJson(),
          'settingsClock': group.settingsClock,
        },
      };
    });
  }

  Future<void> _receiveTransferredFolderLink(
    Map<String, dynamic> descriptor,
    String peerId,
    String collectionId,
    Map<String, PortableFolderFingerprint> fingerprints,
  ) async {
    if (!_trustedKeys.containsKey(peerId) || descriptor['version'] != 1) {
      throw const FormatException('设备连接已失效，请重新连接');
    }
    final fresh = _SyncGroup.fromJson(
      Map<String, dynamic>.from(descriptor['group'] as Map),
    );
    if (_revokedFolderGroups.contains(fresh.id)) {
      throw const FormatException('此文件夹已停止同步，请重新关联');
    }
    await _operations.enqueue(() async {
      if (!_trustedKeys.containsKey(peerId) ||
          _revokedFolderGroups.contains(fresh.id)) {
        throw const FormatException('此文件夹的设备关联已停止，请重新关联');
      }
      await _seedTransferFingerprints(fingerprints);
      final existing = _groups[fresh.id];
      if (existing != null && !listEquals(existing.key, fresh.key)) {
        throw const FormatException('文件夹同步信息不一致');
      }
      if (library.getCollection(collectionId) == null) {
        throw const FormatException('接收的文件夹已不存在');
      }
      final group = existing ?? fresh;
      final wasBound = group.collectionId != null;
      if (group.collectionId != null && group.collectionId != collectionId) {
        throw const FormatException('此来源已关联其他文件夹');
      }
      if (group.collectionId == null) _checkNoOverlap(collectionId);
      group.collectionId = collectionId;
      group.peers.add(peerId);
      _groups[group.id] = group;
      _webDavKnown.clear();
      await _indexGroup(group);
      await _captureGroup(group, initial: !wasBound);
      await _persist();
    });
    _notify();
    await syncNow();
  }

  _SyncGroup? _groupForCollection(String collectionId) => _groups.values
      .where((group) => group.collectionId == collectionId)
      .firstOrNull;
  FolderSyncState? _catalogForCollection(String collectionId) {
    final group = _groupForCollection(collectionId);
    return group == null
        ? null
        : _folders.state(group.id, settings: group.settings);
  }

  FolderSyncSettings folderSettings(String collectionId) =>
      _groupForCollection(collectionId)?.settings ?? const FolderSyncSettings();
  Map<String, String> folderDevices(String collectionId) => {
    _deviceId: _deviceName,
    for (final id in _groupForCollection(collectionId)?.peers ?? <String>{})
      id: _pairedNames[id] ?? '我的设备',
  };
  List<FolderSyncIssue> get folderSyncIssues => [
    for (final group in _groups.values.where(
      (group) => group.collectionId != null,
    )) ...[
      ..._folders.state(group.id, settings: group.settings).issues,
      ..._folders.localIssues(group.id),
      if (group.settingsConflictClock.isNotEmpty)
        FolderSyncIssue(
          groupId: group.id,
          nodeId: 'settings',
          title: group.name,
          reason: 'settingsConflict',
          choices: const [],
        ),
    ],
  ];

  VideoItem? mediaForSyncIssue(String groupId, String nodeId) {
    final group = _groups[groupId];
    if (group?.collectionId == null) return null;
    final localId = _folders.state(groupId).localIdForNode(nodeId);
    if (localId == null) return null;
    final item = library.getVideo(localId);
    return item == null || item.isRecycled ? null : item;
  }

  Future<void> updateFolderSettings(
    String collectionId,
    FolderSyncSettings settings,
  ) async {
    await init();
    _requireStorage();
    final validated = FolderSyncSettings.fromJson(settings.toJson());
    final group = _groupForCollection(collectionId);
    if (group == null) throw const FormatException('请先关联此文件夹');
    if (validated.mode == FolderSyncMode.oneWay &&
        !folderDevices(collectionId).containsKey(validated.sourceDeviceId)) {
      throw const FormatException('请选择此文件夹的一台关联设备作为来源');
    }
    await _operations.enqueue(() async {
      group.settings = validated;
      for (final entry in group.settingsConflictClock.entries) {
        group.settingsClock[entry.key] = max(
          group.settingsClock[entry.key] ?? 0,
          entry.value,
        );
      }
      group.settingsClock[_deviceId] =
          (group.settingsClock[_deviceId] ?? 0) + 1;
      group.settingsConflictClock.clear();
      _folders.state(group.id, settings: validated);
      _pausedFolderFiles.remove(group.id);
      await _cancelForbiddenFolderTransfers(group);
      await _captureAll();
      await _persist();
    });
    _notify();
    await syncNow();
  }

  Future<void> _cancelForbiddenFolderTransfers(_SyncGroup group) async {
    final collectionId = group.collectionId;
    final policy = group.settings;
    for (final task in folderTransfers.where(
      (task) =>
          (task.syncOptions['groupId'] == group.id ||
              (task.syncDescriptor?['group'] as Map?)?['id'] == group.id ||
              (collectionId != null &&
                  !task.incoming &&
                  task.sourceCollectionId == collectionId) ||
              (collectionId != null &&
                  task.incoming &&
                  (task.targetCollectionId == collectionId ||
                      task.syncOptions['targetCollectionId'] ==
                          collectionId))) &&
          (task.isActive || task.canRetry) &&
          (policy.mode == FolderSyncMode.progressOnly ||
              (policy.mode == FolderSyncMode.oneWay &&
                  (task.incoming
                      ? task.peerId != policy.sourceDeviceId
                      : _deviceId != policy.sourceDeviceId))),
    )) {
      await _cancelFolderTask(task);
    }
  }

  Future<void> _cancelFolderTask(FolderTransferTask task) async {
    final transfer = _folderTransfer;
    if (transfer != null) {
      await transfer.cancel(task.id);
    } else {
      // Settings remain editable while sync is disabled. Retire the saved
      // paused task too, otherwise enabling later would resume old policy.
      final saved = _savedFolderTransfers;
      if (saved != null) {
        _savedFolderTransfers = {
          ...saved,
          'tasks': [
            for (final raw in saved['tasks'] as List? ?? [])
              if (raw is Map && raw['id'] == task.id)
                {
                  ...raw,
                  'phase': FolderTransferPhase.cancelled.name,
                  'accepted': false,
                }
              else
                raw,
          ],
        };
      }
    }
  }

  Future<void> syncFolderNow(String collectionId) async {
    await init();
    if (_groupForCollection(collectionId) == null) {
      throw const FormatException('请先关联此文件夹');
    }
    _pausedFolderFiles.remove(_groupForCollection(collectionId)!.id);
    if (!_enabled) await setEnabled(true);
    await syncNow();
    await _requestMissingFolderFiles(
      manualGroupId: _groupForCollection(collectionId)?.id,
    );
  }

  Future<void> removeSyncedItem(
    String collectionId,
    String itemId, {
    bool everywhere = false,
  }) async {
    await init();
    _requireStorage();
    final group = _groupForCollection(collectionId);
    if (group == null) throw const FormatException('关联文件夹已不存在');
    if (everywhere &&
        (group.settings.mode == FolderSyncMode.progressOnly ||
            (group.settings.mode == FolderSyncMode.oneWay &&
                group.settings.sourceDeviceId != _deviceId))) {
      throw const FormatException('当前同步方式仅支持从本机移除');
    }
    await _operations.enqueue(() async {
      final catalog = _folders.state(group.id, settings: group.settings);
      if (itemId == collectionId) {
        await library.recycleSyncItem(itemId);
        _pausedFolderFiles.add(group.id);
      } else {
        final nodeId = catalog.nodeIdForLocal(itemId);
        if (nodeId == null) throw const FormatException('条目尚未完成识别，请同步后重试');
        if (everywhere) {
          catalog.updateSettings(group.settings.copyWith(syncDeletes: true));
          catalog.capture(const [], explicitlyDeletedLocalIds: {itemId});
          catalog.updateSettings(group.settings);
        } else {
          catalog.suppress(nodeId);
        }
        await library.recycleSyncItem(itemId);
      }
      await _refreshFolderEnvelopes();
      await _persist();
    });
    _notify();
    unawaited(syncNow());
  }

  Future<void> restoreLocallyRemovedItems(String collectionId) async {
    await init();
    _requireStorage();
    final group = _groupForCollection(collectionId);
    if (group == null) return;
    await _operations.enqueue(() async {
      final catalog = _folders.state(group.id, settings: group.settings);
      final ids = <String>[];
      for (final node in catalog.suppressedNodeIds.toList()) {
        final id = catalog.localIdForNode(node);
        if (id != null &&
            (library.getVideo(id)?.isRecycled == true ||
                library.getCollection(id)?.isRecycled == true)) {
          ids.add(id);
        }
        catalog.unsuppress(node);
      }
      if (ids.isNotEmpty) await library.restoreFromRecycleBin(ids);
      _pausedFolderFiles.remove(group.id);
      await _persist();
    });
    await syncFolderNow(collectionId);
  }

  Future<void> relinkSyncedMedia(
    String groupId,
    String nodeId,
    String path,
  ) async {
    await init();
    _requireStorage();
    final group = _groups[groupId];
    if (group?.collectionId == null) throw const FormatException('关联文件夹已不存在');
    await _operations.enqueue(() async {
      final catalog = _folders.state(groupId, settings: group!.settings);
      final id = catalog.localIdForNode(nodeId);
      final item = id == null ? null : library.getVideo(id);
      if (item == null || item.isRecycled) {
        throw const FormatException('媒体条目已不存在');
      }
      final expected = catalog.appliedNode(nodeId)?.contentKey;
      final probe = VideoItem.fromJson({...item.toJson(), 'path': path});
      final actual = await _contentKey(probe);
      if (actual == null) throw const FormatException('无法读取所选文件');
      if (expected != null && expected != actual) {
        throw const FormatException('所选文件与原视频内容不同，请重新选择');
      }
      item.path = path;
      await library.renameItem(item.id, item.title);
      await _indexGroup(group);
      await _persist();
    });
    _notify();
    await syncNow();
  }

  Future<void> resolveFolderSyncConflict(
    String groupId,
    String nodeId,
    String eventId, {
    bool keepBoth = false,
  }) async {
    await init();
    _requireStorage();
    final group = _groups[groupId];
    if (group?.collectionId == null) return;
    await _operations.enqueue(() async {
      final catalog = _folders.state(groupId, settings: group!.settings);
      final choices = catalog
          .heads(nodeId)
          .where((event) => !event.deleted)
          .toList();
      final preserveParent =
          keepBoth &&
          folderSyncIssues.any(
            (issue) =>
                issue.nodeId == nodeId &&
                issue.reason == 'deleteHasLiveDescendants',
          );
      if (preserveParent) {
        final heads = catalog.heads(nodeId);
        final clock = folderSyncMergeClocks(heads.map((event) => event.clock));
        clock[_deviceId] = max(clock[_deviceId] ?? 0, _sequence) + 1;
        _sequence = clock[_deviceId]!;
        catalog.merge(
          FolderSyncEvent(
            id: const Uuid().v4(),
            groupId: groupId,
            deviceId: _deviceId,
            clock: clock,
            node: heads.first.node,
            deviceName: _deviceName,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else if (keepBoth && choices.length > 1) {
        if (choices.any(
          (event) => event.node.kind != FolderSyncNodeKind.media,
        )) {
          throw const FormatException('请选择文件夹使用的名称和位置');
        }
        // Fork each additional version into a separate logical identity. Its
        // content remains at the originating device until requested normally.
        final winner =
            choices.where((event) => event.id == eventId).firstOrNull ??
            choices.first;
        for (final choice in choices.where((event) => event.id != winner.id)) {
          final fork = FolderSyncEvent(
            id: const Uuid().v4(),
            groupId: groupId,
            deviceId: _deviceId,
            clock: {_deviceId: ++_sequence},
            node: choice.node.copyWith(
              id: const Uuid().v4(),
              name:
                  '${choice.node.name.substring(0, min(1016, choice.node.name.length))}（保留副本）',
            ),
            deviceName: _deviceName,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          catalog.merge(fork);
        }
        catalog.resolve(nodeId, winner.id);
      } else {
        catalog.resolve(nodeId, eventId);
      }
      await _folders.apply(groupId, group.collectionId!, group.settings);
      await _refreshFolderEnvelopes();
      await _persist();
    });
    _notify();
    await syncNow();
  }

  Future<Map<String, dynamic>?> _receiveFolderPolicy(
    String peerId,
    Map<String, dynamic> offer,
  ) async {
    final group = _groups[offer['groupId']];
    if (group == null ||
        !group.peers.contains(peerId) ||
        group.collectionId == null) {
      return null;
    }
    final root = library.getCollection(group.collectionId!);
    if (root == null || root.isRecycled) return null;
    final limit = group.settings.maxAutoTransferBytes;
    return {
      'groupId': group.id,
      'targetCollectionId': group.collectionId,
      'automatic': true,
      'autoAccept':
          group.settings.mode != FolderSyncMode.progressOnly &&
          group.settingsConflictClock.isEmpty &&
          !_pausedFolderFiles.contains(group.id) &&
          (group.settings.mode != FolderSyncMode.oneWay ||
              group.settings.sourceDeviceId == peerId) &&
          (limit == 0 || (offer['estimatedBytes'] as int? ?? 0) <= limit),
      'maxAutoTransferBytes': limit,
      'minFreeBytes': group.settings.minFreeBytes,
      'bytesPerSecondLimit': group.settings.bytesPerSecondLimit,
    };
  }

  Future<Set<String>> _protectedIncomingFolderNodes(
    String collectionId,
    Map<String, dynamic> metadata,
  ) => _operations.enqueue(() async {
    final group = _groupForCollection(collectionId);
    if (group == null) return <String>{};
    if (group.settings.mode == FolderSyncMode.progressOnly) {
      throw const FormatException('当前仅同步进度，已停止接收媒体内容');
    }
    // This runs before the importer touches the library. Capture local edits
    // first so a full resend cannot silently overwrite a concurrent branch.
    await _folders.capture(
      group.id,
      collectionId,
      group.settings,
      beforeImport: true,
    );
    final catalog = _folders.state(group.id, settings: group.settings);
    final rawEvents = metadata['events'] as List? ?? [];
    if (rawEvents.length > 100000) throw const FormatException('目录记录过多');
    final incoming = rawEvents
        .map(
          (raw) =>
              FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
        )
        .toList();
    if (incoming.any((event) => event.groupId != group.id)) {
      throw const FormatException('目录不属于此关联');
    }
    final rejected = {
      if (group.settings.mode == FolderSyncMode.oneWay)
        for (final event in incoming)
          if (event.deviceId != group.settings.sourceDeviceId) event.node.id,
    };
    catalog.mergeAll(
      incoming.where(
        (event) =>
            group.settings.mode != FolderSyncMode.oneWay ||
            event.deviceId == group.settings.sourceDeviceId,
      ),
    );
    await _refreshFolderEnvelopes();
    await _persist();
    return {
      ...rejected,
      for (final issue in catalog.issues) issue.nodeId,
      for (final event in catalog.activeEvents)
        if (catalog.isSuppressed(event.node.id)) event.node.id,
    };
  });

  Future<void> _adoptTransferredFolder(
    String peerId,
    String collectionId,
    Map<String, dynamic> descriptor,
    Map<String, String> stableToLocalIds,
  ) async {
    if (!_trustedKeys.containsKey(peerId)) {
      throw const FormatException('设备连接已失效');
    }
    final fresh = _SyncGroup.fromJson(
      Map<String, dynamic>.from(descriptor['group'] as Map),
    );
    await _operations.enqueue(() async {
      if (!_trustedKeys.containsKey(peerId)) {
        throw const FormatException('设备连接已失效');
      }
      final existing = _groups[fresh.id];
      if (_revokedFolderGroups.contains(fresh.id) &&
          descriptor['allowRebind'] != true) {
        if (descriptor['cancelled'] == true) return;
        throw const FormatException('此文件夹已取消关联，请重新接受发送');
      }
      if (existing == null && descriptor['cancelled'] == true) return;
      if (descriptor['allowRebind'] == true) {
        _revokedFolderGroups.remove(fresh.id);
      }
      if (existing != null &&
          (!listEquals(existing.key, fresh.key) ||
              (existing.collectionId != null &&
                  existing.collectionId != collectionId))) {
        throw const FormatException('文件夹关联不一致');
      }
      if (existing == null) _checkNoOverlap(collectionId);
      final group = existing ?? fresh;
      final incomingCatalog = Map<String, dynamic>.from(
        descriptor['catalog'] as Map? ?? {},
      );
      if (group.settings.mode == FolderSyncMode.progressOnly) {
        throw const FormatException('当前仅同步进度，已停止接收媒体内容');
      }
      if (group.settings.mode == FolderSyncMode.oneWay) {
        if (peerId != group.settings.sourceDeviceId) {
          throw const FormatException('当前只接收来源设备的媒体内容');
        }
        incomingCatalog['events'] = [
          for (final raw in incomingCatalog['events'] as List? ?? [])
            if (raw is Map && raw['deviceId'] == group.settings.sourceDeviceId)
              raw,
        ];
      }
      group.collectionId = collectionId;
      group.peers.add(peerId);
      _groups[group.id] = group;
      await _folders.adopt(
        group.id,
        collectionId,
        stableToLocalIds,
        incomingCatalog,
        group.settings,
      );
      await _refreshFolderEnvelopes();
      await _persist();
    });
  }

  Future<Map<String, dynamic>> _handleFolderControl(
    String peerId,
    String method,
    Map<String, dynamic> payload,
  ) async {
    if (!_enabled ||
        !_trustedKeys.containsKey(peerId) ||
        method != 'sync.need') {
      throw const FormatException('同步请求无效');
    }
    final group = _groups[payload['groupId']];
    final requested = payload['nodes'];
    if (group == null ||
        !group.peers.contains(peerId) ||
        group.collectionId == null ||
        requested is! List ||
        requested.length > 1000 ||
        group.settings.mode == FolderSyncMode.progressOnly ||
        group.settingsConflictClock.isNotEmpty ||
        _pausedFolderFiles.contains(group.id)) {
      return {'accepted': false};
    }
    if (group.settings.mode == FolderSyncMode.oneWay &&
        group.settings.sourceDeviceId != _deviceId) {
      return {'accepted': false};
    }
    final catalog = _folders.state(group.id, settings: group.settings);
    final selected = <String>{};
    final overrides = <String, String>{};
    var bytes = 0;
    for (final nodeId in requested.whereType<String>()) {
      var node = catalog.safeNodes[nodeId];
      var local = catalog.localIdForNode(nodeId);
      // A resolved "keep both" fork may refer to content still held under its
      // original logical identity at this peer. Reuse that verified content.
      if (node != null && local == null) {
        local = catalog.nodeBindings.entries
            .where(
              (entry) =>
                  library.getVideo(entry.value) != null &&
                  catalog.appliedNode(entry.key)?.contentKey == node.contentKey,
            )
            .map((entry) => entry.value)
            .firstOrNull;
      }
      final item = local == null ? null : library.getVideo(local);
      if (node == null ||
          item == null ||
          item.isRecycled ||
          catalog.isSuppressed(nodeId)) {
        continue;
      }
      final path = library.relativeFolderPath(
        group.collectionId!,
        item.parentId,
      );
      if (!_folders.allowed(
        group.settings,
        path.isEmpty ? item.title : '$path/${item.title}',
        extension: node.extension,
      )) {
        continue;
      }
      final actualKey = await _contentKey(item);
      if (actualKey == null || actualKey != node.contentKey) continue;
      final cloudBytes = item.sourceRef?.cloudDrive == null
          ? null
          : await _folders.cloudTransferBytes(item);
      if (item.sourceRef?.cloudDrive != null && cloudBytes == null) continue;
      selected.add(item.id);
      overrides[item.id] = nodeId;
      bytes += cloudBytes ?? node.size;
    }
    if (selected.isEmpty) return {'accepted': false};
    final manager = _ensureFolderTransfer();
    if (manager.tasks.any(
      (task) =>
          !task.incoming &&
          task.peerId == peerId &&
          task.sourceCollectionId == group.collectionId &&
          (task.isActive || task.canRetry),
    )) {
      return {'accepted': true};
    }
    await manager.sendFolder(
      group.collectionId!,
      peerId,
      syncOptions: {
        'groupId': group.id,
        'automatic': true,
        'includeMediaIds': selected.toList(),
        'estimatedBytes': bytes,
        'includeSidecars': group.settings.includeSidecars,
        'minFreeBytes': group.settings.minFreeBytes,
        'stableOverrides': overrides,
      },
    );
    return {'accepted': true};
  }

  Future<void> _requestMissingFolderFiles({String? manualGroupId}) async {
    if (_requestingFolderFiles || !_enabled || _disposed || _lan == null) {
      return;
    }
    _requestingFolderFiles = true;
    try {
      for (final group in _groups.values.toList()) {
        if (group.collectionId == null ||
            group.settings.mode == FolderSyncMode.progressOnly ||
            group.settingsConflictClock.isNotEmpty ||
            _pausedFolderFiles.contains(group.id)) {
          continue;
        }
        final needed = _folders.missing(group.id).take(1000).toList();
        if (needed.isEmpty) continue;
        if (folderTransfers.any(
          (task) =>
              task.incoming &&
              task.syncOptions['groupId'] == group.id &&
              (task.isActive || task.canRetry),
        )) {
          continue;
        }
        for (final peer in _lan!.nearbyDevices.where(
          (peer) => group.peers.contains(peer.id),
        )) {
          if (group.settings.mode == FolderSyncMode.oneWay &&
              group.settings.sourceDeviceId != peer.id) {
            continue;
          }
          try {
            await _lan!.sendControl(peer, 'sync.need', {
              'groupId': group.id,
              'nodes': needed,
              'manual': manualGroupId == group.id,
            });
          } catch (_) {
            /* Offline requests remain pending in the catalogue. */
          }
        }
      }
    } finally {
      _requestingFolderFiles = false;
    }
  }

  void _onProgress(VideoItem item, int position) {
    if (!_enabled || _applying || item.isTransient) return;
    _scheduleCapture();
  }

  void _onLibraryChanged() {
    if (!_enabled || _applying) return;
    _scheduleCapture();
    _folderChangeTimer?.cancel();
    _folderChangeTimer = Timer(const Duration(seconds: 2), () {
      if (_enabled && !_disposed) unawaited(syncNow());
    });
  }

  void _onPodcastChanged() {
    if (!_enabled || _applying || _disposed) return;
    _scheduleCapture();
    _folderChangeTimer?.cancel();
    _folderChangeTimer = Timer(const Duration(seconds: 2), () {
      if (_enabled && !_disposed) unawaited(syncNow());
    });
  }

  void _scheduleCapture() {
    _captureTimer?.cancel();
    _captureTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(
        _operations
            .enqueue(() async {
              await _captureAll();
              await _applyAll();
              await _persist();
              _notify();
            })
            .catchError((Object _) {
              _error = '进度暂未保存，将在下次同步时重试';
              _notify();
            }),
      );
    });
  }

  Future<void> createFolderBinding(String collectionId) async {
    await init();
    _requireStorage();
    if (!_enabled) await setEnabled(true);
    await _operations.enqueue(() async {
      if (_groups.values.any((g) => g.collectionId == collectionId)) return;
      _checkNoOverlap(collectionId);
      final folder = library.getCollection(collectionId);
      if (folder == null) throw const FormatException('文件夹已不存在');
      final group = _SyncGroup(
        id: const Uuid().v4(),
        name: folder.name,
        key: List.generate(32, (_) => Random.secure().nextInt(256)),
        collectionId: collectionId,
        settingsClock: {_deviceId: 1},
      );
      _groups[group.id] = group;
      await _indexGroup(group);
      await _captureGroup(group);
      await _persist();
    });
    _notify();
  }

  void _checkNoOverlap(String collectionId) {
    bool ancestor(String root, String target) {
      final seen = <String>{};
      String? id = target;
      while (id != null && seen.add(id)) {
        if (id == root) return true;
        id = library.getCollection(id)?.parentId;
      }
      return false;
    }

    for (final g in _groups.values) {
      final id = g.collectionId;
      if (id != null &&
          (ancestor(id, collectionId) || ancestor(collectionId, id))) {
        throw const FormatException('此文件夹或它的上级、子文件夹已开启同步');
      }
    }
  }

  Future<void> shareFolder(String collectionId, String peerId) async {
    if (!_trustedKeys.containsKey(peerId)) {
      throw const FormatException('请先配对设备');
    }
    await createFolderBinding(collectionId);
    await _operations.enqueue(() async {
      final group = _groups.values.firstWhere(
        (g) => g.collectionId == collectionId,
      );
      group.peers.add(peerId);
      await _persist();
    });
    await syncNow();
    _notify();
  }

  Future<void> acceptInvitation(String groupId, String collectionId) async {
    await init();
    _requireStorage();
    await _operations.enqueue(() async {
      final group = _groups[groupId];
      if (group == null) throw const FormatException('关联邀请已失效');
      _checkNoOverlap(collectionId);
      if (library.getCollection(collectionId) == null) {
        throw const FormatException('文件夹已不存在');
      }
      group.collectionId = collectionId;
      final catalog = _folders.state(group.id, settings: group.settings);
      group.awaitingCatalog =
          catalog.activeEvents.isEmpty ||
          catalog.activeEvents.length < group.catalogCount;
      _webDavKnown.clear();
      await _indexGroup(group);
      // Preserve an existing local watch as a concurrent branch on first merge.
      await _captureGroup(group, initial: true);
      await _applyAll();
      await _persist();
    });
    await syncNow();
    _notify();
  }

  Future<void> unbindFolder(String collectionId) async {
    await init();
    _requireStorage();
    await _operations.enqueue(() async {
      final ids = _groups.values
          .where((g) => g.collectionId == collectionId)
          .map((g) => g.id)
          .toList();
      for (final id in ids) {
        _revokedFolderGroups.add(id);
        _pausedFolderFiles.add(id);
        for (final task in folderTransfers.where(
          (task) =>
              task.syncOptions['groupId'] == id ||
              (task.syncDescriptor?['group'] as Map?)?['id'] == id ||
              (!task.incoming && task.sourceCollectionId == collectionId) ||
              (task.incoming &&
                  (task.targetCollectionId == collectionId ||
                      task.syncOptions['targetCollectionId'] == collectionId)),
        )) {
          if (task.isActive || task.canRetry) {
            await _cancelFolderTask(task);
          }
        }
        _groups.remove(id);
        _folders.remove(id);
        _folderEnvelopes.removeWhere(
          (_, envelope) => envelope['groupId'] == id,
        );
        _mediaKeys.remove(id);
        _podcastEpisodes.remove(id);
        _excludedNodes.remove(id);
        _excludedProgressKeys.remove(id);
        final events = _events.values
            .where((e) => e.groupId == id)
            .map((e) => e.id)
            .toList();
        for (final eventId in events) {
          _events.remove(eventId);
          _envelopes.remove(eventId);
        }
        _localSignatures.removeWhere((key, _) => key.startsWith('$id|'));
        _localClocks.removeWhere((key, _) => key.startsWith('$id|'));
      }
      _pruneRemote.clear();
      await _persist();
    });
    _notify();
  }

  Future<void> _indexGroup(_SyncGroup group) async {
    final folder = group.collectionId;
    if (folder == null) return;
    if (folderTransfers.any(
      (task) =>
          !task.incoming &&
          task.sourceCollectionId == folder &&
          task.syncOptions['directFiles'] == true &&
          (task.phase == FolderTransferPhase.preparing ||
              task.phase == FolderTransferPhase.transferring),
    )) {
      return;
    }
    if (folderTransfers.any(
      (task) =>
          task.incoming &&
          task.syncOptions['adopted'] != true &&
          task.syncOptions['importStarted'] == true &&
          (task.targetCollectionId == folder ||
              task.syncOptions['targetCollectionId'] == folder),
    )) {
      return;
    }
    final applying = _applying;
    _applying = true;
    final catalog = _folders.state(group.id, settings: group.settings);
    final excludedNodes = <String>{}, excludedKeys = <String>{};
    for (final item in library.mediaInFolderTree(folder)) {
      if (!omitLegacyWebDownload(item, library)) continue;
      final node = catalog.nodeIdForLocal(item.id);
      if (node != null) {
        excludedNodes.add(node);
        excludedKeys.add('node:$node');
        final oldKey = catalog.appliedNode(node)?.contentKey;
        if (oldKey != null) excludedKeys.add(oldKey);
      }
      final previous = _mediaKeys[group.id]?[item.id];
      if (previous != null) excludedKeys.add(previous);
    }
    _excludedNodes[group.id] = excludedNodes;
    final waiting =
        group.awaitingCatalog &&
        (catalog.activeEvents.isEmpty ||
            catalog.activeEvents.length < group.catalogCount);
    try {
      if (!waiting) {
        group.awaitingCatalog = false;
        await _folders.capture(group.id, folder, group.settings);
        await _folders.apply(group.id, folder, group.settings);
        _reaffirmOneWaySource(group, catalog);
        group.catalogCount = catalog.activeEvents
            .where((event) => !excludedNodes.contains(event.node.id))
            .length;
      }
    } finally {
      _applying = applying;
    }
    final keys = <String, String>{};
    final items = library
        .mediaInFolderTree(folder)
        .where(
          (v) =>
              !v.isRecycled &&
              !v.isTransient &&
              !omitLegacyWebDownload(v, library),
        )
        .toList();
    final podcastEpisodes = <String, _PodcastSyncEpisode>{};
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready &&
        library.storageCollections.any(
          (card) => card.podcastRef != null && !card.isRecycled,
        )) {
      await runtime.initialize(library: library);
    }
    if (runtime.ready) {
      runtime.controller.flushStates();
      for (final card in library.storageCollections.where(
        (card) => card.podcastRef != null && !card.isRecycled,
      )) {
        String? ancestor = card.id;
        final seen = <String>{};
        while (ancestor != null && ancestor != folder && seen.add(ancestor)) {
          ancestor = library.getCollection(ancestor)?.parentId;
        }
        if (ancestor != folder) continue;
        for (final episode in runtime.store.episodes(
          card.podcastRef!.channelId,
        )) {
          final localId = '__podcast_state__:${episode.id}';
          final adapter = items
              .where(
                (item) =>
                    !communityMediaIsLocal(item.path) &&
                    item.sourceRef?.podcast?.episodeId == episode.id,
              )
              .firstOrNull;
          podcastEpisodes[localId] = _PodcastSyncEpisode(episode, adapter);
          keys[localId] = 'podcast:${episode.id}';
          if (adapter != null) {
            final oldKey = '${group.id}|${adapter.id}';
            final newKey = '${group.id}|$localId';
            // Old versions keyed a projected episode by its folder node.
            // Carry its observed clock to the episode identity, but publish a
            // new checkpoint unless a newer/equivalent one is already known.
            if (!_localSignatures.containsKey(newKey) &&
                _localSignatures[oldKey] ==
                    _podcastValue(episode, adapter).signature) {
              final clock = _localClocks[oldKey];
              if (clock != null) _localClocks[newKey] = Map.of(clock);
              final heads = _heads(group.id, 'podcast:${episode.id}');
              final value = _podcastValue(episode, adapter);
              final same = heads
                  .where((head) => head.value.signature == value.signature)
                  .toList();
              final seen =
                  clock != null &&
                  clock.isNotEmpty &&
                  heads.any(
                    (head) =>
                        clock.entries.every(
                          (entry) =>
                              (head.clock[entry.key] ?? 0) >= entry.value,
                        ) &&
                        {...clock.keys, ...head.clock.keys}.any(
                          (key) => (head.clock[key] ?? 0) > (clock[key] ?? 0),
                        ),
                  );
              if (same.isNotEmpty || seen) {
                _localSignatures[newKey] = _podcastSignature(episode, adapter);
                if (same.isNotEmpty) _localClocks[newKey] = _joinClocks(same);
              }
            }
          }
        }
      }
    }
    _podcastEpisodes[group.id] = podcastEpisodes;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (!communityMediaIsLocal(item.path)) {
        final podcast = item.sourceRef?.podcast;
        if (podcast != null &&
            podcastEpisodes.containsKey(
              '__podcast_state__:${podcast.episodeId}',
            )) {
          continue;
        }
      }
      final key = await _contentKey(item);
      if (key != null) {
        final node = catalog.nodeIdForLocal(item.id);
        keys[item.id] =
            !waiting &&
                !group.settings.shareProgressForSameContent &&
                node != null &&
                catalog.heads(node).isNotEmpty
            ? 'node:$node'
            : key;
      }
      if (i % 8 == 0) {
        _status = '正在识别文件 ${i + 1}/${items.length}';
        _notify();
      }
    }
    final previous = _mediaKeys[group.id];
    var reidentified = false;
    if (previous != null) {
      for (final entry in keys.entries) {
        if (previous[entry.key] != null && previous[entry.key] != entry.value) {
          _localSignatures.remove('${group.id}|${entry.key}');
          _localClocks.remove('${group.id}|${entry.key}');
          reidentified = true;
        }
      }
    }
    _mediaKeys[group.id] = keys;
    excludedKeys.removeAll(keys.values);
    _excludedProgressKeys[group.id] = excludedKeys;
    if (reidentified) await _captureGroup(group, initial: true);
  }

  void _reaffirmOneWaySource(_SyncGroup group, FolderSyncState catalog) {
    if (group.settings.mode != FolderSyncMode.oneWay ||
        group.settings.sourceDeviceId != _deviceId) {
      return;
    }
    // A newly chosen source may have inherited valid nodes from the previous
    // source. Publish the unchanged consensus with our authority, so a fresh
    // follower can reconstruct it without accepting queued follower edits.
    final nodes = catalog.activeEvents.map((event) => event.node.id).toSet();
    for (final node in nodes) {
      if (catalog.isSuppressed(node)) continue;
      final heads = catalog.heads(node);
      if (heads.isEmpty ||
          heads.every((event) => event.deviceId == _deviceId) ||
          heads.map((event) => event.semanticSignature).toSet().length != 1) {
        continue;
      }
      catalog.resolve(node, heads.first.id);
    }
  }

  Future<String?> _contentKey(VideoItem item) async {
    final source = communityMediaIsLocal(item.path) ? null : item.sourceRef;
    if (source?.podcast != null) return 'podcast:${source!.podcast!.episodeId}';
    final cloud = source?.cloudDrive;
    if (cloud != null) {
      final revision = cloud.revision;
      return 'cloud:${cloud.sourceKey}'
          '${revision == null || revision.isEmpty ? '' : ':${digest.sha256.convert(utf8.encode(revision))}'}';
    }
    if (isCloudDriveMedia(source: source, path: item.path)) return null;
    final remembered = _fingerprints[item.id];
    final biliKey = '${source?.bvid}:${source?.cid}';
    if (source?.kind == MediaSourceKind.bilibiliStream &&
        remembered != null &&
        (remembered['bilibiliSourceKey'] == null ||
            remembered['bilibiliSourceKey'] == biliKey)) {
      // A local card's existing content clock survives its source promotion.
      remembered['bilibiliSourceKey'] = biliKey;
      if (item.bilibiliDownloadPath == null) {
        return remembered['key'] as String?;
      }
    }
    final path = communityMediaIsLocal(item.path)
        ? item.path
        : item.bilibiliDownloadPath ?? item.path;
    if (source?.bvid != null && path.startsWith('bilibili:')) {
      final bvid = source!.bvid!;
      return 'bili:$bvid:${source.cid ?? source.page ?? 1}';
    }
    if (path.startsWith('http:') ||
        path.startsWith('https:') ||
        path.startsWith('bilibili:')) {
      return null;
    }
    try {
      final file = File(path), stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final old = _fingerprints[item.id];
      if (old?['path'] == path &&
          old?['size'] == stat.size &&
          old?['modified'] == stat.modified.millisecondsSinceEpoch) {
        return old!['key'] as String;
      }
      // Full digest runs off the UI isolate; header-only samples are not an
      // identity proof for two files with different content in the middle.
      final key = await Isolate.run(() async {
        final hash = await digest.sha256.bind(file.openRead()).first;
        return 'sha256:${stat.size}:$hash';
      });
      final after = await file.stat();
      if (after.size != stat.size || after.modified != stat.modified) {
        return null;
      }
      _fingerprints[item.id] = {
        'id': item.id,
        'path': path,
        'size': stat.size,
        'modified': stat.modified.millisecondsSinceEpoch,
        'key': key,
      };
      return key;
    } catch (_) {
      return null;
    }
  }

  SyncProgressValue _value(VideoItem item) {
    final record = library.mediaActivity(item.id);
    return SyncProgressValue(
      positionMs: item.lastPositionMs,
      completed: record?.completed ?? false,
      continueEnrolled: record?.continueEnrolled ?? false,
      lastPlayedAtMs: record?.lastPlayedAtMs,
      watchMs: record?.accumulatedWatchMs ?? 0,
    );
  }

  SyncProgressValue _podcastValue(PodcastEpisode episode, VideoItem? adapter) {
    final state = PodcastRuntime.instance.controller.state(episode.id);
    final activity = adapter == null ? null : library.mediaActivity(adapter.id);
    return SyncProgressValue(
      positionMs: state.positionMs,
      completed: state.played,
      continueEnrolled: state.positionMs > 0 && !state.played,
      lastPlayedAtMs: state.lastPlayedMs == 0 ? null : state.lastPlayedMs,
      watchMs: activity?.accumulatedWatchMs ?? 0,
    );
  }

  String _podcastSignature(PodcastEpisode episode, VideoItem? adapter) =>
      jsonEncode([
        _podcastValue(episode, adapter).toJson(),
        PodcastRuntime.instance.controller.state(episode.id).playbackUpdatedMs,
      ]);

  List<SyncProgressEvent> _heads(String group, String key) => syncProgressHeads(
    _events.values.where((e) => e.groupId == group && e.mediaKey == key),
  );
  Future<void> _captureAll() async {
    for (final group
        in _groups.values.where((g) => g.collectionId != null).toList()) {
      await _indexGroup(group);
      await _captureGroup(group);
    }
    await _refreshFolderEnvelopes();
  }

  Future<void> _refreshFolderEnvelopes() async {
    final current = <String>{};
    for (final group in _groups.values) {
      for (final event
          in _folders.state(group.id, settings: group.settings).activeEvents) {
        if ((_excludedNodes[group.id] ?? const <String>{}).contains(
          event.node.id,
        )) {
          continue;
        }
        current.add(event.id);
        if (_folderEnvelopes.containsKey(event.id)) continue;
        final box = await _cipher.encrypt(
          utf8.encode(jsonEncode(event.toJson())),
          secretKey: SecretKey(group.key),
          aad: utf8.encode('folder|$kApplicationId|${group.id}|${event.id}'),
        );
        _folderEnvelopes[event.id] = {
          'kind': 'folder-event',
          'version': 1,
          'edition': kApplicationId,
          'groupId': group.id,
          'eventId': event.id,
          'nonce': base64Encode(box.nonce),
          'cipherText': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        };
      }
    }
    final obsolete = _folderEnvelopes.keys
        .where((id) => !current.contains(id))
        .toList();
    for (final id in obsolete) {
      _folderEnvelopes.remove(id);
      _pruneRemote.add(id);
    }
  }

  Future<void> _receiveFolderEnvelope(
    Map<String, dynamic> envelope, {
    String? peerId,
    int? trustRevision,
  }) async {
    if (peerId != null && !_acceptPeerChanges(peerId, trustRevision)) return;
    final group = _groups[envelope['groupId']], id = envelope['eventId'];
    if (group == null ||
        id is! String ||
        id.length > 128 ||
        envelope['version'] != 1 ||
        envelope['edition'] != kApplicationId) {
      return;
    }
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['cipherText'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      ),
      secretKey: SecretKey(group.key),
      aad: utf8.encode('folder|$kApplicationId|${group.id}|$id'),
    );
    if (plain.length > 128 * 1024) throw const FormatException('目录记录过大');
    final event = FolderSyncEvent.fromJson(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map),
    );
    if (event.groupId != group.id || event.id != id) {
      throw const FormatException('目录记录不一致');
    }
    if (peerId != null && !_acceptPeerChanges(peerId, trustRevision)) return;
    if (group.settings.mode == FolderSyncMode.oneWay &&
        event.deviceId != group.settings.sourceDeviceId) {
      return;
    }
    final state = _folders.state(group.id, settings: group.settings);
    state.merge(event);
    _folderEnvelopes[event.id] = envelope;
  }

  Map<String, dynamic> _sharedGroup(_SyncGroup group) => {
    'edition': kApplicationId,
    'id': group.id,
    'name': group.name,
    'key': base64Encode(group.key),
    'fromDevice': _deviceName,
    'settings': group.settings.toJson(),
    'settingsClock': group.settingsClock,
    'catalogCount': _folders
        .state(group.id, settings: group.settings)
        .activeEvents
        .where(
          (event) => !(_excludedNodes[group.id] ?? const <String>{}).contains(
            event.node.id,
          ),
        )
        .length,
  };
  void _mergeFolderSettings(_SyncGroup existing, _SyncGroup incoming) {
    folderSyncValidateClock(incoming.settingsClock, allowEmpty: true);
    if (existing.collectionId == null || existing.awaitingCatalog) {
      existing.catalogCount = incoming.catalogCount;
    }
    final observed = folderSyncMergeClocks([
      existing.settingsClock,
      existing.settingsConflictClock,
    ]);
    final same =
        jsonEncode(existing.settings.toJson()) ==
        jsonEncode(incoming.settings.toJson());
    final coversAll =
        folderSyncClockAfter(incoming.settingsClock, observed) ||
        mapEquals(incoming.settingsClock, observed);
    if (same) {
      final joined = folderSyncMergeClocks([
        existing.settingsClock,
        incoming.settingsClock,
      ]);
      existing.settingsClock
        ..clear()
        ..addAll(joined);
      if (coversAll) existing.settingsConflictClock.clear();
    } else if (folderSyncClockAfter(incoming.settingsClock, observed)) {
      existing.settings = incoming.settings;
      existing.settingsClock
        ..clear()
        ..addAll(incoming.settingsClock);
      existing.settingsConflictClock.clear();
    } else if (!folderSyncClockAfter(
          existing.settingsClock,
          incoming.settingsClock,
        ) &&
        !same) {
      for (final entry in incoming.settingsClock.entries) {
        existing.settingsConflictClock[entry.key] = max(
          existing.settingsConflictClock[entry.key] ?? 0,
          entry.value,
        );
      }
      _error = '两端同步设置不同，请重新选择设置后保存';
    }
    _folders.state(existing.id, settings: existing.settings);
  }

  Future<void> _captureGroup(_SyncGroup group, {bool initial = false}) async {
    for (final entry in (_mediaKeys[group.id] ?? {}).entries) {
      final podcast = _podcastEpisodes[group.id]?[entry.key];
      final item = podcast == null ? library.getVideo(entry.key) : null;
      if (item == null && podcast == null) continue;
      final value = podcast == null
          ? _value(item!)
          : _podcastValue(podcast.episode, podcast.adapter);
      final signature = podcast == null
          ? value.signature
          : _podcastSignature(podcast.episode, podcast.adapter);
      final localKey = '${group.id}|${entry.key}';
      if (_localSignatures[localKey] == signature) continue;
      final heads = _heads(group.id, entry.value);
      final hasProgress =
          value.positionMs > 0 ||
          value.completed ||
          value.continueEnrolled ||
          value.lastPlayedAtMs != null ||
          value.watchMs > 0 ||
          podcast != null &&
              PodcastRuntime.instance.controller
                      .state(podcast.episode.id)
                      .playbackUpdatedMs >
                  0;
      if (_localSignatures[localKey] == null && !hasProgress) {
        _localSignatures[localKey] = signature;
        continue;
      }
      if (_localSignatures[localKey] == null && !initial && heads.isNotEmpty) {
        // Restoration/restart: a matching saved local value is not a new watch.
        if (heads.any((h) => h.value.signature == value.signature)) {
          _localSignatures[localKey] = signature;
          final same = heads.where((h) => h.value.signature == value.signature);
          _localClocks[localKey] = _joinClocks(same);
          continue;
        }
      }
      // A checkpoint inherits only changes actually applied to this local item.
      // Merely receiving a remote head while playing must not accept its state.
      final clock = Map<String, int>.from(
        initial ? {} : _localClocks[localKey] ?? {},
      );
      _sequence = max(_sequence, clock[_deviceId] ?? 0) + 1;
      clock[_deviceId] = _sequence;
      final event = SyncProgressEvent(
        id: const Uuid().v4(),
        groupId: group.id,
        mediaKey: entry.value,
        title: podcast?.episode.title ?? item!.title,
        deviceId: _deviceId,
        deviceName: _deviceName,
        clock: clock,
        value: value,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _addEvent(event);
      _localSignatures[localKey] = signature;
      _localClocks[localKey] = clock;
    }
  }

  Map<String, int> _joinClocks(Iterable<SyncProgressEvent> events) {
    final result = <String, int>{};
    for (final event in events) {
      for (final entry in event.clock.entries) {
        result[entry.key] = max(result[entry.key] ?? 0, entry.value);
      }
    }
    return result;
  }

  Future<void> _addEvent(
    SyncProgressEvent event, {
    Map<String, dynamic>? envelope,
  }) async {
    if (_events.containsKey(event.id)) return;
    final group = _groups[event.groupId];
    if (group == null) return;
    final current = _heads(event.groupId, event.mediaKey);
    if (current.any((e) => e.descendsFrom(event))) {
      _pruneRemote.add(event.id);
      return;
    }
    final box = envelope ?? await _encryptEvent(event, group.key);
    _events[event.id] = event;
    _envelopes[event.id] = box;
    final heads = _heads(event.groupId, event.mediaKey),
        keep = heads.map((e) => e.id).toSet();
    final obsolete = _events.values
        .where(
          (e) =>
              e.groupId == event.groupId &&
              e.mediaKey == event.mediaKey &&
              !keep.contains(e.id),
        )
        .map((e) => e.id)
        .toList();
    for (final id in obsolete) {
      _events.remove(id);
      _envelopes.remove(id);
      _pruneRemote.add(id);
    }
  }

  Future<Map<String, dynamic>> _encryptEvent(
    SyncProgressEvent event,
    List<int> key,
  ) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(event.toJson())),
      secretKey: SecretKey(key),
      aad: utf8.encode('progress|$kApplicationId|${event.groupId}|${event.id}'),
    );
    return {
      'kind': 'event',
      'version': 1,
      'edition': kApplicationId,
      'eventId': event.id,
      'groupId': event.groupId,
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<void> _receiveEnvelope(
    Map<String, dynamic> envelope, {
    String? peerId,
    int? trustRevision,
    bool allowLegacyLocal = false,
  }) async {
    if (peerId != null && !_acceptPeerChanges(peerId, trustRevision)) return;
    final rawGroup = envelope['groupId'], rawId = envelope['eventId'];
    if (rawGroup is! String || rawId is! String) return;
    final groupId = rawGroup, id = rawId;
    final group = _groups[groupId];
    if (group == null || id.length > 100 || envelope['version'] != 1) {
      return;
    }
    final legacyLocal = allowLegacyLocal && envelope['edition'] == null;
    if (!legacyLocal && envelope['edition'] != kApplicationId) return;
    if (_events.containsKey(id)) return;
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['cipherText'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      ),
      secretKey: SecretKey(group.key),
      aad: utf8.encode(
        legacyLocal ? '$groupId|$id' : 'progress|$kApplicationId|$groupId|$id',
      ),
    );
    if (plain.length > 128 * 1024) throw const FormatException('同步记录过大');
    final event = SyncProgressEvent.fromJson(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map),
    );
    if (event.id != id ||
        event.groupId != groupId ||
        event.clock.length > 100 ||
        event.mediaKey.length > 512) {
      throw const FormatException('同步记录无效');
    }
    if (peerId != null && !_acceptPeerChanges(peerId, trustRevision)) return;
    await _addEvent(event, envelope: legacyLocal ? null : envelope);
  }

  Future<List<Map<String, dynamic>>> _outgoing(String peerId) async {
    final revision = _trustRevision;
    if (!_acceptPeerChanges(peerId, revision)) return [];
    await _captureAll();
    if (!_acceptPeerChanges(peerId, revision)) return [];
    await _persist();
    final allowed = _groups.values
        .where((g) => g.peers.contains(peerId))
        .toList();
    await _capturePodcasts();
    if (!_acceptPeerChanges(peerId, revision)) return [];
    return [
      {'kind': 'podcast-capabilities', 'version': 1},
      {
        'kind': 'podcast-capabilities',
        'version': 2,
        'catalogPayload': 2,
        'inheritance': 1,
        'viewState': 1,
      },
      for (final g in allowed) {'kind': 'invite', 'group': _sharedGroup(g)},
      for (final envelope in _envelopes.values)
        if (allowed.any((g) => g.id == envelope['groupId']) &&
            _progressEnvelopeAllowed(envelope))
          envelope,
      for (final envelope in _folderEnvelopes.values)
        if (allowed.any((g) => g.id == envelope['groupId'])) envelope,
      if ((_podcastPeerVersions[peerId] ?? 0) >= 1)
        for (final envelope in _podcastEnvelopes.values)
          if (allowed.any((g) => g.id == envelope['groupId'])) envelope,
    ];
  }

  bool _acceptPeerChanges(String peerId, int? revision) =>
      _enabled &&
      !_disposed &&
      _trustedKeys.containsKey(peerId) &&
      (revision == null || revision == _trustRevision);

  bool _progressEnvelopeAllowed(Map<String, dynamic> envelope) {
    final event = _events[envelope['eventId']];
    return event == null ||
        !(_excludedProgressKeys[event.groupId] ?? const <String>{}).contains(
          event.mediaKey,
        );
  }

  Future<void> _receive(
    String peerId,
    List<Map<String, dynamic>> changes, {
    int? trustRevision,
  }) async {
    final revision = trustRevision ?? _trustRevision;
    if (!_acceptPeerChanges(peerId, revision)) return;
    final capability = changes
        .where((record) => record['kind'] == 'podcast-capabilities')
        .map((record) => (record['version'] as num?)?.toInt() ?? 0)
        .fold<int>(0, (best, version) => version > best ? version : best);
    if (capability >= 1) {
      _podcastPeerVersions[peerId] = capability;
    } else {
      _podcastPeerVersions.putIfAbsent(peerId, () => 0);
    }
    await _captureAll();
    if (!_acceptPeerChanges(peerId, revision)) return;
    final snapshotCounts = <String, int>{};
    final receivedCounts = <String, int>{};
    for (final record in changes) {
      if (!_acceptPeerChanges(peerId, revision)) return;
      if (record['kind'] == 'invite' && record['group'] is Map) {
        final incoming = Map<String, dynamic>.from(record['group'] as Map);
        _SyncGroup fresh;
        try {
          fresh = _SyncGroup.fromJson(incoming);
        } catch (_) {
          continue;
        }
        fresh.collectionId = null;
        fresh.peers.clear();
        fresh.lastSyncedAt = null;
        final existing = _groups[fresh.id];
        if (_revokedFolderGroups.contains(fresh.id)) continue;
        if (existing != null && !listEquals(existing.key, fresh.key)) continue;
        if (existing != null) _mergeFolderSettings(existing, fresh);
        if (_groups.length >= 200 && existing == null) continue;
        final g = existing ?? fresh;
        snapshotCounts[g.id] = fresh.catalogCount;
        if (existing == null) _webDavKnown.clear();
        g.peers.add(peerId);
        g.fromDevice = _pairedNames[peerId] ?? fresh.fromDevice;
        _groups[g.id] = g;
      }
    }
    for (final record in changes) {
      if (!_acceptPeerChanges(peerId, revision)) return;
      if (record['kind'] == 'podcast-event') {
        final group = _groups[record['groupId']];
        if (group != null &&
            group.peers.contains(peerId) &&
            PodcastRuntime.instance.ready) {
          try {
            await PodcastSyncCodec.receive(
              record,
              group.key,
              PodcastRuntime.instance.store,
            );
          } catch (_) {
            _error = '部分播客同步记录无法验证，本机数据已保留';
          }
        }
        continue;
      }
      if (record['kind'] != 'event' && record['kind'] != 'folder-event') {
        continue;
      }
      final g = _groups[record['groupId']];
      if (g == null || !g.peers.contains(peerId)) continue;
      try {
        if (record['kind'] == 'folder-event') {
          await _receiveFolderEnvelope(
            record,
            peerId: peerId,
            trustRevision: revision,
          );
          receivedCounts[g.id] = (receivedCounts[g.id] ?? 0) + 1;
        } else {
          await _receiveEnvelope(
            record,
            peerId: peerId,
            trustRevision: revision,
          );
        }
      } catch (_) {
        _error = '部分同步记录无法验证，本机进度已保留';
      }
    }
    for (final group in _groups.values.where(
      (group) => group.awaitingCatalog,
    )) {
      final expected = snapshotCounts[group.id];
      if (expected != null &&
          expected > 0 &&
          (receivedCounts[group.id] ?? 0) >= expected &&
          _folders.state(group.id).rootNodeId != null) {
        group.awaitingCatalog = false;
      }
    }
    for (final group in _groups.values.where((g) => g.collectionId != null)) {
      if (!_acceptPeerChanges(peerId, revision)) return;
      await _indexGroup(group);
    }
    if (!_acceptPeerChanges(peerId, revision)) return;
    await _applyAll();
    await _applyPodcasts();
    await _persist();
    _lastSyncedAt = DateTime.now();
    for (final group in _groups.values.where((g) => g.peers.contains(peerId))) {
      group.lastSyncedAt = _lastSyncedAt;
    }
    _notify();
    scheduleMicrotask(() => unawaited(_requestMissingFolderFiles()));
  }

  Future<void> _capturePodcasts() async {
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready) return;
    runtime.controller.flushStates();
    final current = <String>{};
    for (final group in _groups.values.where((g) => g.collectionId != null)) {
      final catalog = _folders.state(group.id);
      for (final card in library.storageCollections.where(
        (c) => c.podcastRef != null && !c.isRecycled,
      )) {
        String? ancestor = card.id;
        final seen = <String>{};
        var included = false;
        while (ancestor != null && seen.add(ancestor)) {
          if (ancestor == group.collectionId) {
            included = true;
            break;
          }
          ancestor = library.getCollection(ancestor)?.parentId;
        }
        if (!included) continue;
        final channel = runtime.store.channel(card.podcastRef!.channelId);
        if (channel == null) continue;
        final node = catalog.nodeIdForLocal(card.id);
        if (node == null) continue;
        // The subscription and episode references let the other device show
        // the channel. Playback state travels as causal progress events; local
        // download preferences, favorites and presentation stay on this device.
        final data = <String, dynamic>{
          'version': 1,
          'channel': PodcastChannel(
            id: channel.id,
            feedUrl: channel.feedUrl,
            title: channel.title,
            author: channel.author,
            imageUrl: channel.imageUrl,
            guid: channel.guid,
            aliases: channel.aliases,
          ).toJson(),
          'episodes': [
            for (final episode in runtime.store.episodes(channel.id))
              PodcastEpisode(
                id: episode.id,
                channelId: channel.id,
                title: episode.title,
                media: episode.media,
                guid: episode.guid,
                publishedMs: episode.publishedMs,
                durationMs: episode.durationMs,
                sourceFeedUrl: episode.sourceFeedUrl,
              ).toJson(),
          ],
        };
        for (final record in await PodcastSyncCodec.encode(
          data: data,
          groupId: group.id,
          nodeId: node,
          key: group.key,
        )) {
          final id = record['eventId'] as String;
          current.add(id);
          // Digest-based podcast IDs can become current again after a setting
          // is toggled back. Never delete a snapshot that is active again.
          _pruneRemote.remove(id);
          _podcastEnvelopes.putIfAbsent(id, () => record);
        }
      }
    }
    final obsolete = _podcastEnvelopes.keys
        .where((id) => !current.contains(id))
        .toList();
    for (final id in obsolete) {
      final removed = _podcastEnvelopes.remove(id)!;
      // Leaving a group is a local action, not permission to erase its shared
      // podcast backup. Prune superseded snapshots only for a bound group.
      if (_groups[removed['groupId']]?.collectionId != null) {
        _pruneRemote.add(id);
      }
    }
    for (final peer in _podcastPeerVersions.entries.where(
      (e) => e.value == 0,
    )) {
      if (_podcastEnvelopes.values.any(
        (r) => _groups[r['groupId']]?.peers.contains(peer.key) == true,
      )) {
        _error = '对端版本尚不支持播客，请更新后同步订阅与收听状态';
      }
    }
    for (final peer in _podcastPeerVersions.entries.where(
      (entry) => entry.value == 1,
    )) {
      if (_podcastEnvelopes.values.any(
        (record) =>
            _groups[record['groupId']]?.peers.contains(peer.key) == true,
      )) {
        _error = '对端版本较旧，部分单集状态可能无法同步，请更新软件';
      }
    }
  }

  Future<void> _applyPodcasts() async {
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready) return;
    var changed = false;
    for (final pending in runtime.store.list('syncPending')) {
      // Historical pending fragments have no trustworthy edition identity.
      // Retain them, but apply only records authenticated for this edition.
      if (pending['edition'] != kApplicationId) continue;
      final groupId = pending['groupId'] as String, group = _groups[groupId];
      if (group == null) continue;
      final local = _folders.state(groupId).localIdForNode(pending['nodeId']);
      if (local == null || library.getCollection(local) == null) continue;
      final incoming = Map<String, dynamic>.from(pending['data']);
      final incomingChannel = PodcastChannel.fromJson(
        Map<String, dynamic>.from(incoming['channel'] as Map),
      );
      final existingChannel = runtime.store.channel(incomingChannel.id);
      if (existingChannel != null) {
        final localUrls = {
          existingChannel.feedUrl,
          ...existingChannel.aliases,
        }.map(podcastCanonicalUrl).toSet();
        final incomingUrls = {
          incomingChannel.feedUrl,
          ...incomingChannel.aliases,
        }.map(podcastCanonicalUrl).toSet();
        if (localUrls.intersection(incomingUrls).isEmpty) {
          throw const FormatException('播客频道身份与订阅地址不一致');
        }
      }
      for (final raw in incoming['episodes'] as List? ?? const []) {
        final episode = PodcastEpisode.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        final existing = runtime.store.episode(episode.id);
        if (existing != null && existing.channelId != incomingChannel.id) {
          throw const FormatException('播客节目身份不属于此频道');
        }
      }
      // Older devices may still send settings and favorites. Do not apply them
      // as a side effect of synchronizing podcast listening progress.
      final data = <String, dynamic>{
        'version': 1,
        'channel': incoming['channel'],
        'episodes': incoming['episodes'] ?? const [],
      };
      runtime.store.importChannel(data, synchronization: true);
      final raw = Map<String, dynamic>.from(data['channel']);
      await library.setPodcastChannelRef(
        local,
        PodcastChannelRef(channelId: raw['id'], feedUrl: raw['feedUrl']),
      );
      if (pending['id'] is String) {
        runtime.store.remove('syncPending', pending['id']);
      }
      changed = true;
    }
    if (changed) {
      runtime.controller.reload();
      for (final group in _groups.values.where((g) => g.collectionId != null)) {
        await _indexGroup(group);
      }
      await _applyAll();
    }
  }

  Future<void> _applyAll({String? allowMediaId}) async {
    _applying = true;
    try {
      final pending =
          <
            ({
              String groupId,
              String mediaId,
              String localId,
              SyncProgressValue value,
            })
          >[];
      for (final group in _groups.values.where((g) => g.collectionId != null)) {
        for (final entry in (_mediaKeys[group.id] ?? {}).entries) {
          final podcast = _podcastEpisodes[group.id]?[entry.key];
          final activeId = podcast == null
              ? entry.key
              : podcast.adapter?.id ?? podcast.episode.id;
          if (_activeMediaId() == activeId && allowMediaId != activeId) {
            continue;
          }
          final heads = _heads(group.id, entry.value);
          if (heads.isEmpty) continue;
          if (heads.map((h) => _semanticSignature(h.value)).toSet().length >
              1) {
            continue;
          }
          final event = heads.first;
          final item = podcast?.adapter ?? library.getVideo(entry.key);
          if (item == null && podcast == null) continue;
          _localClocks['${group.id}|${entry.key}'] = _joinClocks(heads);
          final local = podcast == null
              ? _value(item!)
              : _podcastValue(podcast.episode, podcast.adapter);
          final target = SyncProgressValue(
            positionMs: event.value.positionMs,
            completed: event.value.completed,
            continueEnrolled: event.value.continueEnrolled,
            lastPlayedAtMs:
                [
                  local.lastPlayedAtMs,
                  ...heads.map((head) => head.value.lastPlayedAtMs),
                ].whereType<int>().fold<int?>(
                  null,
                  (latest, value) =>
                      latest == null ? value : max(latest, value),
                ),
            watchMs: podcast != null && podcast.adapter == null
                ? 0
                : heads.fold(
                    local.watchMs,
                    (longest, head) => max(longest, head.value.watchMs),
                  ),
          );
          if (podcast != null && local.signature != target.signature) {
            PodcastRuntime.instance.controller.savePlaybackProgress(
              podcast.episode.id,
              target.positionMs,
              completed: target.completed,
              lastPlayedMs: target.lastPlayedAtMs,
            );
          }
          if (item == null ||
              (local.signature == target.signature &&
                  (podcast == null ||
                      _value(item).signature == target.signature))) {
            _localSignatures['${group.id}|${entry.key}'] = podcast == null
                ? local.signature
                : _podcastSignature(podcast.episode, podcast.adapter);
            continue;
          }
          pending.add((
            groupId: group.id,
            mediaId: item.id,
            localId: entry.key,
            value: target,
          ));
        }
      }
      for (var i = 0; i < pending.length; i++) {
        final change = pending[i], value = pending[i].value;
        await library.applySyncedPlaybackProgress(
          mediaId: change.mediaId,
          positionMs: value.positionMs,
          completed: value.completed,
          continueEnrolled: value.continueEnrolled,
          accumulatedWatchMs: value.watchMs,
          lastPlayedAtMs: value.lastPlayedAtMs,
          persist: i == pending.length - 1,
        );
        final item = library.getVideo(change.mediaId);
        if (item != null) {
          final podcast = _podcastEpisodes[change.groupId]?[change.localId];
          _localSignatures['${change.groupId}|${change.localId}'] =
              podcast == null
              ? _value(item).signature
              : _podcastSignature(podcast.episode, podcast.adapter);
        }
      }
    } finally {
      _applying = false;
    }
  }

  Future<void> resolveConflict(String conflictId, String eventId) async {
    await _operations.enqueue(() async {
      final conflict = conflicts.firstWhere((c) => c.id == conflictId);
      final chosen = conflict.choices.firstWhere((e) => e.id == eventId);
      final clock = <String, int>{};
      for (final head in conflict.choices) {
        for (final e in head.clock.entries) {
          clock[e.key] = max(clock[e.key] ?? 0, e.value);
        }
      }
      _sequence = max(_sequence, clock[_deviceId] ?? 0) + 1;
      clock[_deviceId] = _sequence;
      final resolved = SyncProgressEvent(
        id: const Uuid().v4(),
        groupId: chosen.groupId,
        mediaKey: chosen.mediaKey,
        title: chosen.title,
        deviceId: _deviceId,
        deviceName: _deviceName,
        clock: clock,
        value: chosen.value,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _addEvent(resolved);
      await _applyAll();
      await _persist();
    });
    await syncNow();
    _notify();
  }

  Future<void> syncNow() {
    if (_syncing != null) {
      _syncAgain = true;
      return _syncing!;
    }
    final work = () async {
      for (var pass = 0; pass < 2; pass++) {
        _syncAgain = false;
        await _sync();
        if (!_syncAgain || !_enabled || _disposed) break;
      }
    }();
    _syncing = work;
    return work.whenComplete(() {
      if (identical(_syncing, work)) _syncing = null;
    });
  }

  Future<void> _sync() async {
    if (!_initialized || !_enabled || _disposed) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await _operations.enqueue(() async {
        await _captureAll();
        await _applyAll();
        await _persist();
      });
      var exchanged = false;
      if (_lan != null) {
        for (final peer
            in _lan!.nearbyDevices
                .where((d) => _trustedKeys.containsKey(d.id))
                .toList()) {
          try {
            await _lan!.syncPeer(peer);
            exchanged = true;
          } catch (_) {
            /* offline peers retain their pending checkpoints */
          }
        }
      }
      if (!_enabled || _disposed) return;
      if (_webDav != null && _groups.isNotEmpty) {
        final readWarnings = <String>{};
        try {
          await _operations.enqueue(() async {
            if (!_enabled || _disposed) return;
            final webDav = _webDav;
            if (webDav == null) return;
            final scanKnown = Set<String>.of(_webDavKnown);
            var storeFullyRead = false;
            for (var page = 0; page < 8; page++) {
              final changes = await webDav.readChanges(
                knownEventIds: scanKnown,
              );
              readWarnings.addAll(webDav.takeReadWarnings());
              if (!_enabled || _disposed || !identical(webDav, _webDav)) return;
              if (changes.isEmpty) {
                storeFullyRead = true;
                break;
              }
              for (final envelope in changes) {
                var accepted = true;
                try {
                  if (envelope['kind'] == 'podcast-event') {
                    final group = _groups[envelope['groupId']];
                    if (group != null && PodcastRuntime.instance.ready) {
                      await PodcastSyncCodec.receive(
                        envelope,
                        group.key,
                        PodcastRuntime.instance.store,
                      );
                    }
                  } else if (envelope['kind'] == 'folder-event') {
                    await _receiveFolderEnvelope(envelope);
                  } else {
                    await _receiveEnvelope(envelope);
                  }
                } catch (_) {
                  accepted = false;
                  _error = '部分同步记录无法验证，本机进度已保留';
                }
                if (envelope['eventId'] case final String id) {
                  // Skip a corrupt authenticated envelope for this scan only;
                  // a repaired server copy must be retried on the next sync.
                  scanKnown.add(id);
                  if (accepted) _webDavKnown.add(id);
                }
              }
              if (changes.length < 250) {
                storeFullyRead = true;
                break;
              }
            }
            for (final group in _groups.values.where(
              (group) => group.collectionId != null,
            )) {
              // The complete store listing has been read successfully. A
              // copied invitation may advertise an older, larger head count.
              if (storeFullyRead &&
                  _folders.state(group.id).rootNodeId != null) {
                group.awaitingCatalog = false;
              }
              await _indexGroup(group);
            }
            await _applyAll();
            await _refreshFolderEnvelopes();
            await _applyPodcasts();
            await _capturePodcasts();
            if (_pruneRemote.isNotEmpty) await _persist();
            final pending =
                [
                      ..._envelopes.values,
                      ..._folderEnvelopes.values,
                      ..._podcastEnvelopes.values,
                    ]
                    .where(
                      (e) =>
                          _groups.containsKey(e['groupId']) &&
                          (e['kind'] != 'event' ||
                              _progressEnvelopeAllowed(e)) &&
                          !_webDavKnown.contains(e['eventId']),
                    )
                    .toList();
            for (var offset = 0; offset < pending.length; offset += 250) {
              final batch = pending.sublist(
                offset,
                min(offset + 250, pending.length),
              );
              await webDav.writeChanges(batch);
              _webDavKnown.addAll(
                batch.map((e) => e['eventId']).whereType<String>(),
              );
            }
            if (_pruneRemote.isNotEmpty) {
              // Replacement heads must be stored before their predecessors
              // are removed. Persist each completed deletion batch so a large
              // library and partial network failure both resume safely.
              while (_pruneRemote.isNotEmpty) {
                final batch = _pruneRemote.take(5000).toSet();
                await webDav.deleteChanges(batch);
                _pruneRemote.removeAll(batch);
                _webDavKnown.removeAll(batch);
                await _persist();
              }
            }
            await _applyAll();
            await _persist();
          });
          if (!_enabled || _disposed) return;
          _webDavStatus = readWarnings.isNotEmpty ? '已同步，部分损坏记录已跳过' : '已同步';
          if (readWarnings.isNotEmpty) {
            _error = '已跳过 ${readWarnings.length} 个损坏的存储记录，其余内容已同步；修复记录后会再次读取';
          }
          exchanged = true;
        } catch (_) {
          _webDavStatus = '暂未连接，下次自动重试';
          _error = '存储同步未完成，请检查地址、账号或网络';
        }
      }
      if (exchanged) {
        _lastSyncedAt = DateTime.now();
        for (final group in _groups.values.where(
          (g) => g.collectionId != null,
        )) {
          group.lastSyncedAt = _lastSyncedAt;
        }
      }
      final pendingFiles = _groups.values.fold<int>(
        0,
        (sum, group) => sum + _folders.missingCount(group.id),
      );
      _status = conflicts.isNotEmpty || folderSyncIssues.isNotEmpty
          ? '有同步项目需要确认'
          : folderTransfers.any((task) => task.isActive)
          ? '正在同步文件'
          : pendingFiles > 0
          ? '有文件等待补齐'
          : exchanged
          ? '已同步'
          : _groups.isEmpty
          ? '关联文件夹后，进度会自动同步'
          : '等待已关联设备上线';
    } catch (_) {
      _error = '同步未完成，本机进度已保留';
      _status = '稍后自动重试';
    } finally {
      _busy = false;
      _notify();
      unawaited(_requestMissingFolderFiles());
    }
  }

  Future<void> configureWebDav(ProgressSyncWebDavConfig config) async {
    await init();
    _requireStorage();
    final client = ProgressSyncWebDav(config: config);
    try {
      await client.testConnection();
    } catch (_) {
      client.close();
      throw const FormatException('连接失败，请检查地址、账号和密码');
    }
    await _operations.enqueue(() async {
      _webDav?.close();
      _webDav = client;
      _webDavConfig = config;
      _webDavKnown.clear();
      _webDavStatus = '连接成功';
      await _persist();
    });
    if (!_enabled) await setEnabled(true);
    await _persist();
    _notify();
    await syncNow();
  }

  Future<void> disconnectWebDav() async {
    await init();
    _requireStorage();
    await _operations.enqueue(() async {
      _webDav?.close();
      _webDav = null;
      _webDavConfig = null;
      _webDavKnown.clear();
      _webDavStatus = null;
      await _persist();
    });
    _notify();
  }

  Future<String> exportSyncCode() async {
    await init();
    _requireStorage();
    if (_groups.isEmpty) throw const FormatException('先关联一个文件夹');
    final data = {
      'version': 1,
      'edition': kApplicationId,
      'groups': _groups.values
          .where((g) => g.collectionId != null)
          .map(_sharedGroup)
          .toList(),
    };
    return 'fluent-progress:1:${base64UrlEncode(utf8.encode(jsonEncode(data)))}';
  }

  Future<void> importSyncCode(String code) async {
    await init();
    _requireStorage();
    if (code.length > 128 * 1024 ||
        !code.trim().startsWith('fluent-progress:1:')) {
      throw const FormatException('同步码无效，请从另一台设备复制');
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(
            utf8.decode(
              base64Url.decode(
                code.trim().substring('fluent-progress:1:'.length),
              ),
            ),
          )
          as Map,
    );
    if (data['edition'] != kApplicationId) {
      throw const FormatException('同步码属于其他版本或来自旧版，请在相同版本重新生成');
    }
    final incoming = (data['groups'] as List)
        .map((g) => _SyncGroup.fromJson(Map<String, dynamic>.from(g as Map)))
        .toList();
    if (data['version'] != 1) throw const FormatException('同步码版本不受支持');
    for (final group in incoming) {
      group.collectionId = null;
      group.peers.clear();
      group.lastSyncedAt = null;
    }
    if (incoming.length > 200) throw const FormatException('同步码过大');
    await _operations.enqueue(() async {
      for (final group in incoming) {
        final existing = _groups[group.id];
        if (existing != null && !listEquals(existing.key, group.key)) {
          throw const FormatException('同步码与现有文件夹不一致');
        }
      }
      for (final group in incoming) {
        _revokedFolderGroups.remove(group.id);
        _groups.putIfAbsent(group.id, () => group);
      }
      _webDavKnown.clear();
      await _persist();
    });
    if (!_enabled) await setEnabled(true);
    await _persist();
    _notify();
  }

  Future<void> preparePlayback(String mediaId) async {
    if (!_enabled || _groups.isEmpty) return;
    // Bound the wait: unavailable peers never hold up opening a local video.
    var expired = false;
    try {
      await (() async {
        await syncNow();
        if (expired) return;
        await _operations.enqueue(() async {
          if (!expired) {
            await _applyAll(allowMediaId: mediaId);
            await _persist();
          }
        });
      })().timeout(
        const Duration(milliseconds: 900),
        onTimeout: () {
          expired = true;
        },
      );
    } catch (_) {}
  }

  Future<void> flush() async {
    if (!_enabled) return;
    _captureTimer?.cancel();
    _folderChangeTimer?.cancel();
    try {
      await _operations.enqueue(() async {
        await _captureAll();
        await _persist();
      });
    } catch (_) {
      _error = '进度暂未保存，将在下次同步时重试';
      _notify();
      return;
    }
    unawaited(syncNow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_enabled) unawaited(syncNow());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  @override
  void dispose() {
    _trustRevision++;
    _disposed = true;
    _timer?.cancel();
    _captureTimer?.cancel();
    _folderChangeTimer?.cancel();
    library.removeProgressObserver(_onProgress);
    library.removeListener(_onLibraryChanged);
    library.activityRevision.removeListener(_onLibraryChanged);
    _observedPodcast?.removeListener(_onPodcastChanged);
    WidgetsBinding.instance.removeObserver(this);
    _lan?.removeListener(_notify);
    _lan?.dispose();
    _folderTransfer?.removeListener(_notify);
    _folderTransfer?.dispose();
    _webDav?.close();
    super.dispose();
  }
}
