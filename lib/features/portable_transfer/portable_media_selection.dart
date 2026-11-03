import '../../models/media_source_ref.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../services/library_service.dart';

/// Folder/file checkbox shown in the export picker.
enum PortableCheckState { unchecked, partial, checked }

/// Lightweight library tree used by the export picker.
///
/// Only active (non-recycled) nodes reachable from the library root are
/// indexed, matching what [LibraryService.getContents] would show.
class PortableTreeIndex {
  PortableTreeIndex({required this.nodes, required this.rootIds});

  final Map<String, PortableTreeNode> nodes;
  final List<String> rootIds;

  factory PortableTreeIndex.fromLibrary(LibraryService library) {
    final nodes = <String, PortableTreeNode>{};
    String itemId(dynamic item) =>
        item is VideoCollection ? item.id : (item as VideoItem).id;

    void visit(String? parentId) {
      for (final item in library.getContents(parentId)) {
        final id = itemId(item);
        if (item is VideoCollection) {
          visit(id);
          nodes[id] = PortableTreeNode(
            id: id,
            name: item.name,
            isFolder: true,
            parentId: parentId,
            childIds: library
                .getContents(id)
                .map(itemId)
                .toList(growable: false),
            thumbnailPath: item.thumbnailPath,
          );
        } else {
          final video = item as VideoItem;
          nodes[id] = PortableTreeNode(
            id: id,
            name: video.title,
            isFolder: false,
            parentId: parentId,
            childIds: const <String>[],
            thumbnailPath: video.thumbnailPath,
            isOnline:
                video.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
                video.path.startsWith('bilibili://stream/'),
            fileName: video.path,
            mediaTypeAudio: video.type == MediaType.audio,
          );
        }
      }
    }

    visit(null);
    final rootIds = library
        .getContents(null)
        .map(itemId)
        .toList(growable: false);
    // Rebuild root nodes that visit() stored via folder recursion; root files
    // are already in [nodes]. Folders at root were written during visit.
    return PortableTreeIndex(nodes: nodes, rootIds: rootIds);
  }

  PortableTreeNode? node(String id) => nodes[id];

  Iterable<PortableTreeNode> childrenOf(String? parentId) {
    final ids = parentId == null
        ? rootIds
        : (nodes[parentId]?.childIds ?? const <String>[]);
    return ids.map((id) => nodes[id]).whereType<PortableTreeNode>();
  }

  /// Ancestor folder names from library root down to [parentId], exclusive of
  /// the item itself. Used as search-result breadcrumbs.
  List<String> breadcrumb(String? parentId) {
    final names = <String>[];
    final visited = <String>{};
    var current = parentId;
    while (current != null && visited.add(current)) {
      final folder = nodes[current];
      if (folder == null) break;
      names.add(folder.name);
      current = folder.parentId;
    }
    return names.reversed.toList(growable: false);
  }

  bool isDescendantOf(String id, String ancestorId) {
    if (id == ancestorId) return false;
    final visited = <String>{};
    var current = nodes[id]?.parentId;
    while (current != null && visited.add(current)) {
      if (current == ancestorId) return true;
      current = nodes[current]?.parentId;
    }
    return false;
  }

  /// Deepest node that contains every id. A single id is its own LCA.
  /// Returns null when the ids only share the library root, or [ids] is empty.
  String? lowestCommonAncestor(Iterable<String> ids) {
    final unique = <String>[];
    final seen = <String>{};
    for (final id in ids) {
      if (nodes.containsKey(id) && seen.add(id)) unique.add(id);
    }
    if (unique.isEmpty) return null;
    if (unique.length == 1) return unique.single;

    List<String?> ancestorChain(String id) {
      final chain = <String?>[id];
      final visited = <String>{id};
      var current = nodes[id]?.parentId;
      while (current != null && visited.add(current)) {
        chain.add(current);
        current = nodes[current]?.parentId;
      }
      chain.add(null);
      return chain;
    }

    final first = ancestorChain(unique.first);
    final rest = unique
        .skip(1)
        .map((id) => ancestorChain(id).toSet())
        .toList(growable: false);
    for (final node in first) {
      if (rest.every((chain) => chain.contains(node))) return node;
    }
    return null;
  }

