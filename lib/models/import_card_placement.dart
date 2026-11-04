import 'dart:convert';

import 'library_activity.dart';

/// Where a newly imported media card is placed in the library tree.
enum ImportCardPlacement {
  /// The folder that was open when the import was started. Home is the root.
  currentFolder,

  /// Always the media library root.
  libraryRoot,

  /// A stable folder per import feature, created at the library root.
  sourceFolder,

  /// One user-selected folder for all new imports (the root is also allowed).
  fixedFolder,

  /// Ask once for each import operation, never for each file in a batch.
  askEveryTime,
}

extension ImportCardPlacementX on ImportCardPlacement {
  String get storageValue {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return 'currentFolder';
      case ImportCardPlacement.libraryRoot:
        return 'libraryRoot';
      case ImportCardPlacement.sourceFolder:
        return 'sourceFolder';
      case ImportCardPlacement.fixedFolder:
        return 'fixedFolder';
      case ImportCardPlacement.askEveryTime:
        return 'askEveryTime';
    }
  }

  String get label {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return '跟随文件夹';
      case ImportCardPlacement.libraryRoot:
        return '全部放到根目录';
      case ImportCardPlacement.sourceFolder:
        return '按来源分类';
      case ImportCardPlacement.fixedFolder:
        return '统一收件箱';
      case ImportCardPlacement.askEveryTime:
        return '每次选择位置';
    }
  }

  String get description {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return '在哪个文件夹里开始导入，卡片就进哪里。媒体库首页则进根目录。';
      case ImportCardPlacement.libraryRoot:
        return '所有下载与导入统一放到媒体库根目录，之后由你自行整理。';
      case ImportCardPlacement.sourceFolder:
        return '按来源放入各自的文件夹，也可以为某个入口指定已有目录。';
      case ImportCardPlacement.fixedFolder:
        return '新增内容集中放入指定文件夹，之后再整理。';
      case ImportCardPlacement.askEveryTime:
        return '导入前选择位置，一批内容只选择一次。';
    }
  }

  static ImportCardPlacement fromStorage(Object? raw) {
    switch (raw) {
      case 'libraryRoot':
        return ImportCardPlacement.libraryRoot;
      case 'sourceFolder':
        return ImportCardPlacement.sourceFolder;
      case 'currentFolder':
        return ImportCardPlacement.currentFolder;
      case 'fixedFolder':
        return ImportCardPlacement.fixedFolder;
      case 'askEveryTime':
        return ImportCardPlacement.askEveryTime;
      default:
        return ImportCardPlacement.libraryRoot;
    }
  }
}

/// Import surfaces that can each own a stable library folder.
enum ImportCardFeature {
  podcast,
  localFile,
  folder,
  archive,
  bilibiliDownload,
  bilibiliOnline,
  ytDlp,
  fluentPack,
  cloudDrive,
  bilibiliPage,
  podcastEpisode,
  douyin,
  webMedia,
}

extension ImportCardFeatureX on ImportCardFeature {
  String get storageValue {
    switch (this) {
      case ImportCardFeature.podcast:
        return 'podcast';
      case ImportCardFeature.localFile:
        return 'localFile';
      case ImportCardFeature.folder:
        return 'folder';
      case ImportCardFeature.archive:
        return 'archive';
      case ImportCardFeature.bilibiliDownload:
        return 'bilibiliDownload';
      case ImportCardFeature.bilibiliOnline:
        return 'bilibiliOnline';
      case ImportCardFeature.ytDlp:
        return 'ytDlp';
      case ImportCardFeature.fluentPack:
        return 'fluentPack';
      case ImportCardFeature.cloudDrive:
        return 'cloudDrive';
      case ImportCardFeature.bilibiliPage:
        return 'bilibiliPage';
      case ImportCardFeature.podcastEpisode:
        return 'podcastEpisode';
      case ImportCardFeature.douyin:
        return 'douyin';
      case ImportCardFeature.webMedia:
        return 'webMedia';
    }
  }

  String get label {
    switch (this) {
      case ImportCardFeature.podcast:
        return '播客';
      case ImportCardFeature.localFile:
        return '本地文件';
      case ImportCardFeature.folder:
        return '文件夹导入';
      case ImportCardFeature.archive:
        return '压缩包';
      case ImportCardFeature.bilibiliDownload:
        return 'B站下载';
      case ImportCardFeature.bilibiliOnline:
        return 'B站在线';
      case ImportCardFeature.ytDlp:
        return 'YT-DLP';
      case ImportCardFeature.fluentPack:
        return '导出包';
      case ImportCardFeature.cloudDrive:
        return '网盘';
      case ImportCardFeature.bilibiliPage:
        return 'B站页面';
      case ImportCardFeature.podcastEpisode:
        return '播客单集';
      case ImportCardFeature.douyin:
        return '抖音下载';
      case ImportCardFeature.webMedia:
        return '浏览器导入';
    }
  }

