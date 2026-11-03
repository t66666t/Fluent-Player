class TemporaryStorageCategoryReport {
  final String id;
  final String title;
  final String description;
  final int fileCount;
  final int totalBytes;
  final bool canClean;
  final String? note;

  const TemporaryStorageCategoryReport({
    required this.id,
    required this.title,
    required this.description,
    required this.fileCount,
    required this.totalBytes,
    required this.canClean,
    this.note,
  });

  bool get hasVisibleContent {
    return fileCount > 0 || totalBytes > 0 || (note?.trim().isNotEmpty ?? false);
  }
}

class TemporaryStorageScanReport {
  final List<TemporaryStorageCategoryReport> categories;

  const TemporaryStorageScanReport({
    required this.categories,
  });

  int get totalBytes =>
      categories.fold(0, (sum, item) => sum + item.totalBytes);

  int get totalFileCount =>
      categories.fold(0, (sum, item) => sum + item.fileCount);

  bool get hasClearableContent =>
      categories.any((item) => item.canClean && item.totalBytes > 0);
}
