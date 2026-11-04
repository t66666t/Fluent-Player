import 'dart:io';

import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';

/// Folders an online card writes its cover, danmaku and preview frames to.
typedef BilibiliStreamCardDirectories = ({
  Directory dataRoot,
  Directory thumbDir,
  Directory danmakuDir,
});

/// One online card handed out by the shared card entry.
class BilibiliStreamCardResult {
  final VideoItem item;

  /// False when an existing card for the same BV + part was reused.
  final bool created;

  const BilibiliStreamCardResult({required this.item, required this.created});
}

/// Cards for one video, as returned to the in-app Bilibili pages.
class BilibiliStreamCardBatch {
  final BilibiliVideoInfo videoInfo;
  final List<BilibiliStreamCardResult> cards;

  /// Part numbers whose card could not be created.
  final List<int> failedPages;

  /// Folder the new cards were imported into (a multi-part video gets its
  /// own folder inside it); null for the library root, or when nothing had
  /// to be created.
  final String? targetFolderId;

  const BilibiliStreamCardBatch({
    required this.videoInfo,
    required this.cards,
    this.failedPages = const <int>[],
    this.targetFolderId,
  });

  int get createdCount => cards.where((card) => card.created).length;
  int get reusedCount => cards.length - createdCount;
}

final RegExp _streamPathBvid = RegExp(
  r'^bilibili://stream/(BV[0-9A-Za-z]{10})',
);
final RegExp _streamPathCid = RegExp(r'[?&]cid=(\d+)');

/// BV id of an online card, from its source ref or legacy path.
String? bilibiliStreamCardBvid(VideoItem item) {
  final ref = item.sourceRef;
  final fromRef = ref?.bvid?.trim();
  if (fromRef != null && fromRef.isNotEmpty) return fromRef;
  if (ref?.kind == MediaSourceKind.bilibiliStream) {
    final value = ref!.value.trim();
    if (value.isNotEmpty) return value;
  }
  return _streamPathBvid.firstMatch(item.path)?.group(1);
}

int? _streamCardCid(VideoItem item) {
  final cid = item.sourceRef?.cid;
  if (cid != null && cid > 0) return cid;
  final match = _streamPathCid.firstMatch(item.path);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Identity of one online Bilibili part: `bvid#cid`.
///
/// Library cards and one-time watch cards of this part share it. A downloaded
/// file, or any other card, returns null even when the file path matches.
String? bilibiliOnlinePartKey(VideoItem item) {
  if (!_isOnlineCard(item)) return null;
  final bvid = bilibiliStreamCardBvid(item);
  final cid = _streamCardCid(item);
  if (bvid == null || bvid.isEmpty || cid == null || cid <= 0) return null;
  return '$bvid#$cid';
}

bool _isOnlineCard(VideoItem item) =>
    item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
    item.path.startsWith('bilibili://stream/');

/// True when neither the card nor any folder above it is in the recycle bin.
bool isLiveLibraryItem(
  VideoItem item,
  VideoCollection? Function(String id) collectionOf,
) {
  if (item.isRecycled) return false;
  final visited = <String>{};
  var parentId = item.parentId;
  while (parentId != null && visited.add(parentId)) {
    final folder = collectionOf(parentId);
    if (folder == null) return true;
    if (folder.isRecycled) return false;
    parentId = folder.parentId;
  }
  return true;
}

/// Live online cards of [bvid], any part.
List<VideoItem> findBilibiliStreamCardsOfVideo(
  Iterable<VideoItem> items, {
  required String bvid,
  required VideoCollection? Function(String id) collectionOf,
}) {
  return items
      .where(
        (item) =>
            _isOnlineCard(item) &&
            bilibiliStreamCardBvid(item) == bvid &&
            isLiveLibraryItem(item, collectionOf),
      )
      .toList(growable: false);
}

/// Older cards without a stored part number are matched by [cid] when known,
/// otherwise treated as part 1.
bool _matchesPart(VideoItem item, {required int page, int? cid}) {
  final storedPage = item.sourceRef?.page;
  if (storedPage != null) return storedPage == page;
  final storedCid = _streamCardCid(item);
  if (storedCid != null && cid != null && cid > 0) return storedCid == cid;
  return page == 1;
}

/// The live online card for [bvid] part [page], or null. When several exist
/// (older imports were never deduplicated) the most recently updated wins.
VideoItem? findBilibiliStreamCard(
  Iterable<VideoItem> items, {
  required String bvid,
  required int page,
  int? cid,
  required VideoCollection? Function(String id) collectionOf,
}) {
  VideoItem? best;
  for (final item in findBilibiliStreamCardsOfVideo(
    items,
    bvid: bvid,
    collectionOf: collectionOf,
  )) {
    if (!_matchesPart(item, page: page, cid: cid)) continue;
    if (best == null || item.lastUpdated > best.lastUpdated) best = item;
  }
  return best;
}