  String get defaultFolderName => group.label;

  ImportCardGroup get group => switch (this) {
    ImportCardFeature.localFile ||
    ImportCardFeature.folder ||
    ImportCardFeature.archive => ImportCardGroup.local,
    ImportCardFeature.bilibiliDownload ||
    ImportCardFeature.bilibiliOnline ||
    ImportCardFeature.bilibiliPage => ImportCardGroup.bilibili,
    ImportCardFeature.podcast ||
    ImportCardFeature.podcastEpisode => ImportCardGroup.podcast,
    ImportCardFeature.ytDlp => ImportCardGroup.ytDlp,
    ImportCardFeature.fluentPack => ImportCardGroup.portable,
    ImportCardFeature.cloudDrive => ImportCardGroup.cloudDrive,
    ImportCardFeature.douyin => ImportCardGroup.douyin,
    ImportCardFeature.webMedia => ImportCardGroup.webMedia,
  };

  static ImportCardFeature? tryParse(Object? raw) {
    for (final feature in ImportCardFeature.values) {
      if (feature.storageValue == raw) return feature;
    }
    return null;
  }

  static ImportCardFeature fromSourceKind(LibraryImportSourceKind kind) {
    switch (kind) {
      case LibraryImportSourceKind.folder:
        return ImportCardFeature.folder;
      case LibraryImportSourceKind.archive:
        return ImportCardFeature.archive;
      case LibraryImportSourceKind.ytDlp:
        return ImportCardFeature.ytDlp;
      case LibraryImportSourceKind.fluentPack:
        return ImportCardFeature.fluentPack;
      case LibraryImportSourceKind.bilibili:
        return ImportCardFeature.bilibiliDownload;
      case LibraryImportSourceKind.localFile:
      case LibraryImportSourceKind.share:
        return ImportCardFeature.localFile;
      case LibraryImportSourceKind.cloudDrive:
        return ImportCardFeature.cloudDrive;
    }
  }
}

enum ImportCardGroup {
  local,
  portable,
  bilibili,
  ytDlp,
  podcast,
  cloudDrive,
  douyin,
  webMedia,
}

extension ImportCardGroupX on ImportCardGroup {
  String get ruleKey => 'group:$name';
  String get label => switch (this) {
    ImportCardGroup.local => '本地导入',
    ImportCardGroup.portable => '导出包',
    ImportCardGroup.bilibili => '哔哩哔哩',
    ImportCardGroup.ytDlp => 'yt-dlp',
    ImportCardGroup.podcast => '播客',
    ImportCardGroup.cloudDrive => '网盘',
    ImportCardGroup.douyin => '抖音',
    ImportCardGroup.webMedia => '网页导入',
  };
  String get description => switch (this) {
    ImportCardGroup.local => '媒体文件、文件夹、压缩包',
    ImportCardGroup.portable => '导入 / 导出页面、接收导出包',
    ImportCardGroup.bilibili => '下载页、在线解析、B站页面',
    ImportCardGroup.ytDlp => '单条下载、播放列表',
    ImportCardGroup.podcast => '频道订阅、单集导入',
    ImportCardGroup.cloudDrive => '网盘文件、文件夹导入',
    ImportCardGroup.douyin => '下载后加入媒体库',
    ImportCardGroup.webMedia => '网页识别、浏览器下载入库',
  };
  List<ImportCardFeature> get features => ImportCardFeature.values
      .where((feature) => feature.group == this)
      .toList(growable: false);
}

class ImportPlacementRule {
  const ImportPlacementRule(this.placement, {this.folderId});
  final ImportCardPlacement placement;

  /// Null is an explicitly selected root when placement is fixedFolder.
  final String? folderId;
  Map<String, dynamic> toJson() => {
    'placement': placement.storageValue,
    if (folderId != null) 'folderId': folderId,
  };
  static ImportPlacementRule? fromJson(Object? raw) {
    if (raw is! Map ||
        !ImportCardPlacement.values.any(
          (mode) => mode.storageValue == raw['placement'],
        )) {
      return null;
    }
    return ImportPlacementRule(
      ImportCardPlacementX.fromStorage(raw['placement']),
      folderId:
          raw['folderId'] is String &&
              (raw['folderId'] as String).trim().isNotEmpty
          ? (raw['folderId'] as String).trim()
          : null,
    );
  }
}

