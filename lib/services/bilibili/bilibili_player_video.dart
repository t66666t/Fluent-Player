import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';

/// The Bilibili video (BV id and part) a playback card belongs to.
typedef BilibiliPlayerVideo = ({String bvid, int page});

final RegExp _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');

/// The Bilibili video behind [item], or null for any other media.
///
/// Online cards count, and so do downloaded videos that kept their BV id
/// (their source records the video they were downloaded from).
BilibiliPlayerVideo? bilibiliPlayerVideoOf(VideoItem? item) {
  if (item == null) return null;
  final ref = item.sourceRef;
  final online =
      ref?.kind == MediaSourceKind.bilibiliStream ||
      item.path.startsWith('bilibili://stream/');
  String? bvid;
  if (online) {
    bvid = bilibiliStreamCardBvid(item);
  } else if (ref != null) {
    final stored = ref.bvid?.trim();
    if (stored != null && stored.isNotEmpty) {
      bvid = stored;
    } else if (ref.kind == MediaSourceKind.bilibiliBv) {
      bvid = ref.value.trim();
    }
  }
  if (bvid == null || !_bvidPattern.hasMatch(bvid)) return null;
  final page = ref?.page;
  return (bvid: bvid, page: page != null && page > 0 ? page : 1);
}
