/// Rows, the details table and the folder tree stay in the tree, but the
/// library does not offer them. Flip this to bring the switcher back; saved
/// choices are left untouched and apply again.
bool mediaLibraryAlternateViewsEnabled = false;

/// Top-level browsing styles offered by the media-library view switcher.
///
/// The persisted integer is the enum index (`mediaLibraryViewMode`). Index 1
/// used to be the retired list tile; it now renders as [rows], which reuses the
/// same fixed-height row pipeline (selection, box select, reorder, preload).
enum MediaLibraryViewMode {
  grid,
  rows,
  table,
  tree;

  static MediaLibraryViewMode fromStorage(int value) {
    if (value < 0 || value >= values.length) return grid;
    return values[value];
  }

  int get storageValue => index;

  String get label => switch (this) {
    grid => '卡片网格',
    rows => '媒体行',
    table => '详细信息',
    tree => '树形分栏',
  };

  String get description => switch (this) {
    grid => '封面为主，适合靠画面识别内容',
    rows => '左图右文，长标题完整可读',
    table => '紧凑表格，可按列排序',
    tree => '左侧文件夹树，右侧浏览内容',
  };
}

/// What actually renders inside the scrolling content area.
///
/// [MediaLibraryViewMode.tree] is a shell around one of these, chosen by
/// `mediaTreeContentMode`.
enum MediaLibraryContentLayout {
  grid,
  rows,
  table;

  static MediaLibraryContentLayout fromStorage(int value) {
    if (value < 0 || value >= values.length) return rows;
    return values[value];
  }

  /// Rows and table share the fixed-extent row grid and its hit-test geometry.
  bool get usesRowPipeline => this != grid;

  String get label => switch (this) {
    grid => '卡片网格',
    rows => '媒体行',
    table => '详细信息',
  };
}

/// Optional columns of the details table. The title column is always shown.
enum MediaTableColumn {
  type,
  duration,
  progress,
  subtitles,
  updated,
  location;

  String get label => switch (this) {
    type => '类型',
    duration => '时长',
    progress => '观看进度',
    subtitles => '字幕',
    updated => '最近更新',
    location => '位置',
  };

  static Set<MediaTableColumn> decode(String raw) => {
    for (final name in raw.split(','))
      for (final column in values)
        if (column.name == name.trim()) column,
  };

  static String encode(Iterable<MediaTableColumn> columns) => [
    for (final column in values)
      if (columns.contains(column)) column.name,
  ].join(',');
}

/// View-only sort for the details table. [manual] keeps the stored folder
/// order (which drag-reorder edits); other keys never rewrite that order.
enum MediaTableSortKey {
  manual,
  title,
  type,
  duration,
  progress,
  updated;

  static MediaTableSortKey fromStorage(String value) => values.firstWhere(
    (key) => key.name == value,
    orElse: () => manual,
  );
}
