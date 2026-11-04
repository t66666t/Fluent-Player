import 'media_source_ref.dart';
import 'podcast_source_ref.dart';

class VideoCollection {
  final String id;
  String name;
  final int createTime;
  String? thumbnailPath;
  /// Retained until the Bilibili folder cover is saved, including across restarts.
  String? bilibiliPendingCoverUrl;
  /// Optional cover text. Null follows the folder name; empty hides text on this folder only.
  String? coverLabel;
  
  // New: File System Structure
  List<String> childrenIds; // Can contain VideoItem IDs or VideoCollection IDs
  String? parentId; // null means root
  bool isRecycled;
  int? recycleTime;
  MediaSourceRef? sourceRef;
  PodcastChannelRef? podcastRef;
  bool get isPodcast => podcastRef != null;

  /// Hides a podcast card from folder browsing while retaining its subscription.
  bool isHiddenFromFolders;

  // Deprecated but kept for migration if needed, though we will try to migrate immediately
  // List<String> videoIds; 

  VideoCollection({
    required this.id,
    required this.name,
    required this.createTime,
    this.thumbnailPath,
    this.bilibiliPendingCoverUrl,
    this.coverLabel,
    List<String>? childrenIds,
    this.parentId,
    this.isRecycled = false,
    this.recycleTime,
    this.sourceRef,
    this.podcastRef,
    this.isHiddenFromFolders = false,
  }) : childrenIds = childrenIds ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createTime': createTime,
      'thumbnailPath': thumbnailPath,
      if (bilibiliPendingCoverUrl != null)
        'bilibiliPendingCoverUrl': bilibiliPendingCoverUrl,
      'coverLabel': coverLabel,
      'childrenIds': childrenIds,
      'parentId': parentId,
      'isRecycled': isRecycled,
      'recycleTime': recycleTime,
      'sourceRef': sourceRef?.toJson(),
      if (podcastRef != null) 'podcastRef': podcastRef!.toJson(),
      if (isHiddenFromFolders) 'isHiddenFromFolders': true,
    };
  }

  factory VideoCollection.fromJson(Map<String, dynamic> json) {
    // Migration logic: if videoIds exists but childrenIds doesn't, use videoIds
    List<String> loadedChildren = [];
    if (json['childrenIds'] != null) {
      loadedChildren = (json['childrenIds'] as List<dynamic>).map((e) => e as String).toList();
    } else if (json['videoIds'] != null) {
      loadedChildren = (json['videoIds'] as List<dynamic>).map((e) => e as String).toList();
    }

    return VideoCollection(
      id: json['id'] as String,
      name: json['name'] as String,
      createTime: json['createTime'] as int,
      thumbnailPath: json['thumbnailPath'] as String?,
      bilibiliPendingCoverUrl: json['bilibiliPendingCoverUrl'] as String?,
      coverLabel: json['coverLabel'] as String?,
      childrenIds: loadedChildren,
      parentId: json['parentId'] as String?,
      isRecycled: json['isRecycled'] as bool? ?? false,
      recycleTime: json['recycleTime'] as int?,
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
      podcastRef: PodcastChannelRef.fromJsonOrNull(json['podcastRef']),
      isHiddenFromFolders: json['isHiddenFromFolders'] == true,
    );
  }
  
  // Helper to distinguish from VideoItem if needed (though we usually check by ID lookup)
  bool get isCollection => true;
}
