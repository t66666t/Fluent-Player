/// Disk accounting uses file lengths, never download estimates or media size
/// cached on a card. Decimal GB and binary GiB are deliberately distinguished.
String formatStorageSize(int bytes, {bool binary = false}) {
  final base = binary ? 1024 : 1000;
  final units = binary
      ? const ['B', 'KiB', 'MiB', 'GiB', 'TiB']
      : const ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= base && index < units.length - 1) {
    value /= base;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 2)} ${units[index]}';
}

enum StorageCategory {
  libraryMedia('媒体库原文件', '已导入的视频和音频；通过卡片移入回收站后删除。'),
  recycleBin('回收站文件', '已回收卡片的原文件和附属资源；与其他卡片共享的文件只计一次。'),
  downloads('下载成品', '已下载但尚未被媒体库引用的成品；删除后需要重新下载。'),
  offlineDownloads('离线下载', '用户明确保留的播客等离线媒体。不参与普通清缓存；删除后需要重新下载，听过和订阅状态仍保留。'),
  streaming('在线播放缓存', '可重新获取的在线播放片段，例如 RSS 播客试听缓存；仅统计已经保存在本机的文件。'),
  materialized('转写与合成素材', '为播放预览、转写、OCR 或合成准备的音视频副本；使用中和可恢复的任务素材受保护。'),
  thumbnails('封面与缩略图', '卡片封面、章节图片与在线预览图；自选封面删除后无法恢复，其他预览图可按需重建。'),
  subtitles('字幕与弹幕', '媒体库保存的字幕和弹幕；需单独确认后删除，并同步清除卡片引用，删除后无法恢复。'),
  compatibility('兼容播放副本', '为兼容音频解码生成的媒体副本；清理后仍保留原文件，需要时重新生成。'),
  picker('文件选择与导入缓存', '文件选择器、相册及分享导入产生的临时副本。'),
  downloadTemp('下载中间文件', '分段、合并、重试和中断下载产生的临时文件。'),
  workTemp('转写、OCR 与合成临时文件', '提取的音频、OCR 图片、本地推理、AI 文稿预处理缓存和合成工作文件。'),
  transfer('导出包与传输文件', '.fluentpack 导出包、压缩包、解压和便携传输工作副本；删除后无法恢复导出包。'),
  orphaned('未关联的媒体库文件', '已知媒体库目录中没有卡片或任务引用的遗留文件。'),
  models('本地模型', '本地语音识别、翻译、语音增强和 OCR 模型及配套文件、下载断点；由模型功能管理。历史工具文件保留占用明细。'),
  metadata('配置与任务记录', '媒体库索引、备份、AI 会话、字体、连接权限、设置和可恢复任务，以及保留的历史记录。'),
  other('其他与待核实文件', '尚不能确认用途的文件；保留路径明细，避免误删。');

  const StorageCategory(this.title, this.description);
  final String title;
  final String description;
}

enum StorageRootKind { data, cache, support, privateContainer, exports }

/// Mutually exclusive accounting origin. Filter tags may overlap; this does not.
enum StorageOrigin {
  localMedia('本地媒体'),
  bilibili('B 站'),
  ytDlp('yt-dlp'),
  podcast('播客'),
  cloudDrive('网盘'),
  shared('共享资源'),
  appData('应用数据'),
  unknown('未知'),
  web('网页媒体'),
  douyin('抖音');

  const StorageOrigin(this.title);
  final String title;
}

/// How a confirmed cleanup is allowed to treat the file. Suffixes never decide this.
enum StorageCleanupPolicy {
  regenerableCache,
  savedContent,
  featureManaged,
  protected,
  unknown,
}

/// Which button produced the plan. The service checks it again after confirmation.
enum StorageCleanupAction {
  /// Historical callers: only files already marked [StorageFileEntry.canDelete].
  listed,
  clearCache,
  deleteOffline,
  deleteSubtitle,
  abandonResume,
}

enum StorageAssetRole {
  file,
  mediaSegment,
  assembledMedia,
  subtitleBody,
  wordTiming,
  remoteStamp,
  partialCommit,
  manifest,
  checkpoint,
  database,
  databaseAuxiliary,
  upgradeBackup,
  artworkBlob,
  artworkStaging,
  accountMetadata,
  loginProfile,
  resumePart,
}

/// Display labels for subtitle provenance. Missing evidence stays unverified.
abstract final class StorageSubtitleKinds {
  static const podcastOfficial = '播客官方文稿';
  static const cloudSidecar = '网盘外挂字幕副本';
  static const cloudOfficial = '网盘官方字幕';
  static const cloudOfficialAi = '网盘官方 AI 字幕';
  static const ai = '本地 AI 字幕';
  static const translated = '翻译字幕';
  static const ocr = 'OCR 字幕';
  static const imported = '导入字幕';
  static const unverified = '来源待核实';
}

