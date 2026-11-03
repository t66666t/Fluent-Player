/// Shared expand defaults for 继续学习 / 最近添加 grouping chrome.
///
/// Folding is a density tool: the next action (resume / latest small import)
/// stays visible. User toggles are stored separately in
/// [MediaLibraryGroupExpandMemory] so a rebuild cannot reopen a closed group.
class MediaLibraryGroupExpandPolicy {
  const MediaLibraryGroupExpandPolicy._();

  /// Two or three siblings are cheaper as a flat list than an extra tap.
  static const int alwaysExpandedMaxItems = 3;

  /// About one card grid on a phone; the newest import batch opens itself.
  static const int recentLatestAutoExpandMaxItems = 16;

  /// YouTube-style history: yesterday stays open when it still fits a glance.
  static const int yesterdayAutoExpandMaxItems = 12;

  /// Opening a huge group may collapse other huge groups to keep the tree light.
  static const int hugeExclusiveMinItems = 50;

  static const int coverPreviewMax = 4;

  static bool alwaysExpanded(int count) =>
      count > 0 && count <= alwaysExpandedMaxItems;

  static bool isHuge(int count) => count >= hugeExclusiveMinItems;

  /// Newest multi-item batch auto-opens when small. Older batches and
  /// 「更早添加」 stay shut unless they are tiny. Singles never use this.
  static bool recentDefaultExpanded({
    required bool isNewestMultiItemBatch,
    required int count,
    required bool isUnknownBucket,
  }) {
    if (alwaysExpanded(count)) return true;
    if (isUnknownBucket) return false;
    if (isNewestMultiItemBatch) {
      return count <= recentLatestAutoExpandMaxItems;
    }
    return false;
  }

  /// Today is open. Yesterday is open when short. Unknown 「更早」 stays shut
  /// unless tiny. [dayStartMs] is local midnight; 0 means no clock.
  static bool historyDefaultExpanded({
    required int count,
    required int dayStartMs,
    DateTime? now,
  }) {
    if (alwaysExpanded(count)) return true;
    if (dayStartMs <= 0) return false;
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    if (dayStartMs == today.millisecondsSinceEpoch) return true;
    final previous = today.subtract(const Duration(days: 1));
    final yesterdayStart = DateTime(
      previous.year,
      previous.month,
      previous.day,
    ).millisecondsSinceEpoch;
    if (dayStartMs == yesterdayStart) {
      return count <= yesterdayAutoExpandMaxItems;
    }
    return false;
  }
}

/// Session memory so defaults apply once; user open/close wins afterwards.
class MediaLibraryGroupExpandMemory {
  final Set<String> _opened = <String>{};
  final Set<String> _closed = <String>{};

  bool isExpanded(String rowId, {required bool defaultExpanded}) {
    if (_closed.contains(rowId)) return false;
    if (_opened.contains(rowId)) return true;
    return defaultExpanded;
  }

  void toggle(String rowId, {required bool currentlyExpanded}) {
    if (currentlyExpanded) {
      _opened.remove(rowId);
      _closed.add(rowId);
    } else {
      _closed.remove(rowId);
      _opened.add(rowId);
    }
  }

  /// SnackBar 「查看」 and similar intents always win over the default.
  void forceOpen(String rowId) {
    _closed.remove(rowId);
    _opened.add(rowId);
  }

  void collapse(String rowId) {
    _opened.remove(rowId);
    _closed.add(rowId);
  }

  void clear() {
    _opened.clear();
    _closed.clear();
  }
}
