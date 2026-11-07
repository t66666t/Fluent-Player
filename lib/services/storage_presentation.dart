import 'storage_audit_models.dart';

/// Presentation only: filtering never changes the retained scan or its policies.
enum StorageSourceFilter {
  all('全部'),
  local('本地媒体'),
  podcast('播客'),
  bilibili('B 站'),
  cloudDrive('网盘'),
  website('网页与下载工具'),
  appData('应用数据'),
  shared('共享资源'),
  other('其他来源'),
  legacy('历史来源文件');

  const StorageSourceFilter(this.title);
  final String title;

  bool matches(StorageFileEntry file) {
    bool has(StorageOrigin origin) =>
        file.origin == origin || file.sourceTags.contains(origin);
    return switch (this) {
      all => true,
      local => has(StorageOrigin.localMedia),
      podcast => has(StorageOrigin.podcast),
      bilibili => has(StorageOrigin.bilibili),
      cloudDrive => has(StorageOrigin.cloudDrive),
      website =>
        has(StorageOrigin.web) ||
            has(StorageOrigin.douyin) ||
            has(StorageOrigin.ytDlp),
      appData => has(StorageOrigin.appData),
      shared => has(StorageOrigin.shared),
      other => has(StorageOrigin.unknown),
      legacy =>
        has(StorageOrigin.bilibili) ||
            has(StorageOrigin.cloudDrive) ||
            has(StorageOrigin.web) ||
            has(StorageOrigin.douyin) ||
            has(StorageOrigin.ytDlp),
    };
  }
}

// This standalone edition owns its own list; do not infer it from old files.
const storageSourceFilters = [
  StorageSourceFilter.all,
  StorageSourceFilter.local,
  StorageSourceFilter.podcast,
  StorageSourceFilter.appData,
  StorageSourceFilter.shared,
  StorageSourceFilter.other,
  StorageSourceFilter.legacy,
];

enum StorageSection {
  saved('媒体与保存的成果', '原文件、离线下载和字幕；删除成果前会单独确认。'),
  cache('缓存与工作文件', '仅可重建的缓存直接清理；封面与任务文件按各自规则管理。'),
  resources('导出、模型与应用数据', '导出包、模型、设置和任务记录按各自用途管理。'),
  review('需要核实的文件', '未关联不代表没有价值，请查看路径后决定是否删除。');

  const StorageSection(this.title, this.description);
  final String title;
  final String description;
}

StorageSection storageSection(StorageCategory category) => switch (category) {
  StorageCategory.libraryMedia ||
  StorageCategory.recycleBin ||
  StorageCategory.downloads ||
  StorageCategory.offlineDownloads ||
  StorageCategory.subtitles => StorageSection.saved,
  StorageCategory.streaming ||
  StorageCategory.materialized ||
  StorageCategory.thumbnails ||
  StorageCategory.compatibility ||
  StorageCategory.picker ||
  StorageCategory.downloadTemp ||
  StorageCategory.workTemp => StorageSection.cache,
  StorageCategory.transfer ||
  StorageCategory.models ||
  StorageCategory.metadata => StorageSection.resources,
  StorageCategory.orphaned || StorageCategory.other => StorageSection.review,
};

bool storageNeedsConfirmation(StorageFileEntry file) =>
    !storageDeletionPermitted(StorageCleanupAction.clearCache, file) &&
    StorageCleanupAction.values.any(
      (action) => storageDeletionPermitted(action, file),
    );

class StorageView {
  StorageView(StorageSnapshot snapshot, StorageSourceFilter source)
    : files = snapshot.files.where(source.matches).toList() {
    final appFiles = files.where((file) => !file.external).toList();
    bytes = appFiles.fold(0, (sum, file) => sum + file.bytes);
    fileCount = appFiles.length;
    cacheFiles = appFiles
        .where(
          (file) =>
              storageDeletionPermitted(StorageCleanupAction.clearCache, file),
        )
        .toList();
    cacheBytes = cacheFiles.fold(0, (sum, file) => sum + file.bytes);
    confirmationBytes = appFiles
        .where(storageNeedsConfirmation)
        .fold(0, (sum, file) => sum + file.bytes);
    externalFiles = files.where((file) => file.external).toList();
    externalBytes = externalFiles.fold(0, (sum, file) => sum + file.bytes);
    categories = [
      for (final category in StorageCategory.values)
        if (appFiles.any((file) => file.category == category))
          StorageCategoryUsage(
            category,
            appFiles.where((file) => file.category == category).toList(),
          ),
    ]..sort((a, b) => b.bytes.compareTo(a.bytes));
  }

  final List<StorageFileEntry> files;
  late final int bytes;
  late final int fileCount;
  late final List<StorageFileEntry> cacheFiles;
  late final int cacheBytes;
  late final int confirmationBytes;
  late final List<StorageFileEntry> externalFiles;
  late final int externalBytes;
  late final List<StorageCategoryUsage> categories;
}