/// Plain asset description sent to the scan isolate. It must not open services.
class StorageAssetDescriptor {
  const StorageAssetDescriptor({
    required this.assetKey,
    required this.origin,
    required this.category,
    required this.policy,
    this.sourceTags = const [],
    this.title = '',
    this.paths = const [],
    this.directory,
    this.protected = false,
    this.protection,
    this.role = StorageAssetRole.file,
    this.subtitleKind,
    this.deletable = false,
    this.explicitDelete = false,
    this.cacheableResidue = false,
    this.version = 0,
    this.ownerIds = const [],
    this.detail,
  });

  final String assetKey;
  final StorageOrigin origin;
  final List<StorageOrigin> sourceTags;
  final StorageCategory category;
  final StorageCleanupPolicy policy;
  final String title;
  final List<String> paths;
  final String? directory;
  final bool protected;
  final String? protection;
  final StorageAssetRole role;
  final String? subtitleKind;
  final bool deletable;
  final bool explicitDelete;

  /// Sealed-material leftovers may be cleared; live resume data may not.
  final bool cacheableResidue;
  final int version;
  final List<String> ownerIds;
  final String? detail;
}

class StorageRoot {
  const StorageRoot(
    this.path,
    this.label,
    this.kind, {
    this.scoped = false,
    this.feature,
  });
  final String path;
  final String label;
  final StorageRootKind kind;

  /// Shared Documents and system temp directories are only examined under
  /// known application subdirectories and filename patterns.
  final bool scoped;

  /// Set when this root is an already proven feature directory, so classification
  /// retains its logical folder name even at a registered historical location.
  final String? feature;
}

class StorageReference {
  const StorageReference({
    required this.path,
    required this.ownerId,
    required this.ownerTitle,
    required this.category,
    this.directory = false,
    this.recycled = false,
    this.deletable = false,
    this.origin,
    this.subtitleKind,
    this.assetKey,
    this.role = StorageAssetRole.file,
  });
  final String path;
  final String ownerId;
  final String ownerTitle;
  final StorageCategory category;
  final bool directory;
  final bool recycled;
  final bool deletable;
  final StorageOrigin? origin;
  final String? subtitleKind;
  final String? assetKey;
  final StorageAssetRole role;
}

class StorageScanInput {
  const StorageScanInput({
    required this.roots,
    this.references = const [],
    this.protectedPaths = const [],
    this.protectedPrefixes = const [],
    this.protectedFilePrefixes = const [],
    this.warnings = const [],
    this.minimumTemporaryAge = Duration.zero,
    this.platformUsage,
    this.assets = const [],
    this.verifiedPaths = const [],
    this.sourceVersions = const {},
  });
  final List<StorageRoot> roots;
  final List<StorageReference> references;
  final List<String> protectedPaths;
  final List<String> protectedPrefixes;
  final List<String> protectedFilePrefixes;
  final List<String> warnings;
  final Duration minimumTemporaryAge;
  final StoragePlatformUsage? platformUsage;

  /// Asset groups collected on the UI isolate. The scanner only reads these.
  final List<StorageAssetDescriptor> assets;

  /// Exact directories that may be entered under a scoped shared root.
  final List<String> verifiedPaths;

  /// Cheap change tokens (usually a database mtime) used to expire a snapshot.
  final Map<String, int> sourceVersions;
}

class StoragePlatformUsage {
  const StoragePlatformUsage({
    required this.appBytes,
    required this.dataBytes,
    required this.cacheBytes,
    required this.sampledAt,
  });
  final int appBytes;

  /// Android dataBytes already includes cacheBytes.
  final int dataBytes;
  final int cacheBytes;
  final DateTime sampledAt;
  int get totalBytes => appBytes + dataBytes;
}

class StorageFileEntry {
  const StorageFileEntry({
    required this.path,
    required this.rootPath,
    required this.rootLabel,
    required this.category,
    required this.bytes,
    required this.modifiedMicros,
    required this.changedMicros,
    required this.ownerIds,
    required this.ownerTitles,
    required this.canDelete,
    this.protection,
    this.external = false,
    this.origin = StorageOrigin.unknown,
    this.sourceTags = const [],
    this.assetKey,
    this.role = StorageAssetRole.file,
    this.cleanupPolicy = StorageCleanupPolicy.unknown,
    this.subtitleKind,
    this.detail,
    this.explicitDelete = false,
    this.assetVersion = 0,
  });
  final String path;
  final String rootPath;
  final String rootLabel;
  final StorageCategory category;
  final int bytes;
  final int modifiedMicros;
  final int changedMicros;
  final List<String> ownerIds;
  final List<String> ownerTitles;

  /// Whether the generic cache/listed cleanup may delete this file right now.
  final bool canDelete;
  final String? protection;

  /// Referenced originals outside application roots are shown separately.
  final bool external;
  final StorageOrigin origin;

