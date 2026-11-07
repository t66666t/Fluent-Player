/// Root-library destinations shown by the compact entry switcher.
enum MediaLibraryRootEntry {
  continueLearning,
  recent,
  folders,
  bilibili,
  podcasts,
  cloudDrive,
}

extension MediaLibraryRootEntryX on MediaLibraryRootEntry {
  /// Local surfaces are distinct from the available RSS podcast surface.
  bool get isLocal =>
      this == MediaLibraryRootEntry.continueLearning ||
      this == MediaLibraryRootEntry.recent ||
      this == MediaLibraryRootEntry.folders;

  /// Active community surfaces include local media and RSS podcasts.
  bool get isAvailable => isLocal || this == MediaLibraryRootEntry.podcasts;

  String get storageValue {
    switch (this) {
      case MediaLibraryRootEntry.continueLearning:
        return 'continueLearning';
      case MediaLibraryRootEntry.recent:
        return 'recent';
      case MediaLibraryRootEntry.folders:
        return 'folders';
      case MediaLibraryRootEntry.bilibili:
        return 'bilibili';
      case MediaLibraryRootEntry.podcasts:
        return 'podcasts';
      case MediaLibraryRootEntry.cloudDrive:
        return 'cloudDrive';
    }
  }

  String get label {
    switch (this) {
      case MediaLibraryRootEntry.continueLearning:
        return '继续学习';
      case MediaLibraryRootEntry.recent:
        return '最近添加';
      case MediaLibraryRootEntry.folders:
        return '文件夹';
      case MediaLibraryRootEntry.bilibili:
        return '哔哩哔哩';
      case MediaLibraryRootEntry.podcasts:
        return '播客';
      case MediaLibraryRootEntry.cloudDrive:
        return '网盘官网';
    }
  }

  static MediaLibraryRootEntry? tryParse(String? raw) {
    switch (raw) {
      case 'continueLearning':
        return MediaLibraryRootEntry.continueLearning;
      case 'recent':
        return MediaLibraryRootEntry.recent;
      case 'folders':
        return MediaLibraryRootEntry.folders;
      case 'bilibili':
        return MediaLibraryRootEntry.bilibili;
      case 'podcasts':
        return MediaLibraryRootEntry.podcasts;
      case 'cloudDrive':
        return MediaLibraryRootEntry.cloudDrive;
      default:
        return null;
    }
  }
}
