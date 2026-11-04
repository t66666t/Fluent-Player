import 'package:uuid/uuid.dart';

import 'podcast_models.dart';
import 'podcast_store.dart';

class PodcastSubscriptionFolder {
  const PodcastSubscriptionFolder({
    required this.id,
    required this.name,
    this.parentId,
  });

  final String id;
  final String name;
  final String? parentId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };
}

/// Local organization of subscriptions. Library-card placement and episode /
/// playback order belong to their existing owners and are never changed here.
class PodcastSubscriptionLayout {
  PodcastSubscriptionLayout(this.store) {
    final raw = store.read('viewState', 'podcast-overview') ?? {};
    for (final item in raw['folders'] as List? ?? const []) {
      if (item is! Map || item['id'] is! String || item['name'] is! String) {
        continue;
      }
      final id = item['id'] as String;
      if (!id.startsWith('podcast-folder:')) continue;
      _folders[id] = PodcastSubscriptionFolder(
        id: id,
        name: item['name'] as String,
        parentId: item['parentId'] as String?,
      );
    }
    // Recover orphaned or cyclic folders at the root, without hiding channels.
    for (final folder in _folders.values.toList()) {
      if (!_validParent(folder.id, folder.parentId)) {
        _folders[folder.id] = PodcastSubscriptionFolder(
          id: folder.id,
          name: folder.name,
        );
      }
    }
    final parents = raw['channelFolders'];
    if (parents is Map) {
      for (final entry in parents.entries) {
        if (entry.key is String &&
            entry.value is String &&
            _folders.containsKey(entry.value)) {
          _channelParents[entry.key as String] = entry.value as String;
        }
      }
    }
    final orders = raw['folderOrders'];
    if (orders is Map) {
      for (final entry in orders.entries) {
        if (entry.key is String && entry.value is List) {
          _orders[entry.key as String] = (entry.value as List)
              .whereType<String>()
              .toSet()
              .toList();
        }
      }
    }
    _orders.putIfAbsent('', store.overviewOrder);
  }

  final PodcastStore store;
  final _folders = <String, PodcastSubscriptionFolder>{};
  final _channelParents = <String, String>{};
  final _orders = <String, List<String>>{};

  List<PodcastSubscriptionFolder> get folders => _folders.values.toList();
  PodcastSubscriptionFolder? folder(String id) => _folders[id];
  String? parentOf(String id) => _folders[id]?.parentId ?? _channelParents[id];

  List<PodcastSubscriptionFolder> ancestors(String? id) {
    final result = <PodcastSubscriptionFolder>[];
    final visited = <String>{};
    while (id != null && visited.add(id)) {
      final current = _folders[id];
      if (current == null) break;
      result.insert(0, current);
      id = current.parentId;
    }
    return result;
  }

  List<String> entries(String? parentId, List<PodcastChannel> channels) {
    final available = <String>[
      for (final folder in _folders.values)
        if (folder.parentId == parentId) folder.id,
      for (final channel in channels)
        if (channel.active && _channelParents[channel.id] == parentId)
          channel.id,
    ];
    final rank = <String, int>{
      for (final (index, id) in (_orders[parentId ?? ''] ?? <String>[]).indexed)
        id: index,
    };
    final byId = {for (final channel in channels) channel.id: channel};
    final fallback = {for (final (index, id) in available.indexed) id: index};
    available.sort((a, b) {
      final order = (rank[a] ?? 1 << 30).compareTo(rank[b] ?? 1 << 30);
      if (order != 0) return order;
      // Keep the existing newest-subscription-first default for unplaced cards.
      if (byId.containsKey(a) && byId.containsKey(b)) {
        final date = byId[b]!.subscribedMs.compareTo(byId[a]!.subscribedMs);
        if (date != 0) return date;
      }
      return fallback[a]!.compareTo(fallback[b]!);
    });
    return available;
  }

  bool _validParent(String id, String? parentId) {
    final visited = <String>{id};
    while (parentId != null) {
      if (!visited.add(parentId)) return false;
      final parent = _folders[parentId];
      if (parent == null) return false;
      parentId = parent.parentId;
    }
    return true;
  }

  bool canMove(Iterable<String> ids, String? targetId) {
    final values = ids.toSet();
    if (values.isEmpty ||
        (targetId != null && !_folders.containsKey(targetId))) {
      return false;
    }
    final channels = store.channels.map((channel) => channel.id).toSet();
    return values.every(
      (id) =>
          (_folders.containsKey(id) || channels.contains(id)) &&
          _validParent(id, targetId),
    );
  }