  /// Path [ancestorId, ..., descendantId]. Empty if [descendantId] is not under
  /// [ancestorId].
  List<String> pathFrom(String ancestorId, String descendantId) {
    if (ancestorId == descendantId) return <String>[ancestorId];
    final upward = <String>[descendantId];
    final visited = <String>{descendantId};
    var current = nodes[descendantId]?.parentId;
    while (current != null && visited.add(current)) {
      upward.add(current);
      if (current == ancestorId) {
        return upward.reversed.toList(growable: false);
      }
      current = nodes[current]?.parentId;
    }
    return const <String>[];
  }

  int descendantMediaCount(String folderId) {
    var count = 0;
    final stack = <String>[folderId];
    final visited = <String>{};
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!visited.add(id)) continue;
      final current = nodes[id];
      if (current == null) continue;
      if (!current.isFolder) {
        if (id != folderId) count++;
        continue;
      }
      stack.addAll(current.childIds);
    }
    // The walk starts at the folder; files are counted when visited as children.
    // Root-as-file never happens for folderId.
    return count;
  }
}

class PortableTreeNode {
  const PortableTreeNode({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.parentId,
    required this.childIds,
    this.thumbnailPath,
    this.isOnline = false,
    this.fileName,
    this.mediaTypeAudio = false,
  });

  final String id;
  final String name;
  final bool isFolder;
  final String? parentId;
  final List<String> childIds;
  final String? thumbnailPath;
  final bool isOnline;
  final String? fileName;
  final bool mediaTypeAudio;
}

/// Selection stored as "selection roots": a checked folder implies every
/// descendant, so children are not also stored. Unchecking one file inside a
/// fully checked folder explodes the parent into sibling roots.
class PortableMediaSelection {
  PortableMediaSelection([Iterable<String>? roots])
    : _roots = <String>{...?roots};

  final Set<String> _roots;

  Set<String> get selectedRoots => Set<String>.unmodifiable(_roots);

  bool get isEmpty => _roots.isEmpty;

  void clear() => _roots.clear();

  PortableCheckState checkState(PortableTreeIndex tree, String id) {
    if (_isFullySelected(tree, id)) return PortableCheckState.checked;
    final node = tree.node(id);
    if (node != null &&
        node.isFolder &&
        _roots.any((root) => root == id || tree.isDescendantOf(root, id))) {
      return PortableCheckState.partial;
    }
    return PortableCheckState.unchecked;
  }

  bool isFullySelected(PortableTreeIndex tree, String id) =>
      _isFullySelected(tree, id);

  /// Counts media cards that will actually be packed, optionally limited to
  /// one folder's descendants.
  int selectedMediaCount(PortableTreeIndex tree, {String? underFolderId}) {
    var count = 0;
    void walk(String id) {
      final node = tree.node(id);
      if (node == null) return;
      if (!node.isFolder) {
        if (_isFullySelected(tree, id)) count++;
        return;
      }
      for (final childId in node.childIds) {
        walk(childId);
      }
    }

    if (underFolderId != null) {
      final folder = tree.node(underFolderId);
      if (folder == null) return 0;
      for (final childId in folder.childIds) {
        walk(childId);
      }
      return count;
    }
    for (final id in tree.rootIds) {
      walk(id);
    }
    return count;
  }

  void setChecked(PortableTreeIndex tree, String id, bool checked) {
    if (tree.node(id) == null) return;
    if (checked) {
      _select(tree, id);
    } else {
      _unselect(tree, id);
    }
  }

  void setAll(PortableTreeIndex tree, Iterable<String> ids, bool checked) {
    for (final id in List<String>.from(ids)) {
      setChecked(tree, id, checked);
    }
  }

