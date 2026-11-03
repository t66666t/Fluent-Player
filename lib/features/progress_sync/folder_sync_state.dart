import 'dart:convert';
import 'dart:math';

import 'folder_sync_models.dart';

/// Causal catalog for one shared folder. This class performs no I/O and never
/// treats a missing scan entry as a deletion. Persist the complete state locally;
/// exchange only [events], never another installation's local bindings.
class FolderSyncState {
  FolderSyncState({
    required this.groupId,
    required this.deviceId,
    String? deviceName,
    FolderSyncSettings settings = const FolderSyncSettings(),
    String Function()? newId,
    int Function()? nowMs,
  }) : deviceName = deviceName ?? deviceId,
       _settings = FolderSyncSettings.fromJson(settings.toJson()),
       _newId = newId ?? _randomId,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    folderSyncValidateId(groupId, 'groupId');
    folderSyncValidateId(deviceId, 'deviceId');
    if (this.deviceName.length > 100 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(this.deviceName)) {
      throw const FormatException('设备名称无效');
    }
  }
  static const maxNodes = 50000, maxEvents = 200000, maxDepth = 256;
  final String groupId, deviceId, deviceName;
  FolderSyncSettings _settings;
  final String Function() _newId;
  final int Function() _nowMs;
  final Map<String, FolderSyncEvent> _events = {};
  final Map<String, Map<String, FolderSyncEvent>> _heads = {};
  final Map<String, String> _localBindings = {}, _nodeBindings = {};
  final Map<String, String> _appliedSignatures = {};
  final Map<String, Map<String, int>> _appliedClocks = {};
  final Map<String, FolderSyncNode> _appliedNodes = {};
  final Set<String> _suppressed = {};
  final Map<String, Map<String, List<FolderSyncAcknowledgement>>>
  _acknowledged = {};
  int _sequence = 0, _acknowledgementCount = 0;
  _Projection? _projection;
  List<FolderSyncEvent>? _activeEvents;

  FolderSyncSettings get settings => _settings;
  void updateSettings(FolderSyncSettings value) {
    _settings = FolderSyncSettings.fromJson(value.toJson());
  }

  bool get canPublish =>
      settings.mode == FolderSyncMode.smart ||
      (settings.mode == FolderSyncMode.oneWay &&
          settings.sourceDeviceId == deviceId);
  List<FolderSyncEvent> get events => List.unmodifiable(_events.values);

  /// Exchange current causal heads rather than the complete local history.
  /// Concurrent differing meanings and equal-clock forks are all retained.
  List<FolderSyncEvent> get activeEvents => _activeEvents ??= List.unmodifiable(
    [for (final versions in _heads.values) ...versions.values],
  );

  /// Discard strictly superseded history in occasional explicit maintenance.
  /// Local applied branches remain in their independent baseline records.
  int compact() {
    if (_events.length <= 1000 ||
        _events.length <= activeEvents.length * 2 + 1000) {
      return 0;
    }
    final before = _events.length;
    _events.removeWhere((id, event) {
      final current = _heads[event.node.id];
      return current != null &&
          !current.containsKey(id) &&
          current.values.any((head) => head.descendsFrom(event));
    });
    return before - _events.length;
  }

  Map<String, String> get localBindings => Map.unmodifiable(_localBindings);
  Map<String, String> get nodeBindings => Map.unmodifiable(_nodeBindings);
  Set<String> get suppressedNodeIds => Set.unmodifiable(_suppressed);
  String? nodeIdForLocal(String localId) => _localBindings[localId];
  String? localIdForNode(String nodeId) => _nodeBindings[nodeId];
  String? appliedSignature(String nodeId) => _appliedSignatures[nodeId];
  Map<String, int> appliedClock(String nodeId) =>
      Map.unmodifiable(_appliedClocks[nodeId] ?? const {});
  FolderSyncNode? appliedNode(String nodeId) => _appliedNodes[nodeId];
  List<FolderSyncEvent> heads(String nodeId) {
    final result =
        (_heads[nodeId]?.values ?? const <FolderSyncEvent>[]).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(result);
  }

  _Projection get _view => _projection ??= _project();

  /// Canonical safe logical tree, independent of local remove/suppression.
  Map<String, FolderSyncNode> get safeNodes => _view.nodes;

  /// Apply this view locally: suppressions include descendants automatically.
  Map<String, FolderSyncNode> get applicableNodes => Map.unmodifiable({
    for (final entry in safeNodes.entries)
      if (!isSuppressed(entry.key)) entry.key: entry.value,
  });
  String? get rootNodeId => _view.rootId;
  Set<String> get safeDeletedNodeIds => _view.deleted;
  List<FolderSyncIssue> get issues => _view.issues;

  void bindLocal(String localId, String nodeId, {bool replace = false}) {
    _validateLocalId(localId);
    folderSyncValidateId(nodeId, 'nodeId');
    final oldNode = _localBindings[localId], oldLocal = _nodeBindings[nodeId];
    if (!replace &&
        ((oldNode != null && oldNode != nodeId) ||
            (oldLocal != null && oldLocal != localId))) {
      throw StateError('条目已经关联其他同步身份');
    }
    if (_localBindings.length >= maxNodes &&
        oldNode == null &&
        oldLocal == null) {
      throw const FormatException('本地关联数量过多');
    }
    if (oldNode != null && oldNode != nodeId) _nodeBindings.remove(oldNode);
    if (oldLocal != null && oldLocal != localId) {
      _localBindings.remove(oldLocal);
    }
    _localBindings[localId] = nodeId;
    _nodeBindings[nodeId] = localId;
  }

  void unbindLocal(String localId, {bool suppress = false}) {
    final nodeId = _localBindings.remove(localId);
    if (nodeId == null) return;
    _nodeBindings.remove(nodeId);
    if (suppress) this.suppress(nodeId);
  }

  void suppress(String nodeId) {
    folderSyncValidateId(nodeId, 'nodeId');
    if (_suppressed.length >= maxNodes && !_suppressed.contains(nodeId)) {
      throw const FormatException('本机排除数量过多');
    }
    _suppressed.add(nodeId);
  }

  void unsuppress(String nodeId) => _suppressed.remove(nodeId);
  bool isSuppressed(String nodeId) {
    if (_suppressed.isEmpty) return false;
    final visited = <String>{};
    String? cursor = nodeId;
    while (cursor != null && visited.add(cursor)) {
      if (_suppressed.contains(cursor)) return true;
      final node =
          _view.nodes[cursor] ??
          _appliedNodes[cursor] ??
          _heads[cursor]?.values.firstOrNull?.node;
      cursor = node?.parentId;
    }
    return false;
  }

  /// Call only after the corresponding remote version really exists locally.
  /// This records the branch applied, not every remote branch merely received.
  void markApplied(
    String nodeId, {
    required String localId,
    FolderSyncNode? appliedNode,
    Map<String, int>? clock,
    bool? deleted,
  }) {
    final versions = heads(nodeId);
    final node =
        appliedNode ??
        (versions.map((e) => e.semanticSignature).toSet().length == 1
            ? versions.first.node
            : null);
    if (node == null || node.id != nodeId) throw StateError('请明确已应用的目录版本');
    node.validate();
    if (!_appliedNodes.containsKey(nodeId) &&
        _appliedNodes.length >= maxNodes) {
      throw const FormatException('本地应用记录数量过多');
    }
    final wasDeleted =
        deleted ?? (versions.isNotEmpty && versions.every((e) => e.deleted));
    final signature = node.signature(deleted: wasDeleted);
    final matching = versions
        .where((e) => e.semanticSignature == signature)
        .toList();
    final appliedClock =
        clock ?? folderSyncMergeClocks(matching.map((e) => e.clock));
    folderSyncValidateClock(appliedClock, allowEmpty: true);
    bindLocal(localId, nodeId);
    _appliedNodes[nodeId] = node;
    _appliedSignatures[nodeId] = signature;
    _appliedClocks[nodeId] = Map.of(appliedClock);
  }

  /// Only explicit user deletion can emit a tombstone. An unavailable disk,
  /// partial scan, missing file, or filtered entry never implies deletion.
  List<FolderSyncEvent> capture(
    List<FolderSyncLocalEntry> snapshot, {
    bool available = true,
    Set<String> explicitlyDeletedLocalIds = const {},
    Set<String> suppressedLocalIds = const {},
  }) {
    if (!available) return const [];
    if (snapshot.length > maxNodes ||
        explicitlyDeletedLocalIds.length > maxNodes ||
        suppressedLocalIds.length > maxNodes) {
      throw const FormatException('本地目录数量过多');
    }
    final entries = <String, FolderSyncLocalEntry>{};
    for (final entry in snapshot) {
      _validateLocalId(entry.localId);
      if (entry.parentLocalId != null) _validateLocalId(entry.parentLocalId!);
      if (entries.containsKey(entry.localId)) {
        throw const FormatException('本地条目标识重复');
      }
      FolderSyncNode(
        id: 'validate',
        kind: entry.kind,
        name: entry.name,
        size: entry.size,
        contentKey: entry.contentKey,
        extension: entry.extension,
      ).validate();
      entries[entry.localId] = entry;
    }
    for (final entry in snapshot) {
      if (!_localBindings.containsKey(entry.localId)) {
        bindLocal(entry.localId, _freshNodeId());
      }
    }
    for (final local in suppressedLocalIds) {
      if (_localBindings[local] case final node?) suppress(node);
    }
    final produced = <FolderSyncEvent>[];
    final localNodes = <String, FolderSyncNode>{};
    for (final entry in snapshot) {
      if (entry.parentLocalId != null &&
          !_localBindings.containsKey(entry.parentLocalId)) {
        continue;
      }
      final nodeId = _localBindings[entry.localId]!;
      localNodes[nodeId] = FolderSyncNode(
        id: nodeId,
        parentId: entry.parentLocalId == null
            ? null
            : _localBindings[entry.parentLocalId],
        kind: entry.kind,
        name: entry.name,
        contentKey: entry.contentKey,
        size: entry.size,
        extension: entry.extension,
      );
    }
    if (canPublish) {
      final structurallySafe = _safeLocalNodes(localNodes);
      for (final node in localNodes.values) {
        if (!structurallySafe.contains(node.id) ||
            _suppressedInSnapshot(node.id, localNodes) ||
            explicitlyDeletedLocalIds.contains(_nodeBindings[node.id])) {
          continue;
        }
        final signature = node.signature();
        if (_appliedSignatures[node.id] == signature) {
          // Identical concurrent semantics need no filesystem operation.
          final versions = heads(node.id);
          if (versions.isNotEmpty &&
              versions.every((e) => e.semanticSignature == signature)) {
            _appliedClocks[node.id] = folderSyncMergeClocks(
              versions.map((e) => e.clock),
            );
          }
          continue;
        }
        final versions = heads(node.id);
        if (!_appliedSignatures.containsKey(node.id) &&
            versions.isNotEmpty &&
            versions.every((e) => e.semanticSignature == signature)) {
          markApplied(
            node.id,
            localId: _nodeBindings[node.id]!,
            appliedNode: node,
          );
          continue;
        }
        final event = _emit(
          node,
          deleted: false,
          base: _appliedClocks[node.id] ?? const {},
        );
        produced.add(event);
        _rememberLocal(event);
      }
    }
    final deletedIds = <String>{};
    for (final local in explicitlyDeletedLocalIds) {
      if (_localBindings[local] case final node?) deletedIds.add(node);
    }
    // Expand only the previously applied local tree. Never delete a remote
    // descendant which has not actually been seen/applied on this device.
    final children = <String, List<String>>{};
    for (final node in _appliedNodes.values) {
      if (node.parentId case final parent?) {
        children.putIfAbsent(parent, () => []).add(node.id);
      }
    }
    final pendingDeletes = deletedIds.toList();
    for (var index = 0; index < pendingDeletes.length; index++) {
      for (final child in children[pendingDeletes[index]] ?? const <String>[]) {
        if (deletedIds.add(child)) pendingDeletes.add(child);
      }
    }
    for (final id in deletedIds) {
      final node = _appliedNodes[id];
      if (node == null) continue;
      if (!settings.syncDeletes || !canPublish) {
        suppress(id);
        continue;
      }
      if (_appliedSignatures[id] == node.signature(deleted: true)) continue;
      final event = _emit(
        node,
        deleted: true,
        base: _appliedClocks[id] ?? const {},
      );
      produced.add(event);
      _rememberLocal(event);
    }
    return List.unmodifiable(produced);
  }

  void _rememberLocal(FolderSyncEvent event) {
    _appliedNodes[event.node.id] = event.node;
    _appliedSignatures[event.node.id] = event.semanticSignature;
    _appliedClocks[event.node.id] = Map.of(event.clock);
  }

  FolderSyncEvent _emit(
    FolderSyncNode node, {
    required bool deleted,
    required Map<String, int> base,
  }) {
    final clock = Map<String, int>.of(base);
    _sequence = max(_sequence, clock[deviceId] ?? 0) + 1;
    if (_sequence > folderSyncMaxCounter) {
      throw const FormatException('本机目录时钟已用尽');
    }
    clock[deviceId] = _sequence;
    final event = FolderSyncEvent(
      id: _freshEventId(),
      groupId: groupId,
      deviceId: deviceId,
      deviceName: deviceName,
      clock: clock,
      node: node,
      deleted: deleted,
      createdAtMs: _nowMs(),
    );
    if (!merge(event)) throw StateError('无法记录本机目录事件');
    return event;
  }

  bool merge(FolderSyncEvent event) {
    event.validate();
    if (event.groupId != groupId) throw const FormatException('目录事件属于其他文件夹');
    final old = _events[event.id];
    if (old != null) {
      // A reused event ID cannot replace its original authenticated meaning.
      if (jsonEncode(old.toJson()) != jsonEncode(event.toJson())) {
        throw const FormatException('目录事件标识被重复使用');
      }
      return false;
    }
    final known = _heads[event.node.id];
    if (known != null && known.values.any((head) => head.descendsFrom(event))) {
      // A pruned event can be replayed after restart. The current head's clock
      // is sufficient proof that its meaning is obsolete; no permanent ID log
      // is needed and receiving old history must not grow storage again.
      return false;
    }
    if (_events.length >= maxEvents) compact();
    if (_events.length >= maxEvents ||
        (!_heads.containsKey(event.node.id) && _heads.length >= maxNodes)) {
      throw const FormatException('目录同步记录数量过多');
    }
    final current = _heads.putIfAbsent(event.node.id, () => {});
    current.removeWhere((_, head) => event.descendsFrom(head));
    current[event.id] = event;
    _events[event.id] = event;
    _sequence = max(_sequence, event.clock[deviceId] ?? 0);
    _projection = null;
    _activeEvents = null;
    return true;
  }

  int mergeAll(Iterable<FolderSyncEvent> events) {
    var accepted = 0, count = 0;
    for (final event in events) {
      if (++count > maxEvents) throw const FormatException('目录事件批次过大');
      if (merge(event)) accepted++;
    }
    return accepted;
  }

  FolderSyncEvent resolve(String nodeId, String eventId) {
    final versions = heads(nodeId);
    final chosen = versions.where((e) => e.id == eventId).firstOrNull;
    if (chosen == null) throw StateError('待确认的目录版本已变化');
    return _emit(
      chosen.node,
      deleted: chosen.deleted,
      base: folderSyncMergeClocks(versions.map((e) => e.clock)),
    );
  }

  void acknowledgeRemote(
    String peerId,
    String nodeId, {
    Map<String, int>? clock,
    String? contentKey,
    String? metadataSignature,
  }) {
    folderSyncValidateId(peerId, 'peerId');
    folderSyncValidateId(nodeId, 'nodeId');
    final versions = heads(nodeId);
    final consensus =
        versions.isNotEmpty &&
        versions.map((e) => e.semanticSignature).toSet().length == 1;
    if (metadataSignature == null && !consensus) {
      throw StateError('请明确远端确认的目录版本');
    }
    final ack = FolderSyncAcknowledgement.fromJson(
      FolderSyncAcknowledgement(
        nodeId: nodeId,
        clock: clock ?? folderSyncMergeClocks(versions.map((e) => e.clock)),
        contentKey:
            contentKey ??
            (consensus && !versions.first.deleted
                ? versions.first.node.contentKey
                : null),
        metadataSignature:
            metadataSignature ?? versions.first.semanticSignature,
      ).toJson(),
    );
    _mergeAcknowledgement(peerId, ack);
  }

  void _mergeAcknowledgement(String peerId, FolderSyncAcknowledgement ack) {
    if (!_acknowledged.containsKey(peerId) && _acknowledged.length >= 128) {
      throw const FormatException('确认设备数量过多');
    }
    final peer = _acknowledged.putIfAbsent(peerId, () => {});
    if (!peer.containsKey(ack.nodeId) && peer.length >= maxNodes) {
      throw const FormatException('确认条目数量过多');
    }
    final versions = peer.putIfAbsent(ack.nodeId, () => []);
    if (versions.any(
      (e) =>
          folderSyncClockAfter(e.clock, ack.clock) ||
          jsonEncode(e.toJson()) == jsonEncode(ack.toJson()),
    )) {
      return;
    }
    final superseded = versions
        .where((e) => folderSyncClockAfter(ack.clock, e.clock))
        .length;
    if (versions.length - superseded >= 128 ||
        _acknowledgementCount - superseded >= maxEvents) {
      throw const FormatException('并发确认数量过多');
    }
    versions.removeWhere((e) => folderSyncClockAfter(ack.clock, e.clock));
    versions.add(ack);
    _acknowledgementCount += 1 - superseded;
  }

  FolderSyncAcknowledgement? remoteAcknowledgement(
    String peerId,
    String nodeId,
  ) {
    final versions = _acknowledged[peerId]?[nodeId] ?? const [];
    if (versions.isEmpty ||
        versions
                .map((a) => '${a.metadataSignature}|${a.contentKey}')
                .toSet()
                .length !=
            1) {
      return null;
    }
    return FolderSyncAcknowledgement(
      nodeId: nodeId,
      clock: folderSyncMergeClocks(versions.map((a) => a.clock)),
      metadataSignature: versions.first.metadataSignature,
      contentKey: versions.first.contentKey,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'groupId': groupId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'settings': settings.toJson(),
    'sequence': _sequence,
    'events': _events.values.map((e) => e.toJson()).toList(),
    'localBindings': Map.of(_localBindings),
    'appliedSignatures': Map.of(_appliedSignatures),
    'appliedClocks': {
      for (final e in _appliedClocks.entries) e.key: Map.of(e.value),
    },
    'appliedNodes': _appliedNodes.values.map((n) => n.toJson()).toList(),
    'suppressedNodeIds': _suppressed.toList(),
    'remoteAcknowledgements': [
      for (final peer in _acknowledged.entries)
        for (final versions in peer.value.values)
          for (final ack in versions) {'peerId': peer.key, 'ack': ack.toJson()},
    ],
  };
  factory FolderSyncState.fromJson(
    Map<String, dynamic> json, {
    required String deviceId,
    String? deviceName,
    String Function()? newId,
    int Function()? nowMs,
  }) {
    if (json['version'] != 1 ||
        json['groupId'] is! String ||
        json['deviceId'] != deviceId) {
      throw const FormatException('本机目录状态无效，请仅交换目录事件');
    }
    final state = FolderSyncState(
      groupId: json['groupId'] as String,
      deviceId: deviceId,
      deviceName: deviceName ?? json['deviceName'] as String?,
      settings: FolderSyncSettings.fromJson(
        Map<String, dynamic>.from(json['settings'] as Map? ?? {}),
      ),
      newId: newId,
      nowMs: nowMs,
    );
    List<dynamic> list(String key, int maximum) {
      final value = json[key] ?? const [];
      if (value is! List || value.length > maximum) {
        throw FormatException('$key 数量无效');
      }
      return value;
    }

    Map<String, dynamic> map(String key) {
      final value = json[key] ?? const {};
      if (value is! Map || value.length > maxNodes) {
        throw FormatException('$key 数量无效');
      }
      return Map<String, dynamic>.from(value);
    }

    for (final raw in list('events', maxEvents)) {
      state.merge(
        FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
      );
    }
    final sequence = json['sequence'] ?? 0;
    if (sequence is! int || sequence < 0 || sequence > folderSyncMaxCounter) {
      throw const FormatException('本机时钟无效');
    }
    state._sequence = max(state._sequence, sequence);
    for (final entry in map('localBindings').entries) {
      if (entry.value is! String) throw const FormatException('本地关联无效');
      state.bindLocal(entry.key, entry.value as String);
    }
    for (final raw in list('appliedNodes', maxNodes)) {
      final node = FolderSyncNode.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      if (state._appliedNodes.containsKey(node.id)) {
        throw const FormatException('本地应用条目标识重复');
      }
      state._appliedNodes[node.id] = node;
    }
    for (final entry in map('appliedSignatures').entries) {
      if (entry.value is! String ||
          (entry.value as String).length > 8192 ||
          !state._appliedNodes.containsKey(entry.key) ||
          (entry.value != state._appliedNodes[entry.key]!.signature() &&
              entry.value !=
                  state._appliedNodes[entry.key]!.signature(deleted: true))) {
        throw const FormatException('本地应用签名无效');
      }
      state._appliedSignatures[entry.key] = entry.value as String;
    }
    for (final entry in map('appliedClocks').entries) {
      if (entry.value is! Map || !state._appliedNodes.containsKey(entry.key)) {
        throw const FormatException('本地应用时钟无效');
      }
      final clock = Map<String, int>.from(entry.value as Map);
      folderSyncValidateClock(clock, allowEmpty: true);
      state._appliedClocks[entry.key] = clock;
    }
    for (final raw in list('suppressedNodeIds', maxNodes)) {
      if (raw is! String) throw const FormatException('本机排除无效');
      state.suppress(raw);
    }
    for (final raw in list('remoteAcknowledgements', maxEvents)) {
      final row = Map<String, dynamic>.from(raw as Map);
      folderSyncValidateId(row['peerId'], 'peerId');
      state._mergeAcknowledgement(
        row['peerId'] as String,
        FolderSyncAcknowledgement.fromJson(
          Map<String, dynamic>.from(row['ack'] as Map),
        ),
      );
    }
    return state;
  }

  Set<String> _safeLocalNodes(Map<String, FolderSyncNode> nodes) {
    final shadow = <String, FolderSyncNode>{..._appliedNodes, ...nodes};
    final good = <String>{}, bad = <String>{};
    final depths = <String, int>{};
    for (final id in nodes.keys) {
      final path = <String>[];
      final positions = <String>{};
      String? cursor = id;
      while (cursor != null &&
          !good.contains(cursor) &&
          !bad.contains(cursor)) {
        if (!positions.add(cursor)) {
          bad.addAll(path);
          break;
        }
        final node = shadow[cursor];
        if (node == null) {
          bad.addAll(path);
          break;
        }
        path.add(cursor);
        if (node.parentId != null &&
            shadow[node.parentId]?.kind != FolderSyncNodeKind.folder) {
          bad.addAll(path);
          break;
        }
        cursor = node.parentId;
      }
      if (cursor != null && bad.contains(cursor)) bad.addAll(path);
      for (final child in path.reversed) {
        if (bad.contains(child)) continue;
        final node = shadow[child]!;
        final parent = node.parentId;
        if (parent == null) {
          if (node.kind == FolderSyncNodeKind.folder) {
            good.add(child);
            depths[child] = 0;
          } else {
            bad.add(child);
          }
        } else if (!good.contains(parent) || depths[parent]! >= maxDepth) {
          bad.add(child);
        } else {
          good.add(child);
          depths[child] = depths[parent]! + 1;
        }
      }
    }
    return good;
  }

  bool _suppressedInSnapshot(String nodeId, Map<String, FolderSyncNode> nodes) {
    if (_suppressed.isEmpty) return false;
    final visited = <String>{};
    String? cursor = nodeId;
    while (cursor != null && visited.add(cursor)) {
      if (_suppressed.contains(cursor)) return true;
      final node =
          nodes[cursor] ??
          _appliedNodes[cursor] ??
          _heads[cursor]?.values.firstOrNull?.node;
      cursor = node?.parentId;
    }
    return false;
  }

  _Projection _project() {
    final live = <String, FolderSyncNode>{},
        deleted = <String, FolderSyncNode>{};
    final problems = <String, String>{};
    final issues = <FolderSyncIssue>[];
    for (final id in _heads.keys) {
      final versions = heads(id);
      // Older versions published each device's root alias as a rename. Treat
      // name-only root differences as the same node so those saved branches
      // no longer block the whole tree. Other root conflicts remain explicit.
      final rootAliases = versions.every(
        (event) =>
            event.node.kind == FolderSyncNodeKind.folder &&
            event.node.parentId == null,
      );
      final signatures = versions.map(
        (event) => rootAliases
            ? event.node
                  .copyWith(name: versions.first.node.name)
                  .signature(deleted: event.deleted)
            : event.semanticSignature,
      );
      if (signatures.toSet().length > 1) {
        var reason = 'concurrentEdit';
        if (versions.map((e) => e.deleted).toSet().length > 1) {
          reason = 'concurrentDelete';
        } else if (versions
                .map(
                  (e) => '${e.node.kind}|${e.node.contentKey}|${e.node.size}',
                )
                .toSet()
                .length >
            1) {
          reason = 'concurrentContent';
        } else if (versions.map((e) => e.node.parentId).toSet().length > 1) {
          reason = 'concurrentMove';
        } else if (versions.map((e) => e.node.name).toSet().length > 1) {
          reason = 'concurrentRename';
        }
        issues.add(
          FolderSyncIssue(
            groupId: groupId,
            nodeId: id,
            title: versions.first.node.name,
            reason: reason,
            choices: versions,
          ),
        );
        continue;
      }
      (versions.first.deleted ? deleted : live)[id] = versions.first.node;
    }
    final all = {...live, ...deleted};
    final cycle = <String>{}, visited = <String>{};
    for (final id in all.keys) {
      final path = <String>[], indexes = <String, int>{};
      String? cursor = id;
      while (cursor != null &&
          all.containsKey(cursor) &&
          !visited.contains(cursor)) {
        if (indexes[cursor] case final start?) {
          cycle.addAll(path.skip(start));
          break;
        }
        indexes[cursor] = path.length;
        path.add(cursor);
        cursor = all[cursor]!.parentId;
      }
      visited.addAll(path);
    }
    for (final id in cycle) {
      problems[id] = 'cycle';
    }
    final roots = live.values
        .where((n) => n.parentId == null && n.kind == FolderSyncNodeKind.folder)
        .toList();
    final root = roots.length == 1 ? roots.single.id : null;
    final good = <String>{}, depths = <String, int>{};
    for (final id in live.keys) {
      if (good.contains(id) || problems.containsKey(id)) continue;
      final path = <String>[];
      var cursor = id;
      while (!good.contains(cursor) && !problems.containsKey(cursor)) {
        final node = live[cursor]!;
        if (node.parentId == null) {
          if (node.kind != FolderSyncNodeKind.folder) {
            problems[cursor] = 'rootNotFolder';
          } else if (cursor != root) {
            problems[cursor] = 'multipleRoots';
          } else {
            good.add(cursor);
            depths[cursor] = 0;
          }
          break;
        }
        final parent = node.parentId!;
        if (!live.containsKey(parent)) {
          problems[cursor] = deleted.containsKey(parent)
              ? 'deletedParent'
              : _heads.containsKey(parent)
              ? 'parentConflict'
              : 'missingParent';
          break;
        }
        if (live[parent]!.kind != FolderSyncNodeKind.folder) {
          problems[cursor] = 'parentNotFolder';
          break;
        }
        path.add(cursor);
        cursor = parent;
      }
      for (final child in path.reversed) {
        final parent = live[child]!.parentId!;
        if (!good.contains(parent)) {
          problems[child] = 'blockedParent';
        } else if (depths[parent]! >= maxDepth) {
          problems[child] = 'depthLimit';
        } else {
          good.add(child);
          depths[child] = depths[parent]! + 1;
        }
      }
    }
    // Deleted nodes also require a structurally safe ancestry. Receiving an
    // orphan or a non-folder parent must never authorize local removal.
    final allRoots = all.values
        .where((n) => n.parentId == null && n.kind == FolderSyncNodeKind.folder)
        .toList();
    final ancestryGood = {...good}, ancestryDepths = {...depths};
    for (final id in deleted.keys) {
      if (problems.containsKey(id)) continue;
      final path = <String>[];
      var cursor = id;
      while (!ancestryGood.contains(cursor) && !problems.containsKey(cursor)) {
        final node = all[cursor]!;
        final parent = node.parentId;
        if (parent == null) {
          if (node.kind != FolderSyncNodeKind.folder) {
            problems[cursor] = 'rootNotFolder';
          } else if (allRoots.length != 1 || allRoots.single.id != cursor) {
            problems[cursor] = 'multipleRoots';
          } else {
            ancestryGood.add(cursor);
            ancestryDepths[cursor] = 0;
          }
          break;
        }
        if (!all.containsKey(parent)) {
          problems[cursor] = _heads.containsKey(parent)
              ? 'parentConflict'
              : 'missingParent';
          break;
        }
        if (all[parent]!.kind != FolderSyncNodeKind.folder) {
          problems[cursor] = 'parentNotFolder';
          break;
        }
        path.add(cursor);
        cursor = parent;
      }
      for (final child in path.reversed) {
        final parent = all[child]!.parentId!;
        if (!ancestryGood.contains(parent)) {
          problems[child] = 'blockedParent';
        } else if (ancestryDepths[parent]! >= maxDepth) {
          problems[child] = 'depthLimit';
        } else {
          ancestryGood.add(child);
          ancestryDepths[child] = ancestryDepths[parent]! + 1;
        }
      }
    }
    // A directory tombstone must never swallow a still-live child, including a
    // concurrent child that was not applied on the deleting device.
    final pending = <String>[
      for (final entry in _heads.entries)
        if (entry.value.values.any((e) => !e.deleted)) entry.key,
    ];
    final reached = <String>{}, blockedDeletes = <String>{};
    for (var i = 0; i < pending.length; i++) {
      final id = pending[i];
      if (!reached.add(id)) continue;
      if (deleted.containsKey(id)) blockedDeletes.add(id);
      for (final event in _heads[id]?.values ?? const <FolderSyncEvent>[]) {
        if (event.node.parentId case final parent?) pending.add(parent);
      }
    }
    for (final id in blockedDeletes) {
      problems[id] = 'deleteHasLiveDescendants';
    }
    for (final entry in problems.entries) {
      final versions = heads(entry.key);
      if (versions.isEmpty) continue;
      issues.add(
        FolderSyncIssue(
          groupId: groupId,
          nodeId: entry.key,
          title: versions.first.node.name,
          reason: entry.value,
          choices: versions,
        ),
      );
    }
    issues.sort((a, b) => a.nodeId.compareTo(b.nodeId));
    return _Projection(
      Map.unmodifiable({for (final id in good) id: live[id]!}),
      root != null && good.contains(root) ? root : null,
      Set.unmodifiable(deleted.keys.where((id) => !problems.containsKey(id))),
      List.unmodifiable(issues),
    );
  }

  String _freshNodeId() {
    for (var i = 0; i < 32; i++) {
      final id = _newId();
      folderSyncValidateId(id, 'nodeId');
      if (!_heads.containsKey(id) && !_nodeBindings.containsKey(id)) return id;
    }
    throw StateError('无法生成唯一目录身份');
  }

  String _freshEventId() {
    for (var i = 0; i < 32; i++) {
      final id = _newId();
      folderSyncValidateId(id, 'eventId');
      if (!_events.containsKey(id)) return id;
    }
    throw StateError('无法生成唯一目录事件');
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static void _validateLocalId(String value) {
    if (value.isEmpty ||
        value.length > 512 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('本地条目标识无效');
    }
  }
}

class _Projection {
  const _Projection(this.nodes, this.rootId, this.deleted, this.issues);
  final Map<String, FolderSyncNode> nodes;
  final String? rootId;
  final Set<String> deleted;
  final List<FolderSyncIssue> issues;
}
