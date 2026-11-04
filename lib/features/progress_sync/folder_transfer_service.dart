import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../services/app_wakelock_coordinator.dart';
import '../../services/library_service.dart';
import '../../services/settings_service.dart';
import '../portable_transfer/portable_folder_transfer.dart';
import '../portable_transfer/sync_media_origin.dart';
import 'folder_receive_journal.dart';
import 'folder_received_validation.dart';
import 'folder_transfer_models.dart';
import 'folder_transfer_disk_space.dart' as disk;
import 'folder_transfer_storage.dart';
import 'folder_transfer_transport.dart' as wire;
import 'folder_direct_transport.dart';
import 'progress_sync_lan.dart';

typedef FolderLinkBuilder =
    Future<Map<String, dynamic>> Function(
      String collectionId,
      String peerId,
      Map<String, PortableFolderFingerprint> fingerprints,
    );
typedef FolderLinkReceiver =
    Future<void> Function(
      Map<String, dynamic> descriptor,
      String peerId,
      String collectionId,
      Map<String, PortableFolderFingerprint> fingerprints,
    );

/// Coordinates consent, fluentpack delivery, idempotent import and automatic
/// progress association. Long operations never hold a control RPC open.
class FolderTransferService extends ChangeNotifier {
  FolderTransferService({
    required this.library,
    required ProgressSyncLan lan,
    required this.buildLink,
    required this.receiveLink,
    required this.persistState,
    required this.peerNames,
    PortableFolderTransfer? adapter,
    Future<Directory> Function()? directoryProvider,
    Map<String, dynamic>? savedState,
    this.knownContentKeys,
    this.sourceFingerprints,
    Future<int?> Function(Directory)? availableBytes,
    this.autoRetry = true,
    this.receivePolicy,
    this.stableIds,
    this.localIds,
    this.onImported,
    this.syncMetadata,
    this.prepareCatalog,
    this.suppressedIds,
    this.protectedIds,
  }) : _lan = lan,
       _adapter = adapter ?? PortableFolderTransfer(),
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _availableBytes = availableBytes ?? disk.availableBytes {
    for (final raw in savedState?['tasks'] as List? ?? []) {
      try {
        final task = FolderTransferTask.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        if (_validId(task.id) && _tasks.length < 100) _tasks[task.id] = task;
      } catch (_) {
        /* Preserve valid records if one task is damaged. */
      }
    }
    _targets.addAll(
      Map<String, String>.from(savedState?['targets'] as Map? ?? {}),
    );
  }

  final LibraryService library;
  final FolderLinkBuilder buildLink;
  final FolderLinkReceiver receiveLink;
  final Future<void> Function() persistState;
  final Map<String, String> Function() peerNames;
  final bool autoRetry;
  final Future<Map<String, dynamic>?> Function(
    String peerId,
    Map<String, dynamic> offer,
  )?
  receivePolicy;
  final Map<String, String> Function(String collectionId)? stableIds;
  final Map<String, String> Function(String collectionId)? localIds;
  final Future<void> Function(
    String peerId,
    String collectionId,
    Map<String, dynamic> descriptor,
    Map<String, String> stableToLocalIds,
  )?
  onImported;
  final Map<String, dynamic> Function(String collectionId)? syncMetadata;
  final Future<void> Function(String collectionId, String peerId)?
  prepareCatalog;
  final Set<String> Function(String collectionId)? suppressedIds;
  final FutureOr<Set<String>> Function(
    String collectionId,
    Map<String, dynamic> syncMetadata,
  )?
  protectedIds;
  final Future<Set<String>> Function(String collectionId)? knownContentKeys;
  final Map<String, PortableFolderFingerprint> Function(String collectionId)?
  sourceFingerprints;
  final Future<int?> Function(Directory) _availableBytes;
  final PortableFolderTransfer _adapter;
  final Future<Directory> Function() _directoryProvider;
  ProgressSyncLan _lan;
  wire.FolderTransferTransport? _transport;
  FolderDirectTransport? _direct;
  final Map<String, FolderTransferTask> _tasks = {};
  final Map<String, String> _targets = {};
  final Map<String, Future<void>> _running = {};
  final Map<String, wire.FolderTransferCancellation> _cancellations = {};
  final Map<String, DateTime> _attemptedAt = {}, _reportedAt = {};
  final Map<String, int> _attempts = {};
  final Set<String> _stopped = {};
  final Map<String, List<String>> _inventories = {};
  final Map<String, Set<String>> _excludedNodes = {};
  final Map<String, PortableFolderFiles> _sourcePlans = {};

  Future<void> _releaseSourcePlan(String id) async {
    final plan = _sourcePlans.remove(id);
    if (plan != null) {
      try {
        await plan.release();
      } catch (_) {
        // Deferred cache deletion must not stop other task cleanup.
      }
    }
  }

  final String _wakeReason = 'folder_transfer_${const Uuid().v4()}';
  Timer? _timer, _notifyTimer, _saveTimer;
  bool _disposed = false, _online = false, _recovering = false;

  static Future<Directory> _defaultDirectory() async {
    final root = await SettingsService().resolveLargeDataRootDir();
    return Directory(p.join(root.path, 'portable_transfer', 'nearby'));
  }

  List<FolderTransferTask> get tasks =>
      _tasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  Map<String, dynamic> toJson() => {
    'tasks': [
      ...tasks.where((task) => task.isActive || task.canRetry),
      ...tasks.where((task) => !task.isActive && !task.canRetry),
    ].take(100).map((t) => t.toJson()).toList(),
    'targets': _targets,
  };

