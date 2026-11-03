import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'library_service.dart';
import 'media_playback_service.dart';
import 'playback_navigation_service.dart';
import 'playlist_manager.dart';
import '../widgets/media_library_shell.dart';

/// The explicit imported id is authoritative, including when its card was
/// removed. Never substitute another import merely because the titles match.
Future<void> openImportedLibraryMedia(
  BuildContext context,
  String? libraryId, {
  Future<void> Function()? beforeOpen,
  LibraryService? library,
}) async {
  library ??= context.read<LibraryService>();
  void message(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));
  final item = libraryId == null ? null : library.getVideo(libraryId);
  if (item == null) {
    message(libraryId == null ? '找不到对应的媒体卡片，请在媒体库中查找' : '对应的媒体已从媒体库移除');
    return;
  }
  if (library.isStorageItemRecycled(item.id)) {
    message('该媒体在回收站中，请先恢复');
    return;
  }
  final playlist = context.read<PlaylistManager>();
  if (!playlist.isQueueEligible(item)) {
    message('媒体文件已移动或删除，请在媒体库中检查');
    return;
  }
  if (beforeOpen != null) await beforeOpen();
  if (!context.mounted) return;
  // A browser pause/teardown can be asynchronous. Check the exact card again
  // before touching the queue, so removal during that pause stays harmless.
  final current = library.getVideo(item.id);
  if (current == null || library.isStorageItemRecycled(item.id)) {
    message('对应的媒体已移除或移入回收站');
    return;
  }
  if (!playlist.prepareImportedPlayback(current)) {
    message('媒体文件已移动或删除，请在媒体库中检查');
    return;
  }
  FocusScope.of(context).unfocus();
  // This is an explicit library-card entry. A previous watch-only browsing
  // visit must not restore its older queue when this player page goes back.
  PlaybackNavigationService.instance.browseHistory.clear();
  PlaybackNavigationService.instance.primeLibraryPlaybackEntry(
    playbackService: context.read<MediaPlaybackService>(),
    item: current,
  );
  await pushAboveMediaLibrary(
    context,
    PlaybackNavigationService.buildPlaybackEntryRoute(current),
  );
}