  /// Overlapping filter tags. Do not add these sizes into a second total.
  final List<StorageOrigin> sourceTags;
  final String? assetKey;
  final StorageAssetRole role;
  final StorageCleanupPolicy cleanupPolicy;
  final String? subtitleKind;
  final String? detail;

  /// Saved downloads, subtitles or resume data that need their own confirmation.
  final bool explicitDelete;
  final int assetVersion;
}

/// A confirmed plan may delete a file only when the action matches its policy.
bool storageDeletionPermitted(
  StorageCleanupAction action,
  StorageFileEntry file,
) {
  if (file.external) return false;
  return switch (action) {
    StorageCleanupAction.listed => file.canDelete,
    StorageCleanupAction.clearCache =>
      file.canDelete &&
          file.cleanupPolicy == StorageCleanupPolicy.regenerableCache,
    StorageCleanupAction.deleteOffline =>
      file.explicitDelete &&
          file.category == StorageCategory.offlineDownloads &&
          file.cleanupPolicy == StorageCleanupPolicy.savedContent,
    StorageCleanupAction.deleteSubtitle =>
      file.explicitDelete &&
          file.category == StorageCategory.subtitles &&
          file.cleanupPolicy == StorageCleanupPolicy.savedContent,
    StorageCleanupAction.abandonResume =>
      file.explicitDelete &&
          file.category == StorageCategory.downloadTemp &&
          file.cleanupPolicy == StorageCleanupPolicy.featureManaged,
  };
}

class StorageCategoryUsage {
  StorageCategoryUsage(this.category, this.files)
    : bytes = files.fold(0, (sum, f) => sum + f.bytes),
      clearableBytes = files.fold(
        0,
        (sum, f) => sum + (f.canDelete ? f.bytes : 0),
      );
  final StorageCategory category;
  final List<StorageFileEntry> files;
  final int bytes;
  final int clearableBytes;

  int get cacheBytes => files.fold(
    0,
    (sum, file) =>
        sum +
        (storageDeletionPermitted(StorageCleanupAction.clearCache, file)
            ? file.bytes
            : 0),
  );
}

class StorageOriginUsage {
  const StorageOriginUsage(this.origin, this.bytes, this.fileCount);
  final StorageOrigin origin;
  final int bytes;
  final int fileCount;
}

class StorageSnapshot {
  StorageSnapshot({
    required this.scannedAt,
    required this.files,
    required this.roots,
    required this.warnings,
    this.platformUsage,
    this.sourceVersions = const {},
  }) : categories = [
         for (final category in StorageCategory.values)
           StorageCategoryUsage(
             category,
             files.where((f) => !f.external && f.category == category).toList(),
           ),
       ],
       origins = _originUsage(files),
       appBytes = files.fold(0, (sum, f) => sum + (f.external ? 0 : f.bytes)),
       appFileCount = files.where((f) => !f.external).length,
       externalBytes = files.fold(
         0,
         (sum, f) => sum + (f.external ? f.bytes : 0),
       );

  final DateTime scannedAt;
  final List<StorageFileEntry> files;
  final List<StorageRoot> roots;
  final List<String> warnings;
  final StoragePlatformUsage? platformUsage;
  final Map<String, int> sourceVersions;
  final List<StorageCategoryUsage> categories;
  final List<StorageOriginUsage> origins;
  final int appBytes;
  final int appFileCount;
  final int externalBytes;
  int get clearableBytes =>
      categories.fold(0, (sum, c) => sum + c.clearableBytes);

  static List<StorageOriginUsage> _originUsage(List<StorageFileEntry> files) {
    final bytes = <StorageOrigin, int>{};
    final counts = <StorageOrigin, int>{};
    for (final file in files) {
      if (file.external) continue;
      bytes[file.origin] = (bytes[file.origin] ?? 0) + file.bytes;
      counts[file.origin] = (counts[file.origin] ?? 0) + 1;
    }
    return [
      for (final origin in StorageOrigin.values)
        if ((counts[origin] ?? 0) > 0)
          StorageOriginUsage(origin, bytes[origin]!, counts[origin]!),
    ];
  }
}

class StorageDeletionPlan {
  const StorageDeletionPlan(
    this.files, {
    this.action = StorageCleanupAction.listed,
  });
  final List<StorageFileEntry> files;
  final StorageCleanupAction action;
  int get bytes => files.fold(0, (sum, f) => sum + f.bytes);
}

class StorageDeletionResult {
  const StorageDeletionResult({
    required this.deletedPaths,
    required this.releasedBytes,
    required this.skipped,
    required this.failed,
    this.warnings = const [],
  });
  final List<String> deletedPaths;
  final int releasedBytes;
  final Map<String, String> skipped;
  final Map<String, String> failed;

  /// Index repair failed after the bytes were already released.
  final List<String> warnings;
}

class StorageDeletionProgress {
  const StorageDeletionProgress({
    required this.completedFiles,
    required this.totalFiles,
    required this.releasedBytes,
  });

  final int completedFiles;
  final int totalFiles;
  final int releasedBytes;
}