  /// Videos and folders that the portable package must actually contain.
  ///
  /// Folder wrapping is trimmed to the lowest common ancestor of the selection
  /// roots: a lone nested folder is exported as the package top, while picks at
  /// different depths still keep the folders needed to preserve their relative
  /// path. Unselected siblings and unused outer shells are omitted.
  PortableExportInclusion resolve(PortableTreeIndex tree) {
    final collectionIds = <String>{};
    final videoIds = <String>{};
    final seenAncestors = <String>{};
    final lca = tree.lowestCommonAncestor(_roots);

    /// Keep folders from [parentId] up through [lca], but never above it.
    /// A single nested file/folder is its own LCA, so this adds nothing.
    void addAncestorsTowardLca(String? parentId) {
      var current = parentId;
      while (current != null && seenAncestors.add(current)) {
        final folder = tree.node(current);
        if (folder == null || !folder.isFolder) break;
        // current sits strictly above the LCA, so it would be an empty shell.
        if (lca != null && current != lca && tree.isDescendantOf(lca, current)) {
          break;
        }
        collectionIds.add(current);
        if (current == lca) break;
        current = folder.parentId;
      }
    }

    void addCollectionTree(String id) {
      final collection = tree.node(id);
      if (collection == null || !collection.isFolder) return;
      collectionIds.add(id);
      addAncestorsTowardLca(collection.parentId);
      for (final childId in collection.childIds) {
        final child = tree.node(childId);
        if (child == null) continue;
        if (child.isFolder) {
          addCollectionTree(child.id);
        } else {
          videoIds.add(child.id);
          addAncestorsTowardLca(child.parentId);
        }
      }
    }

    for (final id in _roots) {
      final node = tree.node(id);
      if (node == null) continue;
      if (node.isFolder) {
        addCollectionTree(id);
        continue;
      }
      videoIds.add(node.id);
      addAncestorsTowardLca(node.parentId);
    }

    return PortableExportInclusion(
      collectionIds: collectionIds,
      videoIds: videoIds,
    );
  }

  PortableExportInclusion resolveAgainstLibrary(LibraryService library) {
    return resolve(PortableTreeIndex.fromLibrary(library));
  }

  bool _isFullySelected(PortableTreeIndex tree, String id) {
    if (_roots.contains(id)) return true;
    return _coveringAncestor(tree, id) != null;
  }

  String? _coveringAncestor(PortableTreeIndex tree, String id) {
    final visited = <String>{};
    var current = tree.node(id)?.parentId;
    while (current != null && visited.add(current)) {
      if (_roots.contains(current)) return current;
      current = tree.node(current)?.parentId;
    }
    return null;
  }

  void _select(PortableTreeIndex tree, String id) {
    if (_isFullySelected(tree, id)) return;
    _roots.removeWhere((root) => root == id || tree.isDescendantOf(root, id));
    _roots.add(id);
    _compact(tree, id);
  }

  void _unselect(PortableTreeIndex tree, String id) {
    final covering = _coveringAncestor(tree, id);
    if (covering != null) {
      _explode(tree, covering, exceptId: id);
    }
    _roots.remove(id);
    _roots.removeWhere((root) => tree.isDescendantOf(root, id));
  }

  /// Replace a fully selected ancestor with every sibling along the path to
  /// [exceptId], leaving [exceptId] (and its descendants) unselected.
  void _explode(
    PortableTreeIndex tree,
    String coveringId, {
    required String exceptId,
  }) {
    final path = tree.pathFrom(coveringId, exceptId);
    if (path.length < 2) {
      _roots.remove(coveringId);
      return;
    }
    _roots.remove(coveringId);
    for (var index = 0; index < path.length - 1; index++) {
      final parent = tree.node(path[index]);
      if (parent == null) continue;
      final towardsExcept = path[index + 1];
      for (final siblingId in parent.childIds) {
        if (siblingId != towardsExcept) {
          _roots.add(siblingId);
        }
      }
    }
  }

  void _compact(PortableTreeIndex tree, String id) {
    var currentId = id;
    final guard = <String>{};
    while (guard.add(currentId)) {
      final parentId = tree.node(currentId)?.parentId;
      if (parentId == null) return;
      final parent = tree.node(parentId);
      if (parent == null || parent.childIds.isEmpty) return;
      final allChildrenSelected = parent.childIds.every(
        (childId) => _isFullySelected(tree, childId),
      );
      if (!allChildrenSelected) return;
      _roots.removeWhere(
        (root) => root == parentId || tree.isDescendantOf(root, parentId),
      );
      _roots.add(parentId);
      currentId = parentId;
    }
  }
}

class PortableExportInclusion {
  const PortableExportInclusion({
    required this.collectionIds,
    required this.videoIds,
  });

  final Set<String> collectionIds;
  final Set<String> videoIds;

  int get mediaCount => videoIds.length;
  int get folderCount => collectionIds.length;
  bool get isEmpty => collectionIds.isEmpty && videoIds.isEmpty;
}
