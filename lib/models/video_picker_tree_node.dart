import 'video_item.dart';

class VideoPickerTreeNode {
  final String nodeId;
  final String name;
  final bool isFolder;
  final String? parentId;
  final List<VideoPickerTreeNode> children;
  bool isSelected;
  bool isIndeterminate;
  bool isAlreadyInQueue;
  final String? videoId;
  final String? videoPath;
  String? videoDuration;
  final VideoItem? mediaItem;
  bool childrenLoaded;

  VideoPickerTreeNode({
    required this.nodeId,
    required this.name,
    required this.isFolder,
    this.parentId,
    List<VideoPickerTreeNode>? children,
    this.isSelected = false,
    this.isIndeterminate = false,
    this.isAlreadyInQueue = false,
    this.videoId,
    this.videoPath,
    this.videoDuration,
    this.mediaItem,
    this.childrenLoaded = true,
  }) : children = children ?? [];

  VideoPickerTreeNode copyWith({
    String? nodeId,
    String? name,
    bool? isFolder,
    String? parentId,
    List<VideoPickerTreeNode>? children,
    bool? isSelected,
    bool? isIndeterminate,
    bool? isAlreadyInQueue,
    String? videoId,
    String? videoPath,
    String? videoDuration,
    VideoItem? mediaItem,
    bool? childrenLoaded,
  }) {
    return VideoPickerTreeNode(
      nodeId: nodeId ?? this.nodeId,
      name: name ?? this.name,
      isFolder: isFolder ?? this.isFolder,
      parentId: parentId ?? this.parentId,
      children: children ?? this.children,
      isSelected: isSelected ?? this.isSelected,
      isIndeterminate: isIndeterminate ?? this.isIndeterminate,
      isAlreadyInQueue: isAlreadyInQueue ?? this.isAlreadyInQueue,
      videoId: videoId ?? this.videoId,
      videoPath: videoPath ?? this.videoPath,
      videoDuration: videoDuration ?? this.videoDuration,
      mediaItem: mediaItem ?? this.mediaItem,
      childrenLoaded: childrenLoaded ?? this.childrenLoaded,
    );
  }
}

class VideoPickerTree {
  List<VideoPickerTreeNode> roots;
  int selectedCount;
  int totalCount;

  VideoPickerTree({
    List<VideoPickerTreeNode>? roots,
    this.selectedCount = 0,
    this.totalCount = 0,
  }) : roots = roots ?? [];

  void updateSelection(VideoPickerTreeNode node, bool selected) {
    _setSelection(node, selected);
    recalculateCounts();
  }

  void selectAll(bool selected) {
    for (final root in roots) {
      _setSelection(root, selected);
    }
    recalculateCounts();
  }

  void _setSelection(VideoPickerTreeNode node, bool selected) {
    if (node.isFolder) {
      for (final child in node.children) {
        _setSelection(child, selected);
      }
    } else {
      node.isSelected = selected && !node.isAlreadyInQueue;
      node.isIndeterminate = false;
    }
  }

  void recalculateCounts() {
    int selected = 0;
    int total = 0;
    for (final root in roots) {
      final counts = _countNodes(root);
      selected += counts.$1;
      total += counts.$2;
    }
    selectedCount = selected;
    totalCount = total;
  }

  (int, int, int, bool) _countNodes(VideoPickerTreeNode node) {
    if (!node.isFolder) {
      if (node.isAlreadyInQueue) node.isSelected = false;
      return (node.isSelected ? 1 : 0, 1, node.isAlreadyInQueue ? 0 : 1, true);
    }
    int sel = 0;
    int tot = 0;
    int selectable = 0;
    bool loaded = node.childrenLoaded;
    for (final child in node.children) {
      final counts = _countNodes(child);
      sel += counts.$1;
      tot += counts.$2;
      selectable += counts.$3;
      loaded = loaded && counts.$4;
    }
    node.isSelected = loaded && selectable > 0 && sel == selectable;
    node.isIndeterminate = sel > 0 && !node.isSelected;
    return (sel, tot, selectable, loaded);
  }

  List<VideoPickerTreeNode> getSelectedLeaves() {
    final result = <VideoPickerTreeNode>[];
    for (final root in roots) {
      _collectSelectedLeaves(root, result);
    }
    return result;
  }

  void _collectSelectedLeaves(
    VideoPickerTreeNode node,
    List<VideoPickerTreeNode> result,
  ) {
    if (!node.isFolder && node.isSelected && !node.isAlreadyInQueue) {
      result.add(node);
    }
    for (final child in node.children) {
      _collectSelectedLeaves(child, result);
    }
  }
}
