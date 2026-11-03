import 'cloud_drive_source_ref.dart';
import 'podcast_source_ref.dart';

enum MediaSourceKind { url, bilibiliBv, bilibiliId, bilibiliStream, cloudDrive, podcastEpisode }

class MediaSourceRef {
  final String value;
  final MediaSourceKind kind;
  final String? originalValue;
  final String? bvid;
  final String? aid;
  final int? cid;
  final int? page;
  final int? bilibiliCourseEpisodeId;
  /// Original metadata, independent of the card's editable display title.
  final String? bilibiliVideoTitle;
  final String? bilibiliPartTitle;
  final int? bilibiliPartCount;
  final CloudDriveSourceRef? cloudDrive;
  final PodcastEpisodeRef? podcast;

  const MediaSourceRef({
    required this.value,
    required this.kind,
    this.originalValue,
    this.bvid,
    this.aid,
    this.cid,
    this.page,
    this.bilibiliCourseEpisodeId,
    this.bilibiliVideoTitle,
    this.bilibiliPartTitle,
    this.bilibiliPartCount,
    this.cloudDrive,
    this.podcast,
  });

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      'kind': kind.name,
      'originalValue': originalValue,
      'bvid': bvid,
      'aid': aid,
      'cid': cid,
      'page': page,
      if (bilibiliCourseEpisodeId != null)
        'bilibiliCourseEpisodeId': bilibiliCourseEpisodeId,
      if (bilibiliVideoTitle != null) 'bilibiliVideoTitle': bilibiliVideoTitle,
      if (bilibiliPartTitle != null) 'bilibiliPartTitle': bilibiliPartTitle,
      if (bilibiliPartCount != null) 'bilibiliPartCount': bilibiliPartCount,
      'cloudDrive': cloudDrive?.toJson(),
      if (podcast != null) 'podcast': podcast!.toJson(),
    };
  }

  factory MediaSourceRef.fromJson(Map<String, dynamic> json) {
    final value = (json['value'] ?? '').toString().trim();
    return MediaSourceRef(
      value: value,
      kind: MediaSourceKind.values.firstWhere(
        (item) => item.name == json['kind'],
        orElse: () => MediaSourceKind.url,
      ),
      originalValue: _nullableTrimmedString(json['originalValue']),
      bvid: _nullableTrimmedString(json['bvid']),
      aid: _nullableTrimmedString(json['aid']),
      cid: _nullablePositiveInt(json['cid']),
      page: _nullablePositiveInt(json['page']),
      bilibiliCourseEpisodeId: _nullablePositiveInt(json['bilibiliCourseEpisodeId']),
      bilibiliVideoTitle: _nullableTrimmedString(json['bilibiliVideoTitle']),
      bilibiliPartTitle: _nullableTrimmedString(json['bilibiliPartTitle']),
      bilibiliPartCount: _nullablePositiveInt(json['bilibiliPartCount']),
      cloudDrive: CloudDriveSourceRef.fromJsonOrNull(json['cloudDrive']),
      podcast: PodcastEpisodeRef.fromJsonOrNull(json['podcast']),
    );
  }

  MediaSourceRef copyWith({
    String? value,
    MediaSourceKind? kind,
    Object? originalValue = _unset,
    Object? bvid = _unset,
    Object? aid = _unset,
    Object? cid = _unset,
    Object? page = _unset,
    Object? bilibiliCourseEpisodeId = _unset,
    Object? bilibiliVideoTitle = _unset,
    Object? bilibiliPartTitle = _unset,
    Object? bilibiliPartCount = _unset,
    Object? cloudDrive = _unset,
    Object? podcast = _unset,
  }) {
    return MediaSourceRef(
      value: value ?? this.value,
      kind: kind ?? this.kind,
      originalValue: identical(originalValue, _unset)
          ? this.originalValue
          : originalValue as String?,
      bvid: identical(bvid, _unset) ? this.bvid : bvid as String?,
      aid: identical(aid, _unset) ? this.aid : aid as String?,
      cid: identical(cid, _unset) ? this.cid : cid as int?,
      page: identical(page, _unset) ? this.page : page as int?,
      bilibiliCourseEpisodeId: identical(bilibiliCourseEpisodeId, _unset)
          ? this.bilibiliCourseEpisodeId
          : bilibiliCourseEpisodeId as int?,
      bilibiliVideoTitle: identical(bilibiliVideoTitle, _unset)
          ? this.bilibiliVideoTitle
          : bilibiliVideoTitle as String?,
      bilibiliPartTitle: identical(bilibiliPartTitle, _unset)
          ? this.bilibiliPartTitle
          : bilibiliPartTitle as String?,
      bilibiliPartCount: identical(bilibiliPartCount, _unset)
          ? this.bilibiliPartCount
          : bilibiliPartCount as int?,
      cloudDrive: identical(cloudDrive, _unset)
          ? this.cloudDrive
          : cloudDrive as CloudDriveSourceRef?,
      podcast: identical(podcast, _unset) ? this.podcast : podcast as PodcastEpisodeRef?,
    );
  }

  static MediaSourceRef? fromJsonOrNull(Object? json) {
    if (json is! Map) {
      return null;
    }
    final parsed = MediaSourceRef.fromJson(Map<String, dynamic>.from(json));
    return parsed.value.isEmpty ? null : parsed;
  }
}

/// True when this card must never be treated as a local file.
bool isCloudDriveMedia({MediaSourceRef? source, required String path}) =>
    source?.kind == MediaSourceKind.cloudDrive || isCloudDriveLogicalPath(path);

/// Bilibili streams and cloud cards need a downloaded local input.
bool itemNeedsOnlineMaterialization({
  MediaSourceRef? source,
  required String path,
}) =>
    path.startsWith('bilibili://stream/') ||
    source?.kind == MediaSourceKind.bilibiliStream ||
    source?.kind == MediaSourceKind.podcastEpisode ||
    path.startsWith('podcast:') ||
    isCloudDriveMedia(source: source, path: path);

const Object _unset = Object();

String? _nullableTrimmedString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _nullablePositiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}
