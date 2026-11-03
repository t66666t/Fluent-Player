import '../../../services/library_service.dart';
import '../../../models/media_source_ref.dart';
import '../services/cloud_drive_playback_service.dart';
import 'cloud_drive_models.dart';

enum CloudDriveViewSort { naturalName, name, modified, size, type }

enum CloudDriveViewFilter { all, media, video, audio }

extension CloudDriveViewSortLabel on CloudDriveViewSort {
  String get label => switch (this) {
    CloudDriveViewSort.naturalName => '自然名称',
    CloudDriveViewSort.name => '名称',
    CloudDriveViewSort.modified => '修改时间',
    CloudDriveViewSort.size => '文件大小',
    CloudDriveViewSort.type => '文件类型',
  };
}

extension CloudDriveViewFilterLabel on CloudDriveViewFilter {
  String get label => switch (this) {
    CloudDriveViewFilter.all => '全部文件',
    CloudDriveViewFilter.media => '视频与音频',
    CloudDriveViewFilter.video => '仅视频',
    CloudDriveViewFilter.audio => '仅音频',
  };
}

class CloudDriveViewOptions {
  const CloudDriveViewOptions({
    this.sort = CloudDriveViewSort.naturalName,
    this.descending = false,
    this.foldersFirst = true,
    this.filter = CloudDriveViewFilter.all,
  });
  final CloudDriveViewSort sort;
  final bool descending;
  final bool foldersFirst;
  final CloudDriveViewFilter filter;

  CloudDriveViewOptions copyWith({
    CloudDriveViewSort? sort,
    bool? descending,
    bool? foldersFirst,
    CloudDriveViewFilter? filter,
  }) => CloudDriveViewOptions(
    sort: sort ?? this.sort,
    descending: descending ?? this.descending,
    foldersFirst: foldersFirst ?? this.foldersFirst,
    filter: filter ?? this.filter,
  );

  Map<String, Object> toJson() => {
    'sort': sort.name,
    'descending': descending,
    'foldersFirst': foldersFirst,
    'filter': filter.name,
  };

  factory CloudDriveViewOptions.fromJson(Map<String, dynamic> json) =>
      CloudDriveViewOptions(
        sort:
            CloudDriveViewSort.values
                .where((v) => v.name == json['sort'])
                .firstOrNull ??
            CloudDriveViewSort.naturalName,
        descending: json['descending'] == true,
        foldersFirst: json['foldersFirst'] != false,
        filter:
            CloudDriveViewFilter.values
                .where((v) => v.name == json['filter'])
                .firstOrNull ??
            CloudDriveViewFilter.all,
      );

  List<CloudDriveEntry> project(
    Iterable<CloudDriveEntry> entries, {
    String query = '',
    bool sorted = true,
  }) {
    final needle = query.trim().toLowerCase();
    final result = entries.where((entry) {
      if (needle.isNotEmpty && !entry.name.toLowerCase().contains(needle)) {
        return false;
      }
      if (entry.kind == CloudDriveEntryKind.folder) return true;
      return switch (filter) {
        CloudDriveViewFilter.all => true,
        CloudDriveViewFilter.media =>
          entry.kind == CloudDriveEntryKind.video ||
              entry.kind == CloudDriveEntryKind.audio,
        CloudDriveViewFilter.video => entry.kind == CloudDriveEntryKind.video,
        CloudDriveViewFilter.audio => entry.kind == CloudDriveEntryKind.audio,
      };
    }).toList();
    if (sorted) result.sort(compare);
    return result;
  }

  int compare(CloudDriveEntry a, CloudDriveEntry b) {
    if (foldersFirst) {
      final folder = (a.kind == CloudDriveEntryKind.folder ? 0 : 1).compareTo(
        b.kind == CloudDriveEntryKind.folder ? 0 : 1,
      );
      if (folder != 0) return folder;
    }
    int nullable<T extends Comparable<dynamic>>(T? x, T? y) {
      if (x == null || y == null) return x == y ? 0 : (x == null ? 1 : -1);
      return x.compareTo(y) * (descending ? -1 : 1);
    }

    final direction = descending ? -1 : 1;
    final value = switch (sort) {
      CloudDriveViewSort.naturalName =>
        LibraryService.compareStructuredImportNames(a.name, b.name) * direction,
      CloudDriveViewSort.name =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()) * direction,
      CloudDriveViewSort.modified => nullable(a.modifiedAt, b.modifiedAt),
      CloudDriveViewSort.size => nullable(a.size, b.size),
      CloudDriveViewSort.type => _type(a).compareTo(_type(b)) * direction,
    };
    if (value != 0) return value;
    final name = LibraryService.compareStructuredImportNames(a.name, b.name);
    return name != 0
        ? name
        : cloudDriveEntryKey(a).compareTo(cloudDriveEntryKey(b));
  }

  static String _type(CloudDriveEntry entry) =>
      entry.kind == CloudDriveEntryKind.folder
      ? ''
      : entry.name.split('.').skip(1).lastOrNull?.toLowerCase() ?? '';
}

MediaSourceRef cloudDriveEntrySource(CloudDriveEntry entry) =>
    cloudDriveMediaSource(
      providerId: entry.providerId,
      remoteAccountId: entry.remoteAccountId,
      driveId: entry.driveId,
      fileId: entry.fileId,
      pathHint: entry.pathHint,
      revision: entry.revision,
    );

String cloudDriveEntryKey(CloudDriveEntry entry) =>
    cloudDriveEntrySource(entry).cloudDrive!.sourceKey;