  String createFolder(String name, {String? parentId}) {
    if (name.trim().isEmpty ||
        (parentId != null && !_folders.containsKey(parentId))) {
      throw ArgumentError('文件夹名称或位置无效');
    }
    final channels = store.channels;
    final order = entries(parentId, channels);
    final id = 'podcast-folder:${const Uuid().v4()}';
    _folders[id] = PodcastSubscriptionFolder(
      id: id,
      name: name.trim(),
      parentId: parentId,
    );
    _orders[parentId ?? ''] = [...order, id];
    _save();
    return id;
  }

  void renameFolder(String id, String name) {
    final current = _folders[id];
    if (current == null || name.trim().isEmpty) return;
    _folders[id] = PodcastSubscriptionFolder(
      id: id,
      name: name.trim(),
      parentId: current.parentId,
    );
    _save();
  }

  bool move(Iterable<String> ids, String? targetId) {
    final values = ids.toSet();
    if (!canMove(values, targetId)) return false;
    // If a caller selects both a folder and its descendant, move the folder
    // once and retain its subtree rather than flattening it accidentally.
    values.removeWhere(
      (id) =>
          ancestors(parentOf(id)).any((parent) => values.contains(parent.id)),
    );
    final moving = values.where((id) => parentOf(id) != targetId).toList();
    if (moving.isEmpty) return false;
    final order = entries(targetId, store.channels);
    for (final id in moving) {
      final current = _folders[id];
      if (current != null) {
        _folders[id] = PodcastSubscriptionFolder(
          id: id,
          name: current.name,
          parentId: targetId,
        );
      } else if (targetId == null) {
        _channelParents.remove(id);
      } else {
        _channelParents[id] = targetId;
      }
      for (final saved in _orders.values) {
        saved.remove(id);
      }
    }
    _orders[targetId ?? ''] = [...order, ...moving];
    _save();
    return true;
  }

  bool reorder(
    String? parentId,
    List<String> movingIds, {
    required String draggedId,
    required String targetId,
  }) {
    final visible = entries(parentId, store.channels);
    final moving = visible.where(movingIds.contains).toList();
    final oldIndex = visible.indexOf(draggedId);
    final targetIndex = visible.indexOf(targetId);
    if (moving.isEmpty ||
        oldIndex < 0 ||
        targetIndex < 0 ||
        moving.contains(targetId)) {
      return false;
    }
    final remaining = visible.where((id) => !moving.contains(id)).toList();
    final insert =
        remaining.indexOf(targetId) + (oldIndex < targetIndex ? 1 : 0);
    remaining.insertAll(insert, moving);
    _orders[parentId ?? ''] = remaining;
    _save();
    return true;
  }

  /// Dissolving a folder preserves subscriptions, nested folders and downloads.
  /// Its children take its position at the parent level.
  void dissolveFolders(Iterable<String> ids) {
    final channels = store.channels;
    final deleting = ids.toSet().where(_folders.containsKey).toList()
      ..sort((a, b) => ancestors(b).length.compareTo(ancestors(a).length));
    for (final id in deleting) {
      final current = _folders[id]!;
      final order = entries(current.parentId, channels);
      final children = entries(id, channels);
      final position = order.indexOf(id);
      order.remove(id);
      order.insertAll(position < 0 ? order.length : position, children);
      for (final child in _folders.values.toList()) {
        if (child.parentId == id) {
          _folders[child.id] = PodcastSubscriptionFolder(
            id: child.id,
            name: child.name,
            parentId: current.parentId,
          );
        }
      }
      // Include inactive subscriptions, so resubscribing cannot resurrect a
      // membership in a folder that no longer exists.
      for (final entry in _channelParents.entries.toList()) {
        if (entry.value != id) continue;
        if (current.parentId == null) {
          _channelParents.remove(entry.key);
        } else {
          _channelParents[entry.key] = current.parentId!;
        }
      }
      _folders.remove(id);
      _orders.remove(id);
      _orders[current.parentId ?? ''] = order;
    }
    if (deleting.isNotEmpty) _save();
  }

  void _save() {
    store.write('viewState', 'podcast-overview', {
      ...?store.read('viewState', 'podcast-overview'),
      'folders': _folders.values.map((folder) => folder.toJson()).toList(),
      'channelFolders': _channelParents,
      'folderOrders': _orders,
      'updatedClock': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