  Future<void> start({ProgressSyncLan? lan}) async {
    if (_disposed) return;
    if (lan != null && !identical(lan, _lan)) {
      await pause();
      _lan = lan;
    }
    _transport ??= wire.FolderTransferTransport(lan: _lan);
    _direct ??= FolderDirectTransport(_lan);
    await _transport!.start();
    _online = true;
    _timer?.cancel();
    if (autoRetry) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        unawaited(_recover());
      });
    }
    _changed();
  }

  static bool _validId(String id) =>
      RegExp(r'^[a-zA-Z0-9_-]{8,100}$').hasMatch(id);
  String _targetKey(FolderTransferTask task) =>
      '${task.peerId}|${task.sourceCollectionId}';
  LanSyncDevice _peer(String id) => _lan.nearbyDevices.firstWhere(
    (peer) => peer.id == id,
    orElse: () => throw const FormatException('设备暂未在线，连接后会自动继续'),
  );
  FolderTransferTask _task(String id) =>
      _tasks[id] ?? (throw const FormatException('传输任务已不存在'));
  bool _cancelled(FolderTransferTask task) =>
      _disposed ||
      !_online ||
      _stopped.contains(task.id) ||
      task.phase == FolderTransferPhase.cancelled;

  Future<void> sendFolder(
    String collectionId,
    String peerId, {
    Map<String, dynamic> syncOptions = const {},
  }) async {
    if (!_lan.isTrustedPeer(peerId)) {
      throw const FormatException('请先连接另一台设备');
    }
    final folder = library.getCollection(collectionId);
    if (folder == null || folder.isRecycled) {
      throw const FormatException('文件夹已不存在');
    }
    final previous = tasks.where(
      (t) =>
          !t.incoming &&
          t.peerId == peerId &&
          t.sourceCollectionId == collectionId &&
          t.isActive,
    );
    if (previous.isNotEmpty) return;
    if (_tasks.values.where((t) => t.isActive).length >= 8) {
      throw const FormatException('已有多个传输，请等待完成后再发送');
    }
    final task = FolderTransferTask(
      id: const Uuid().v4(),
      direction: FolderTransferDirection.send,
      peerId: peerId,
      peerName: peerNames()[peerId] ?? '我的设备',
      sourceCollectionId: collectionId,
      folderName: folder.name,
      createdAt: DateTime.now(),
      phase: FolderTransferPhase.preparing,
      stageLabel: '正在读取文件信息',
      syncOptions: Map.of(syncOptions),
    );
    _tasks[task.id] = task;
    _changed();
    _launch(task, () => _offer(task));
    _saveLater();
  }

  Future<void> _offer(FolderTransferTask task) async {
    bool containsPodcast(String id) {
      final folder = library.getCollection(id);
      return folder?.isPodcast == true ||
          (folder?.childrenIds.any(
                (child) =>
                    library.getCollection(child) != null &&
                    containsPodcast(child),
              ) ??
              false);
    }

    if (containsPodcast(task.sourceCollectionId)) {
      try {
        final capability = await _control(task, 'folder.capabilities', {
          'id': task.id,
        });
        if (capability['podcasts'] != 1) {
          throw const FormatException('请先更新对端软件以接收播客');
        }
        if ((capability['catalogPayload'] as num? ?? 1) < 2) {
          throw const FormatException('对端尚未支持播客顺序与设置继承，请更新后再传输');
        }
      } catch (_) {
        throw const FormatException('对端版本不支持播客，请更新后再传输这个文件夹');
      }
    }
    if (task.syncOptions['estimatedBytes'] is int) {
      task.mediaCount =
          (task.syncOptions['includeMediaIds'] as List?)?.length ?? 0;
      task.estimatedBytes = task.syncOptions['estimatedBytes'] as int;
    } else if (task.mediaCount == 0) {
      task.mediaCount = library
          .mediaInFolderTree(task.sourceCollectionId)
          .where((item) => !item.isRecycled)
          .length;
    }
    if (_cancelled(task)) return;
    task.phase = FolderTransferPhase.waiting;
    task.stageLabel = null;
    _changed();
    final reply = await _control(task, 'folder.offer', {
      'id': task.id,
      'sourceCollectionId': task.sourceCollectionId,
      'folderName': task.folderName,
      'mediaCount': task.mediaCount,
      'estimatedBytes': task.estimatedBytes,
      if (task.syncOptions['groupId'] is String)
        'groupId': task.syncOptions['groupId'],
      if (task.syncOptions['automatic'] == true) 'automatic': true,
      'directFiles': true,
      'directProtocol': 3,
    });
    if (reply['directFiles'] == true && reply['directProtocol'] != 3) {
      throw const FormatException('请更新另一台设备后重试安全文件同步');
    }
    task.syncOptions = {
      ...task.syncOptions,
      'directFiles': reply['directFiles'] == true,
    };
    await _save();
    if (reply['state'] == 'completed') {
      await _completeSend(task);
    } else if (reply['state'] == 'cancelled') {
      await _cancel(task, tellPeer: false);
    } else if (reply['accepted'] == true) {
      task.accepted = true;
      // The current short offer job must leave the per-task guard first.
      scheduleMicrotask(() => _scheduleSend(task));
    }
  }

  void _scheduleSend(FolderTransferTask task) {
    final pending = _running[task.id];
    if (pending != null) {
      unawaited(pending.then((_) => _scheduleSend(task)));
      return;
    }
    if (!_cancelled(task) && task.phase != FolderTransferPhase.completed) {
      _launch(task, () => _send(task));
    }
  }

  void _scheduleReceive(FolderTransferTask task) {
    final pending = _running[task.id];
    if (pending != null) {
      unawaited(pending.then((_) => _scheduleReceive(task)));
      return;
    }
    if (!_cancelled(task) && task.phase != FolderTransferPhase.completed) {
      _launch(task, () => _receive(task));
    }
  }

  Future<Map<String, dynamic>> handleControl(
    String peerId,
    String method,
    Map<String, dynamic> payload,
  ) async {
    final id = payload['id'];
    if (id is! String || !_validId(id)) {
      throw const FormatException('传输信息无效');
    }
    if (!_online || !_lan.isTrustedPeer(peerId)) {
      throw const FormatException('设备连接已失效，请重新配对后重试');
    }
    if (method == 'folder.capabilities') {
      return {
        'podcasts': 1,
        'catalogPayload': 2,
        'inheritance': 1,
        'viewState': 1,
        'directProtocol': 3,
      };
    }
    if (method == 'folder.offer') return _receiveOffer(peerId, id, payload);
    final task = _task(id);
    if (task.peerId != peerId) throw const FormatException('设备与传输不匹配');
    switch (method) {
      case 'folder.directReady':
        if (!task.incoming ||
            !task.accepted ||
            task.phase == FolderTransferPhase.cancelled) {
          throw const FormatException('传输已取消');
        }
        task.transportOffer = Map<String, dynamic>.from(
          payload['offer'] as Map,
        );
        task.syncOptions = {...task.syncOptions, 'directFiles': true};
        task.totalBytes = task.transportOffer!['size'] as int;
        _scheduleReceive(task);
        _saveLater();
        return {'ok': true};
      case 'folder.refresh':
        if (task.incoming ||
            !task.accepted ||
            task.phase == FolderTransferPhase.cancelled ||
            task.phase == FolderTransferPhase.completed) {
          return {'ok': false};
        }
        _transport?.cancelSend(task.id);
        _direct?.cancel(task.id);
        await _cleanup(task);
        task.syncDescriptor = null;
        task.transportOffer = null;
        task.totalBytes = 0;
        task.completedBytes = 0;
        task.phase = FolderTransferPhase.preparing;
        await _save();
        _scheduleSend(task);
        return {'ok': true};
      case 'folder.accept':
        if (task.incoming || task.phase == FolderTransferPhase.cancelled) {
          throw const FormatException('传输已取消');
        }
        task.accepted = true;
        _stopped.remove(id);
        _scheduleSend(task);
        return {'ok': true};
      case 'folder.ready':
        if (!task.incoming ||
            !task.accepted ||
            task.phase == FolderTransferPhase.cancelled) {
          throw const FormatException('请先确认接收');
        }
        final offer = wire.FolderTransferOffer.fromJson(
          Map<String, dynamic>.from(payload['offer'] as Map),
        );
        if (offer.transferId != id ||
            offer.senderId != peerId ||
            offer.receiverId != _lan.deviceId) {
          throw const FormatException('传输信息与设备不匹配');
        }
        task.transportOffer = offer.toJson();
        task.syncDescriptor = Map<String, dynamic>.from(payload['sync'] as Map);
        final expectedGroup = task.syncOptions['groupId'];
        if (expectedGroup != null &&
            (task.syncDescriptor!['group'] as Map?)?['id'] != expectedGroup) {
          throw const FormatException('传输不属于此关联文件夹');
        }
        task.totalBytes = offer.size;
        if (task.phase != FolderTransferPhase.completed) {
          _stopped.remove(id);
          _scheduleReceive(task);
        }
        _saveLater();
        return {'ok': true};
      case 'folder.stage':
        if (!task.incoming || !task.accepted || _running.containsKey(id)) {
          return {'ok': true};
        }
        if (task.phase != FolderTransferPhase.completed &&
            task.phase != FolderTransferPhase.cancelled) {
          task.phase = FolderTransferPhase.preparing;
          task.stageLabel = '对方正在准备文件';
          _changed();
        }
        return {'ok': true};
      case 'folder.progress':
        if (!task.incoming &&
            task.accepted &&
            task.phase != FolderTransferPhase.completed &&
            task.phase != FolderTransferPhase.cancelled) {
          final sequence = payload['seq'];
          if (sequence is! int || sequence <= task.lastRemoteSequence) {
            return {'ok': true};
          }
          task.lastRemoteSequence = sequence;
          final bytes = payload['bytes'], total = payload['total'];
          if (bytes is int &&
              total == task.totalBytes &&
              bytes >= 0 &&
              bytes <= task.totalBytes) {
            task.completedBytes = bytes;
          }
          final speed = payload['speed'];
          if (speed is num && speed.isFinite && speed >= 0) {
            task.bytesPerSecond = speed.toDouble();
          }
          task.phase = switch (payload['phase']) {
            'verifying' => FolderTransferPhase.verifying,
            'importing' => FolderTransferPhase.importing,
            'linking' => FolderTransferPhase.linking,
            _ => FolderTransferPhase.transferring,
          };
          final stage = payload['stageProgress'];
          task.stageProgress = stage is num && stage.isFinite
              ? stage.toDouble().clamp(0.0, 1.0)
              : null;
          task.stageLabel = null;
          _changed();
        }
        return {'ok': true};
      case 'folder.done':
        if (!task.incoming &&
            task.accepted &&
            task.phase != FolderTransferPhase.cancelled &&
            task.phase != FolderTransferPhase.completed) {
          if (payload['attention'] == true) {
            task.phase = FolderTransferPhase.needsAttention;
            task.bytesPerSecond = 0;
            task.stageLabel = null;
            final missing = payload['unavailableCount'];
            task.error = missing is int && missing > 0
                ? '有 $missing 个原文件缺失'
                : '有原文件未能同步';
            await _save();
            _changed();
          } else {
            await _completeSend(task);
          }
        }
        return {'ok': true};
      case 'folder.cancel':
        if (task.phase != FolderTransferPhase.completed) {
          await _cancel(task, tellPeer: false);
        }
        return {'ok': true};
      case 'folder.status':
        return {
          'state': task.phase.name,
          'accepted': task.accepted,
          'bytes': task.completedBytes,
          'total': task.totalBytes,
        };
      case 'folder.inventory':
        if (!task.incoming || !task.accepted || !task.isActive) {
          throw const FormatException('请先确认接收');
        }
        final offset = payload['offset'];
        if (offset is! int || offset < 0 || offset > 100000) {
          throw const FormatException('文件清单无效');
        }
        if (offset == 0 || !_inventories.containsKey(id)) {
          final target =
              task.syncOptions['targetCollectionId'] as String? ??
              _targets[_targetKey(task)];
          _inventories[id] =
              target != null && library.getCollection(target) != null
              ? <String>[
                  if (task.syncOptions['forceFullTransfer'] != true)
                    ...((await knownContentKeys?.call(target)) ?? <String>{}),
                  for (final node in suppressedIds?.call(target) ?? <String>{})
                    'skip:$node',
                ].take(100000).toList()
              : <String>[];
        }
        final keys = _inventories[id]!;
        final end = min(offset + 1000, keys.length);
        if (offset > keys.length) throw const FormatException('文件清单已更新');
        final page = keys.sublist(offset, end);
        final more = end < keys.length;
        if (!more) _inventories.remove(id);
        return {'keys': page, 'next': end, 'more': more};
      default:
        throw const FormatException('不支持此传输操作');
    }
  }

  Future<Map<String, dynamic>> _receiveOffer(
    String peerId,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final secureDirect =
        payload['directFiles'] == true && payload['directProtocol'] == 3;
    final existing = _tasks[id];
    if (existing != null) {
      if (!existing.incoming || existing.peerId != peerId) {
        throw const FormatException('传输标识不匹配');
      }
      existing.syncOptions = {
        ...existing.syncOptions,
        'directFiles': secureDirect,
      };
      return {
        'state': existing.phase.name,
        'accepted': existing.accepted,
        'directFiles': secureDirect,
        if (secureDirect) 'directProtocol': 3,
      };
    }
    if (_tasks.values.where((t) => t.isActive).length >= 8) {
      throw const FormatException('接收任务较多，请稍后重试');
    }
    final source = payload['sourceCollectionId'], name = payload['folderName'];
    final count = payload['mediaCount'], bytes = payload['estimatedBytes'];
    if (source is! String ||
        source.isEmpty ||
        source.length > 200 ||
        name is! String ||
        name.isEmpty ||
        name.length > 300 ||
        count is! int ||
        count < 0 ||
        count > 1000000 ||
        bytes is! int ||
        bytes < 0 ||
        bytes > 100 * 1024 * 1024 * 1024 * 1024) {
      throw const FormatException('文件夹信息无效');
    }
    final policy = payload['groupId'] is String
        ? await receivePolicy?.call(peerId, payload)
        : null;
    if (!_online || !_lan.isTrustedPeer(peerId)) {
      throw const FormatException('设备连接已失效');
    }
    final automatic =
        policy != null &&
        policy['autoAccept'] != false &&
        payload['automatic'] == true;
    _tasks[id] = FolderTransferTask(
      id: id,
      direction: FolderTransferDirection.receive,
      peerId: peerId,
      peerName: peerNames()[peerId] ?? '我的设备',
      sourceCollectionId: source,
      folderName: name,
      mediaCount: count,
      estimatedBytes: bytes,
      createdAt: DateTime.now(),
      phase: automatic
          ? FolderTransferPhase.preparing
          : FolderTransferPhase.offered,
      accepted: automatic,
      syncOptions: {...?policy, 'directFiles': secureDirect},
    );
    _changed();
    _saveLater();
    return {
      'state': _tasks[id]!.phase.name,
      'accepted': automatic,
      'directFiles': secureDirect,
      if (secureDirect) 'directProtocol': 3,
    };
  }

  Future<void> accept(
    String id, {
    String? existingCollectionId,
    String? destinationParentId,
  }) async {
    final task = _task(id);
    if (!task.incoming || task.phase == FolderTransferPhase.completed) return;
    if (task.phase == FolderTransferPhase.cancelled ||
        !_lan.isTrustedPeer(task.peerId)) {
      throw const FormatException('同步请求已取消或设备连接已失效');
    }
    if (existingCollectionId != null) {
      final folder = library.getCollection(existingCollectionId);
      if (folder == null || folder.isRecycled) {
        throw const FormatException('文件夹已不存在');
      }
    }
    if (destinationParentId != null) {
      final parent = library.getCollection(destinationParentId);
      if (existingCollectionId != null || parent == null || parent.isRecycled) {
        throw const FormatException('接收位置已不可用，请重新选择');
      }
    }
    final repeated = _targets[_targetKey(task)] != null;
    await _requireSpace(
      task,
      repeated
          ? 8 * 1024 * 1024
          : task.syncOptions['directFiles'] == true
          ? task.estimatedBytes + 8 * 1024 * 1024
          : task.estimatedBytes * 2 + 32 * 1024 * 1024,
    );
    task.accepted = true;
    task.syncOptions = {
      ...task.syncOptions,
      'manual': true,
      'acceptChoice': existingCollectionId == null
          ? 'receiveNew'
          : 'linkExisting',
      'targetCollectionId': ?existingCollectionId,
      'destinationParentId': destinationParentId,
    };
    task.phase = FolderTransferPhase.preparing;
    task.stageLabel = '等待对方准备文件';
    task.error = null;
    _stopped.remove(id);
    await _save();
    _changed();
    _launch(task, () async {
      await _control(task, 'folder.accept', {'id': id});
    });
  }

  Future<void> _sendDirect(FolderTransferTask task) async {
    task.phase = FolderTransferPhase.preparing;
    task.stageLabel = '正在读取文件列表';
    task.error = null;
    _changed();
    final directory = await _taskDirectory(task);
    // Only cached, unchanged content identities are compared. Sending never
    // waits for a full media-library hash scan or writes a temporary archive.
    final known = await _readInventory(task);
    final identities = stableIds?.call(task.sourceCollectionId) ?? {};
    final skipped = _excludedNodes.remove(task.id) ?? <String>{};
    final requested = (task.syncOptions['includeMediaIds'] as List?)
        ?.whereType<String>()
        .toSet();
    final include = skipped.isEmpty
        ? requested
        : {
            for (final item in library.mediaInFolderTree(
              task.sourceCollectionId,
            ))
              if ((requested == null || requested.contains(item.id)) &&
                  !skipped.contains(identities[item.id]))
                item.id,
          };
    final plan = await _adapter.prepareDirectFiles(
      library: library,
      collectionId: task.sourceCollectionId,
      includeMediaIds: include,
      includeSidecars: task.syncOptions['includeSidecars'] != false,
      skipContentKeys: known,
      knownFingerprints:
          sourceFingerprints?.call(task.sourceCollectionId) ?? {},
      isCancelled: () => _cancelled(task),
    );
    if (_cancelled(task)) {
      await plan.release();
      return;
    }
    _direct?.cancel(task.id);
    await _releaseSourcePlan(task.id);
    _sourcePlans[task.id] = plan;
    final offer = await _direct!.prepare(
      id: task.id,
      peerId: task.peerId,
      plan: plan,
      complete: (hashes) async {
        if (_cancelled(task)) throw const FormatException('传输已暂停');
        final fingerprints = Map<String, PortableFolderFingerprint>.of(
          plan.fingerprints,
        );
        final files = {for (final file in plan.files) file.relativePath: file};
        for (final record
            in (plan.manifest['snapshot']['videos'] as List).cast<Map>()) {
          final reference = (record['video'] as Map)['path'];
          if (record['isOnline'] == true ||
              reference is! String ||
              !reference.startsWith('@asset:')) {
            continue;
          }
          final path = reference.substring(7),
              file = files[path],
              hash = hashes[path];
          if (file != null && hash != null) {
            fingerprints[record['exportId']
                as String] = PortableFolderFingerprint(
              path: file.path,
              size: file.size,
              modifiedMs: file.modifiedMs,
              sha256: hash,
            );
          }
        }
        task.phase = FolderTransferPhase.linking;
        task.stageLabel = '正在完成文件夹关联';
        _changed();
        task.syncDescriptor = await buildLink(
          task.sourceCollectionId,
          task.peerId,
          fingerprints,
        );
        if (_cancelled(task)) throw const FormatException('传输已暂停');
        final nodes = {
          ...?stableIds?.call(task.sourceCollectionId),
          ...Map<String, String>.from(
            task.syncOptions['stableOverrides'] as Map? ?? {},
          ),
        };
        final snapshot = plan.manifest['snapshot'] as Map;
        final ids = <String>{
          for (final record in [
            ...snapshot['collections'],
            ...snapshot['videos'],
          ])
            record['exportId'] as String,
        };
        final manifest = {
          ...plan.manifest,
          'checksums': hashes,
          'stableIds': {
            for (final entry in nodes.entries)
              if (ids.contains(entry.key)) entry.key: entry.value,
          },
          'folderSync': syncMetadata?.call(task.sourceCollectionId) ?? {},
        };
        await _save();
        return {'manifest': manifest, 'sync': task.syncDescriptor};
      },
    );
    task.packagePath = p.join(directory.path, 'direct-source');
    task.transportOffer = offer;
    task.totalBytes = plan.totalBytes;
    task.phase = FolderTransferPhase.transferring;
    task.stageLabel = null;
    task.stageProgress = null;
    _changed();
    await _save();
    await _control(task, 'folder.directReady', {'id': task.id, 'offer': offer});
  }

  Future<void> _receiveDirect(FolderTransferTask task) async {
    task.error = null;
    final directory = await _taskDirectory(task);
    final files = Directory(p.join(directory.path, 'direct-files'));
    task.packagePath = files.path;
    final maximum = task.syncOptions['maxAutoTransferBytes'] as int? ?? 0;
    if (task.syncOptions['manual'] != true &&
        maximum > 0 &&
        task.totalBytes > maximum) {
      throw const FormatException('文件超过自动接收上限，请手动继续');
    }
    if (!await _incomingResourcesSatisfied(task)) {
      await _requireSpace(
        task,
        max(0, task.totalBytes - task.completedBytes) + 8 * 1024 * 1024,
      );
      task.phase = FolderTransferPhase.transferring;
      task.stageLabel = null;
      _changed();
      final received = await _direct!.receive(
        id: task.id,
        peerId: task.peerId,
        host: _peer(task.peerId).host,
        offer: task.transportOffer!,
        directory: files,
        isCancelled: () => _cancelled(task),
        bytesPerSecondLimit:
            task.syncOptions['bytesPerSecondLimit'] as int? ?? 0,
        onFilesReceived: () {
          task.phase = FolderTransferPhase.importing;
          task.stageLabel = '正在完成文件夹关联';
          task.bytesPerSecond = 0;
          _changed();
          _report(task, force: true);
        },
        onProgress: (completed, total, speed) {
          if (_cancelled(task)) return;
          task.completedBytes = completed;
          task.totalBytes = total;
          task.bytesPerSecond = speed;
          _changed();
          _saveLater();
          _report(task);
        },
      );
      if (_cancelled(task)) return;
      task.syncDescriptor = Map<String, dynamic>.from(received['sync'] as Map);
      final receivedManifest = Map<String, dynamic>.from(
        received['manifest'] as Map,
      );
      _noteUnavailable(task, receivedManifest);
      final expected = task.syncOptions['groupId'];
      if (expected != null &&
          (task.syncDescriptor!['group'] as Map)['id'] != expected) {
        throw const FormatException('文件夹关联不一致');
      }
      task.phase = FolderTransferPhase.importing;
      task.stageLabel = '正在加入媒体库';
      task.syncOptions = {
        ...task.syncOptions,
        'importStarted': true,
        'adopted': false,
      };
      _changed();
      _report(task, force: true);
      await _save();
      final existingId =
          task.syncOptions['targetCollectionId'] as String? ??
          _targets[_targetKey(task)];
      late PortableReceivedFolder imported;
      try {
        imported = await _adapter.importReceivedFolder(
          library: library,
          packagePath: '',
          receivedDirectory: files,
          receivedManifest: receivedManifest,
          beforeExtraLocalCopy: (bytes) =>
              _requireSpace(task, bytes + 8 * 1024 * 1024),
          existingFingerprints:
              existingId == null ||
                  task.syncOptions['forceFullTransfer'] == true
              ? {}
              : sourceFingerprints?.call(existingId) ?? {},
          originDeviceId: task.peerId,
          sourceCollectionId: task.sourceCollectionId,
          existingTargetCollectionId: existingId,
          existingLocalIds: existingId == null
              ? {}
              : localIds?.call(existingId) ?? {},
          suppressedNodeIds: existingId == null
              ? {}
              : suppressedIds?.call(existingId) ?? {},
          resolveProtectedNodeIds: existingId == null
              ? null
              : (metadata) =>
                    protectedIds?.call(existingId, metadata) ?? <String>{},
          isCancelled: () => _cancelled(task),
          onProgress: (progress, label) {
            task.stageProgress = progress;
            task.stageLabel = label;
            _changed();
          },
        );
      } catch (error) {
        task.syncOptions = {...task.syncOptions, 'importStarted': false};
        if (error is FormatException &&
            error.message == '接收端已有文件发生变化，请重新发送资源') {
          task.syncOptions = {...task.syncOptions, 'forceFullTransfer': true};
          await _cleanup(task);
          task.transportOffer = null;
          task.syncDescriptor = null;
          await _bestEffort(task, 'folder.refresh', {'id': task.id});
        }
        rethrow;
      }
      task.targetCollectionId = imported.collectionId;
      task.importedStableIds = Map.of(imported.stableToLocalIds);
      task.syncDescriptor = {
        ...task.syncDescriptor!,
        'catalog': imported.syncMetadata,
      };
      _targets[_targetKey(task)] = imported.collectionId;
      await _save();
      await _writeReceiveJournal(task, imported.fingerprints);
      await _adopt(task);
      await _save();
      if (_cancelled(task)) return;
      await _link(task, imported.fingerprints);
    } else {
      await _link(task, {});
    }
  }

  Future<void> _send(FolderTransferTask task) async {
    if (task.syncOptions['directFiles'] == true) return _sendDirect(task);
    if (_running.length > 3) throw const FormatException('正在等待其他传输完成');
    task.phase = FolderTransferPhase.preparing;
    task.error = null;
    task.bytesPerSecond = 0;
    _changed();
    await _bestEffort(task, 'folder.stage', {'id': task.id});
    final directory = await _taskDirectory(task);
    final file = File(p.join(directory.path, 'outgoing.fluentpack'));
    task.packagePath = file.path;
    Map<String, PortableFolderFingerprint> fingerprints = {};
    await prepareCatalog?.call(task.sourceCollectionId, task.peerId);
    if (!await file.exists() || task.syncDescriptor == null) {
      task.stageLabel = '正在核对已有文件';
      _changed();
      final known = await _readInventory(task);
      final identities = stableIds?.call(task.sourceCollectionId) ?? {};
      final skipped = _excludedNodes.remove(task.id) ?? <String>{};
      final requested = (task.syncOptions['includeMediaIds'] as List?)
          ?.whereType<String>()
          .toSet();
      final include = skipped.isEmpty
          ? requested
          : {
              for (final item in library.mediaInFolderTree(
                task.sourceCollectionId,
              ))
                if ((requested == null || requested.contains(item.id)) &&
                    !skipped.contains(identities[item.id]))
                  item.id,
            };
      final prepared = await _adapter.prepareFolderPackage(
        library: library,
        collectionId: task.sourceCollectionId,
        outputPath: file.path,
        isCancelled: () => _cancelled(task),
        skipContentKeys: known,
        knownFingerprints:
            sourceFingerprints?.call(task.sourceCollectionId) ?? {},
        includeMediaIds: include,
        includeSidecars: task.syncOptions['includeSidecars'] != false,
        stableIds: {
          ...identities,
          ...Map<String, String>.from(
            task.syncOptions['stableOverrides'] as Map? ?? {},
          ),
        },
        syncMetadata: syncMetadata?.call(task.sourceCollectionId) ?? {},
        onPayloadSize: (bytes) => _requireSpace(task, bytes + 32 * 1024 * 1024),
        onProgress: (progress, label) {
          if (_cancelled(task)) return;
          task.stageProgress = progress;
          task.stageLabel = label;
          _changed();
        },
      );
      fingerprints = prepared.fingerprints;
    }
    if (_cancelled(task)) return;
    task.stageLabel = '正在关联观看进度';
    task.stageProgress = null;
    _changed();
    task.syncDescriptor = await buildLink(
      task.sourceCollectionId,
      task.peerId,
      fingerprints,
    );
    if (_cancelled(task)) return;
    final sendCancellation = wire.FolderTransferCancellation();
    _cancellations[task.id] = sendCancellation;
    final offer = await _transport!.prepareSend(
      file,
      peerId: task.peerId,
      transferId: task.id,
      fileName: '${task.folderName}.fluentpack',
      cancellation: sendCancellation,
      onProgress: (progress) {
        if (_cancelled(task)) return;
        task.stageLabel = '正在准备安全传输';
        task.stageProgress = progress.totalBytes > 0
            ? progress.phaseBytes / progress.totalBytes
            : null;
        _changed();
      },
    );
    if (_cancelled(task)) return;
    task.transportOffer = offer.toJson();
    task.totalBytes = offer.size;
    task.phase = FolderTransferPhase.transferring;
    task.stageLabel = '等待接收';
    task.stageProgress = null;
    await _save();
    _changed();
    await _control(task, 'folder.ready', {
      'id': task.id,
      'offer': offer.toJson(),
      'sync': task.syncDescriptor,
    });
  }

  Future<void> _receive(FolderTransferTask task) async {
    if (task.transportOffer?['protocol'] == 2) {
      throw const FormatException('此传输使用旧版明文协议，请更新两台设备并重新发送');
    }
    if (task.transportOffer?['protocol'] == 3) return _receiveDirect(task);
    task.error = null;
    final directory = await _taskDirectory(task);
    final file = File(p.join(directory.path, 'incoming.fluentpack'));
    final journal = File(p.join(directory.path, 'receive.json'));
    task.packagePath = file.path;
    task.checkpointPath = journal.path;
    final offer = wire.FolderTransferOffer.fromJson(task.transportOffer!);
    final maximum = task.syncOptions['maxAutoTransferBytes'] as int? ?? 0;
    if (task.syncOptions['manual'] != true &&
        maximum > 0 &&
        offer.size > maximum) {
      throw const FormatException('文件超过自动接收上限，请手动继续');
    }
    final cancellation = wire.FolderTransferCancellation();
    _cancellations[task.id] = cancellation;
    if (!await _incomingResourcesSatisfied(task)) {
      await _requireSpace(
        task,
        max(0, offer.size * 2 - task.completedBytes) + 32 * 1024 * 1024,
      );
      task.phase = FolderTransferPhase.transferring;
      task.stageLabel = null;
      _changed();
      await _transport!.receive(
        offer,
        destination: file,
        checkpointFile: journal,
        cancellation: cancellation,
        bytesPerSecondLimit:
            task.syncOptions['bytesPerSecondLimit'] as int? ?? 0,
        onProgress: (progress) {
          if (_cancelled(task)) return;
          task.totalBytes = progress.totalBytes;
          task.completedBytes = progress.verifiedBytes;
          task.bytesPerSecond = progress.bytesPerSecond;
          task.phase = progress.phase == wire.FolderTransferPhase.verifying
              ? FolderTransferPhase.verifying
              : FolderTransferPhase.transferring;
          task.stageProgress =
              task.phase == FolderTransferPhase.verifying &&
                  progress.totalBytes > 0
              ? progress.phaseBytes / progress.totalBytes
              : null;
          _changed();
          _saveLater();
          _report(task);
        },
      );
      if (_cancelled(task)) return;
      task.completedBytes = offer.size;
      task.phase = FolderTransferPhase.importing;
      task.stageProgress = null;
      task.stageLabel = '正在加入媒体库';
      _changed();
      _report(task, force: true);
      final existingId =
          task.syncOptions['targetCollectionId'] as String? ??
          _targets[_targetKey(task)];
      late PortableReceivedFolder imported;
      task.syncOptions = {
        ...task.syncOptions,
        'importStarted': true,
        'adopted': false,
      };
      // Persist the capture barrier before any importer can write library cards.
      // A restart must finish this transaction before publishing local changes.
      await _save();
      try {
        imported = await _adapter.importReceivedFolder(
          library: library,
          packagePath: file.path,
          beforeExtraLocalCopy: (bytes) =>
              _requireSpace(task, bytes + 8 * 1024 * 1024),
          originDeviceId: task.peerId,
          sourceCollectionId: task.sourceCollectionId,
          existingTargetCollectionId:
              existingId != null && library.getCollection(existingId) != null
              ? existingId
              : null,
          existingLocalIds: existingId == null
              ? {}
              : localIds?.call(existingId) ?? {},
          reconcileStructure: false,
          suppressedNodeIds: existingId == null
              ? {}
              : suppressedIds?.call(existingId) ?? {},
          resolveProtectedNodeIds: existingId == null
              ? null
              : (metadata) =>
                    protectedIds?.call(existingId, metadata) ?? <String>{},
          isCancelled: () => _cancelled(task),
          onProgress: (progress, label) {
            if (_cancelled(task)) return;
            task.stageProgress = progress;
            task.stageLabel = label;
            _changed();
            _report(task);
          },
        );
      } catch (error) {
        task.syncOptions = {...task.syncOptions, 'importStarted': false};
        if (error is FormatException &&
            error.message == '接收端已有文件发生变化，请重新发送资源') {
          await _cleanup(task);
          task.transportOffer = null;
          task.syncDescriptor = null;
          await _bestEffort(task, 'folder.refresh', {'id': task.id});
        }
        rethrow;
      }
      task.targetCollectionId = imported.collectionId;
      task.importedStableIds = Map.of(imported.stableToLocalIds);
      task.syncDescriptor = {
        ...task.syncDescriptor!,
        'catalog': imported.syncMetadata,
      };
      _targets[_targetKey(task)] = imported.collectionId;
      await _save();
      await _writeReceiveJournal(task, imported.fingerprints);
      await _adopt(task);
      await _save();
      if (_cancelled(task)) return;
      await _link(task, imported.fingerprints);
    } else {
      await _link(task, {});
    }
  }

  Future<void> _link(
    FolderTransferTask task,
    Map<String, PortableFolderFingerprint> fingerprints,
  ) async {
    if (_cancelled(task)) return;
    if (task.incoming &&
        task.syncOptions['acceptChoice'] == 'receiveNew' &&
        task.syncOptions['destinationApplied'] != true) {
      final parentId = task.syncOptions['destinationParentId'] as String?;
      if (parentId != null) {
        final parent = library.getCollection(parentId);
        if (parent == null || parent.isRecycled) {
          throw const FormatException('接收位置已不可用，已收到的文件仍保留在媒体库');
        }
        await library.moveItemToCollection(task.targetCollectionId!, parentId);
      }
      task.syncOptions = {...task.syncOptions, 'destinationApplied': true};
      await _save();
    }
    task.phase = FolderTransferPhase.linking;
    task.stageProgress = null;
    task.stageLabel = '正在完成同步关联';
    _changed();
    _report(task, force: true);
    await _adopt(task);
    if (_cancelled(task)) return;
    await receiveLink(
      task.syncDescriptor!,
      task.peerId,
      task.targetCollectionId!,
      fingerprints,
    );
    if (_cancelled(task)) return;
    if (fingerprints.isNotEmpty) {
      await _writeReceiveJournal(task, fingerprints);
    }
    final missing = task.syncOptions['unavailableCount'] as int? ?? 0;
    if (missing > 0 || !await _incomingResourcesSatisfied(task)) {
      // Relationship can exist while required originals are still absent.
      // Completion is reserved for a folder whose local cards can play.
      task.phase = FolderTransferPhase.needsAttention;
      task.bytesPerSecond = 0;
      task.stageProgress = null;
      task.stageLabel = null;
      task.error = missing > 0 ? '有 $missing 个原文件缺失' : '原文件缺失';
      await _save();
      _changed();
      await _notifyTerminal(task, attention: true);
      return;
    }
    task.phase = FolderTransferPhase.completed;
    task.completedBytes = task.totalBytes;
    task.bytesPerSecond = 0;
    task.stageProgress = null;
    task.stageLabel = null;
    await _save();
    _changed();
    await _notifyTerminal(task);
    await _cleanup(task);
  }

  Future<void> _adopt(FolderTransferTask task) async {
    if (task.syncOptions['adopted'] == true) return;
    await onImported?.call(task.peerId, task.targetCollectionId!, {
      ...task.syncDescriptor!,
      'allowRebind': task.syncOptions['manual'] == true && !_cancelled(task),
      'cancelled': _cancelled(task),
    }, task.importedStableIds);
    task.syncOptions = {
      ...task.syncOptions,
      // A pause/cancel may have made the coordinator deliberately defer the
      // initial association. Resuming must retry adoption before receiveLink.
      'adopted': !_cancelled(task),
      'importStarted': false,
    };
  }

  Future<void> _completeSend(FolderTransferTask task) async {
    if (task.phase == FolderTransferPhase.cancelled) return;
    task.phase = FolderTransferPhase.completed;
    task.peerNotified = true;
    task.completedBytes = task.totalBytes;
    task.bytesPerSecond = 0;
    task.stageLabel = null;
    task.stageProgress = null;
    _transport?.cancelSend(task.id);
    _direct?.cancel(task.id);
    await _save();
    _changed();
    await _cleanup(task);
  }

  void _report(FolderTransferTask task, {bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_reportedAt[task.id] ?? DateTime(0)) <
            const Duration(milliseconds: 600)) {
      return;
    }
    _reportedAt[task.id] = now;
    unawaited(
      _bestEffort(task, 'folder.progress', {
        'id': task.id,
        'bytes': task.completedBytes,
        'total': task.totalBytes,
        'speed': task.bytesPerSecond,
        'phase': task.phase.name,
        'stageProgress': task.stageProgress,
        'seq': ++task.reportSequence,
      }),
    );
  }

  Future<Map<String, dynamic>> _control(
    FolderTransferTask task,
    String method,
    Map<String, dynamic> payload,
  ) => _lan.sendControl(_peer(task.peerId), method, payload);
  Future<void> _bestEffort(
    FolderTransferTask task,
    String method,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _control(task, method, payload);
    } catch (_) {}
  }

  Future<void> _notifyTerminal(
    FolderTransferTask task, {
    bool attention = false,
  }) async {
    if (task.peerNotified) return;
    try {
      await _control(
        task,
        task.phase == FolderTransferPhase.cancelled
            ? 'folder.cancel'
            : 'folder.done',
        {
          'id': task.id,
          if (attention) 'attention': true,
          'unavailableCount': task.syncOptions['unavailableCount'] ?? 0,
        },
      );
      task.peerNotified = true;
      await _save();
    } catch (_) {
      /* Retry the acknowledgement after the device returns. */
    }
  }

  void _launch(FolderTransferTask task, Future<void> Function() operation) {
    if (_disposed || _running.containsKey(task.id)) return;
    _attemptedAt[task.id] = DateTime.now();
    _stopped.remove(task.id);
    final work = Future<void>.sync(operation).catchError((Object error) async {
      if (_disposed ||
          task.phase == FolderTransferPhase.cancelled ||
          task.phase == FolderTransferPhase.completed) {
        return;
      }
      task.phase = FolderTransferPhase.paused;
      _direct?.cancel(task.id);
      await _releaseSourcePlan(task.id);
      task.bytesPerSecond = 0;
      task.stageLabel = null;
      final os = error is FileSystemException ? error.osError?.errorCode : null;
      final detail = error is FormatException ? error.message : '';
      task.error = os == 28 || os == 112
          ? '空间不足，腾出空间后可继续'
          : RegExp(r'^[\u3400-\u9FFF]').hasMatch(detail) && detail.length < 160
          ? detail
          : '传输已暂停，设备重新连接后自动继续';
      _attempts[task.id] = (_attempts[task.id] ?? 0) + 1;
      _changed();
      try {
        await _save();
      } catch (_) {}
    });
    _running[task.id] = work;
    unawaited(
      work.whenComplete(() {
        _running.remove(task.id);
        _cancellations.remove(task.id);
        if (task.phase == FolderTransferPhase.cancelled) {
          unawaited(_cleanup(task));
        }
      }),
    );
  }

  Future<void> retry(String id) async {
    final task = _task(id);
    if (task.phase == FolderTransferPhase.completed ||
        task.phase == FolderTransferPhase.cancelled ||
        !_online) {
      return;
    }
    task.error = null;
    _stopped.remove(id);
    if (task.incoming) {
      final linked =
          task.targetCollectionId != null && task.syncDescriptor != null;
      if (linked && await _incomingResourcesSatisfied(task)) {
        _launch(task, () => _link(task, {}));
      } else if (task.syncOptions['forceFullTransfer'] == true &&
          task.accepted) {
        await _cleanup(task);
        task.transportOffer = null;
        task.syncDescriptor = null;
        task.phase = FolderTransferPhase.preparing;
        await _save();
        await _bestEffort(task, 'folder.refresh', {'id': task.id});
      } else if (task.accepted && task.transportOffer != null) {
        _launch(task, () => _receive(task));
      } else if (linked) {
        task.phase = FolderTransferPhase.needsAttention;
        task.bytesPerSecond = 0;
        task.error = '原文件缺失';
        _changed();
        await _save();
      } else {
        await accept(id);
      }
    } else if (task.accepted) {
      _scheduleSend(task);
    } else {
      _launch(task, () => _offer(task));
    }
    _changed();
  }

  Future<void> reject(String id) => _cancel(_task(id));
  Future<void> cancel(String id) => _cancel(_task(id));
  Future<void> _cancel(FolderTransferTask task, {bool tellPeer = true}) async {
    if (task.phase == FolderTransferPhase.completed) return;
    _stopped.add(task.id);
    task.phase = FolderTransferPhase.cancelled;
    task.bytesPerSecond = 0;
    task.error = null;
    _cancellations[task.id]?.cancel();
    _direct?.cancel(task.id);
    _transport?.cancelSend(task.id);
    await _releaseSourcePlan(task.id);
    _changed();
    await _save();
    if (tellPeer) {
      unawaited(_notifyTerminal(task));
    } else {
      task.peerNotified = true;
      await _save();
    }
    if (!_running.containsKey(task.id)) await _cleanup(task);
  }

  Future<void> dismiss(String id) async {
    final task = _task(id);
    if (task.isActive || _running.containsKey(id)) return;
    if (task.canRetry) await _cancel(task);
    await _cleanup(task);
    _tasks.remove(id);
    await _save();
    _changed();
  }

  Future<void> _recover() async {
    if (!_online || _disposed || _recovering) return;
    _recovering = true;
    try {
      for (final task in tasks) {
        if (_running.containsKey(task.id) ||
            task.phase == FolderTransferPhase.offered ||
            ((task.phase == FolderTransferPhase.completed ||
                    task.phase == FolderTransferPhase.cancelled) &&
                task.peerNotified)) {
          continue;
        }
        if (!_lan.nearbyDevices.any((peer) => peer.id == task.peerId)) continue;
        final backoff = min(60, 4 * (1 << min(4, _attempts[task.id] ?? 0)));
        if (DateTime.now().difference(_attemptedAt[task.id] ?? DateTime(0)) <
            Duration(seconds: backoff)) {
          continue;
        }
        _attemptedAt[task.id] = DateTime.now();
        if (task.phase == FolderTransferPhase.completed ||
            task.phase == FolderTransferPhase.cancelled) {
          await _notifyTerminal(task);
        } else if (task.canRetry) {
          await retry(task.id);
        } else if (!task.incoming &&
            task.phase == FolderTransferPhase.waiting) {
          _launch(task, () => _offer(task));
        } else if (!task.incoming && task.accepted) {
          try {
            final status = await _control(task, 'folder.status', {
              'id': task.id,
            });
            if (status['state'] == 'completed') await _completeSend(task);
            if (status['state'] == 'cancelled') {
              await _cancel(task, tellPeer: false);
            }
          } catch (_) {
            /* The receiver can finish from a durable checkpoint. */
          }
        } else if (task.incoming && task.accepted) {
          await accept(task.id);
        }
      }
    } finally {
      _recovering = false;
    }
  }

  void _noteUnavailable(
    FolderTransferTask task,
    Map<String, dynamic> manifest,
  ) {
    final count = manifest['unavailableCount'];
    if (count is int && count >= 0) {
      task.syncOptions = {...task.syncOptions, 'unavailableCount': count};
    }
    final snapshot = manifest['snapshot'];
    final videos = snapshot is Map ? snapshot['videos'] : null;
    if (videos is List) {
      // The offer counts the source folder before the receiver's suppressed
      // nodes are excluded. A valid resend can therefore require zero cards.
      task.syncOptions = {
        ...task.syncOptions,
        'requiredMediaCount': videos.length,
      };
    }
  }

  /// True only when this task already published a local root whose required
  /// files can be opened outside the task directory. A chosen target id or an
  /// empty folder shell is not enough.
  Future<bool> _incomingResourcesSatisfied(FolderTransferTask task) async {
    final id = task.targetCollectionId;
    if (id == null || library.getCollection(id) == null) return false;
    if ((task.syncOptions['unavailableCount'] as int? ?? 0) > 0) return false;
    final videos = library
        .mediaInFolderTree(id)
        .where((item) => !item.isRecycled && !item.isTransient)
        .toList();
    if (videos.isEmpty) {
      return (task.syncOptions['requiredMediaCount'] ?? task.mediaCount) == 0;
    }
    final root = p.normalize((await _directoryProvider()).path);
    final taskDir = p.join(root, task.id);
    var localFiles = 0;
    for (final item in videos) {
      final origin = await classifySyncMediaOrigin(
        path: item.path,
        playbackPath: item.playbackPath ?? item.bilibiliDownloadPath,
        sourceKind: item.sourceRef?.kind,
      );
      if (origin.placement == SyncMediaPlacement.onlineReference) {
        if (item.sourceRef?.cloudDrive != null) return false;
        continue;
      }
      final local = origin.localPath;
      if (origin.placement != SyncMediaPlacement.localFile || local == null) {
        return false;
      }
      final file = File(local);
      if (!await file.exists() || p.isWithin(taskDir, p.normalize(file.path))) {
        return false;
      }
      try {
        final opened = await file.open();
        await opened.close();
      } catch (_) {
        return false;
      }
      localFiles++;
    }
    if (localFiles > 0) {
      final valid = await validateReceivedFolderFiles(
        journalFile: File(p.join(taskDir, 'receive-journal.json')),
        transferId: task.id,
        peerId: task.peerId,
        targetRootId: id,
        currentMediaPath: (cardId) {
          final item = library.getVideo(cardId);
          return item?.bilibiliDownloadPath ?? item?.path;
        },
        isCancelled: () => _cancelled(task),
      );
      if (!valid) {
        task.syncOptions = {...task.syncOptions, 'forceFullTransfer': true};
        return false;
      }
    }
    return true;
  }

  Future<void> _writeReceiveJournal(
    FolderTransferTask task,
    Map<String, PortableFolderFingerprint> fingerprints,
  ) async {
    final directory = await _taskDirectory(task);
    final group = task.syncOptions['groupId'];
    final journal = FolderReceiveJournal(
      transferId: task.id,
      groupId: group is String ? group : '',
      peerId: task.peerId,
      manifestRevision: task.id,
      targetDirectory: directory.path,
      targetRootId: task.targetCollectionId,
      assets: [
        for (final entry in fingerprints.entries)
          ReceiveAssetRecord(
            assetId: entry.key,
            nodeIds: [entry.key],
            role: 'primary',
            expectedLength: entry.value.size,
            stage: ReceiveAssetStage.attached,
            permanentPath: entry.value.path,
            cardId: entry.key,
            contentIdentity: entry.value.sha256,
            confirmedBytes: entry.value.size,
          ),
      ],
    );
    await FolderReceiveJournal.save(
      File(p.join(directory.path, 'receive-journal.json')),
      journal,
    );
  }

  Future<Directory> _taskDirectory(FolderTransferTask task) async {
    final root = await _directoryProvider();
    if (!_validId(task.id)) throw const FormatException('传输标识无效');
    final directory = Directory(p.join(root.path, task.id));
    await directory.create(recursive: true);
    _changed();
    return directory;
  }

  Future<void> _requireSpace(FolderTransferTask task, int requiredBytes) async {
    final available = await _availableBytes(await _directoryProvider());
    final reserve = task.syncOptions['minFreeBytes'] as int? ?? 0;
    if (available != null && available < requiredBytes + reserve) {
      task.error = '空间不足，腾出空间后可继续';
      _changed();
      throw const FormatException('空间不足，腾出空间后可继续');
    }
  }

  Future<Set<String>> _readInventory(FolderTransferTask task) async {
    final keys = <String>{};
    final skipped = <String>{};
    try {
      var offset = 0;
      for (var page = 0; page < 100; page++) {
        final reply = await _control(task, 'folder.inventory', {
          'id': task.id,
          'offset': offset,
        });
        for (final value in reply['keys'] as List? ?? []) {
          if (value is String &&
              value.startsWith('skip:') &&
              value.length <= 133) {
            skipped.add(value.substring(5));
          }
          if (value is String &&
              RegExp(r'^sha256:\d+:[a-f0-9]{64}$').hasMatch(value)) {
            keys.add(value);
          }
        }
        if (reply['more'] != true) break;
        final next = reply['next'];
        if (next is! int || next <= offset) break;
        offset = next;
      }
    } catch (_) {
      /* Missing inventories fall back to the complete valid pack. */
    }
    _excludedNodes[task.id] = skipped;
    return keys;
  }

  Future<void> _cleanup(FolderTransferTask task) async {
    _direct?.cancel(task.id);
    await _releaseSourcePlan(task.id);
    try {
      final root = p.normalize(p.absolute((await _directoryProvider()).path));
      final directory = p.join(root, task.id);
      for (final name in [
        'outgoing.fluentpack',
        'outgoing.fluentpack.part',
        'incoming.fluentpack',
        'incoming.fluentpack.part',
        'receive.json',
        'receive.json.tmp',
        'direct-receipt.json',
        'direct-receipt.json.next',
      ]) {
        final file = File(p.join(directory, name));
        if (p.isWithin(root, p.normalize(p.absolute(file.path))) &&
            await file.exists()) {
          await file.delete();
        }
      }
      for (final name in ['direct-files', 'direct-parts']) {
        final path = p.normalize(p.absolute(p.join(directory, name)));
        if (p.isWithin(root, path)) {
          final folder = Directory(path);
          if (await folder.exists()) await folder.delete(recursive: true);
        }
      }
      final dir = Directory(directory);
      if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
    } catch (_) {
      /* Managed storage cleanup can remove unused remnants later. */
    }
  }

  void _changed() {
    if (_disposed) return;
    AppWakelockCoordinator.setActive(
      _wakeReason,
      _online &&
          _tasks.values.any(
            (task) => switch (task.phase) {
              FolderTransferPhase.preparing ||
              FolderTransferPhase.transferring ||
              FolderTransferPhase.verifying ||
              FolderTransferPhase.importing ||
              FolderTransferPhase.linking => true,
              _ => false,
            },
          ),
    );
    FolderTransferStorage.instance.update(
      this,
      {
        for (final task in _tasks.values)
          if (task.isActive || task.canRetry)
            for (final path in [task.packagePath, task.checkpointPath])
              if (path != null) p.dirname(path),
      },
      {
        for (final task in _tasks.values)
          if (!task.incoming && task.isActive) task.sourceCollectionId,
      },
    );
    _notifyTimer ??= Timer(const Duration(milliseconds: 180), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _save() => persistState();
  void _saveLater() {
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(_save().catchError((Object _) {}));
    });
  }

  Future<void> pause() async {
    _online = false;
    _timer?.cancel();
    for (final task in _tasks.values) {
      if (task.phase == FolderTransferPhase.completed ||
          task.phase == FolderTransferPhase.cancelled ||
          task.phase == FolderTransferPhase.offered) {
        continue;
      }
      _stopped.add(task.id);
      _cancellations[task.id]?.cancel();
      task.phase = FolderTransferPhase.paused;
      task.bytesPerSecond = 0;
    }
    await _transport?.close();
    _transport = null;
    await _direct?.close();
    _direct = null;
    for (final id in _sourcePlans.keys.toList()) {
      await _releaseSourcePlan(id);
    }
    try {
      await Future.wait(
        _running.values.toList(),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      /* Cancelled jobs retain their journal for the next start. */
    }
    _changed();
    await _save();
  }

  @override
  void dispose() {
    _disposed = true;
    _online = false;
    _timer?.cancel();
    _notifyTimer?.cancel();
    _saveTimer?.cancel();
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    unawaited(_transport?.close());
    unawaited(_direct?.close());
    for (final id in _sourcePlans.keys.toList()) {
      unawaited(_releaseSourcePlan(id));
    }
    AppWakelockCoordinator.setActive(_wakeReason, false);
    FolderTransferStorage.instance.remove(this);
    super.dispose();
  }
}