/// Preset-independent exceptions. Changing a preset preserves these choices.
class ImportPlacementRules {
  static const settingsKey = 'importPlacementRules';
  ImportPlacementRules({
    this.fixedFolderId,
    Map<String, ImportPlacementRule>? overrides,
  }) : overrides = Map.of(overrides ?? const {});
  String? fixedFolderId;
  final Map<String, ImportPlacementRule> overrides;

  ImportPlacementRule effectiveRule(
    ImportCardFeature feature,
    ImportCardPlacement preset,
  ) =>
      overrides[feature.storageValue] ??
      overrides[feature.group.ruleKey] ??
      ImportPlacementRule(preset, folderId: fixedFolderId);

  String encode() => jsonEncode({
    'version': 1,
    'fixedFolderId': fixedFolderId,
    'overrides': overrides.map((key, rule) => MapEntry(key, rule.toJson())),
  });

  factory ImportPlacementRules.decode(String raw) {
    final result = ImportPlacementRules();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return result;
      final folder = decoded['fixedFolderId'];
      if (folder is String && folder.trim().isNotEmpty) {
        result.fixedFolderId = folder.trim();
      }
      final overrides = decoded['overrides'];
      if (overrides is Map) {
        final keys = <String>{
          for (final feature in ImportCardFeature.values) feature.storageValue,
          for (final group in ImportCardGroup.values) group.ruleKey,
        };
        for (final key in keys) {
          final rule = ImportPlacementRule.fromJson(overrides[key]);
          if (rule != null) result.overrides[key] = rule;
        }
      }
    } catch (_) {
      /* Corrupt preferences fall back to the preset. */
    }
    return result;
  }
  static String normalize(String raw) =>
      ImportPlacementRules.decode(raw).encode();
}

/// A task owns its placement snapshot; null folders never mean "not captured".
/// Source directories are created lazily when content is actually imported.
class ImportPlacementRequest {
  ImportPlacementRequest({
    required this.feature,
    required this.placement,
    this.folderId,
    this.sourceFolderName,
    this.isResolved = false,
  });
  factory ImportPlacementRequest.explicit(
    ImportCardFeature feature,
    String? folderId,
  ) => ImportPlacementRequest(
    feature: feature,
    placement: ImportCardPlacement.fixedFolder,
    folderId: folderId,
    isResolved: true,
  );
  final ImportCardFeature feature;
  final ImportCardPlacement placement;
  String? folderId;
  final String? sourceFolderName;
  bool isResolved;
  Map<String, dynamic> toJson() => {
    'feature': feature.storageValue,
    'placement': placement.storageValue,
    'folderId': folderId,
    'sourceFolderName': sourceFolderName,
    'isResolved': isResolved,
  };
  static ImportPlacementRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final feature = ImportCardFeatureX.tryParse(raw['feature']);
    final rule = ImportPlacementRule.fromJson(raw);
    if (feature == null || rule == null) return null;
    return ImportPlacementRequest(
      feature: feature,
      placement: rule.placement,
      folderId: rule.folderId,
      sourceFolderName: raw['sourceFolderName'] is String
          ? raw['sourceFolderName'] as String
          : null,
      isResolved: raw['isResolved'] == true,
    );
  }
}

class ImportPlacementException implements Exception {
  const ImportPlacementException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ImportSourceFolders {
  static const String namesKey = 'importSourceFolderNames';
  static const String idsKey = 'importSourceFolderIds';

  static String sanitizeFolderName(String raw, {required String fallback}) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\r\n\t]'), ' ')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
        .trim();
    if (cleaned.isEmpty) return fallback;
    const maxLength = 40;
    if (cleaned.length <= maxLength) return cleaned;
    return cleaned.substring(0, maxLength).trim();
  }

  static Map<String, String> decodeNames(String raw) {
    final names = <String, String>{
      for (final feature in ImportCardFeature.values)
        feature.storageValue: feature.defaultFolderName,
    };
    final decoded = _decodeObject(raw);
    for (final feature in ImportCardFeature.values) {
      final value = decoded[feature.storageValue];
      if (value is! String) continue;
      names[feature.storageValue] = sanitizeFolderName(
        value,
        fallback: feature.defaultFolderName,
      );
    }
    return names;
  }

  static Map<String, String> decodeIds(String raw) {
    final ids = <String, String>{};
    final decoded = _decodeObject(raw);
    for (final feature in ImportCardFeature.values) {
      final value = decoded[feature.storageValue];
      if (value is! String) continue;
      final id = value.trim();
      if (id.isEmpty) continue;
      ids[feature.storageValue] = id;
    }
    return ids;
  }

  static String normalizeNamesJson(String raw) => jsonEncode(decodeNames(raw));

  static String normalizeIdsJson(String raw) => jsonEncode(decodeIds(raw));

  static Map<String, dynamic> _decodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }
}
