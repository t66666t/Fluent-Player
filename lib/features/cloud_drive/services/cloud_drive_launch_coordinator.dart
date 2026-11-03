import 'dart:async';
import 'package:flutter/material.dart';
import '../../../models/media_source_ref.dart';
import '../../../models/video_item.dart';
import '../../../services/library_service.dart';
import '../../../services/media_playback_service.dart';
import '../../../services/playback_navigation_service.dart';
import '../../../services/playlist_manager.dart';
import '../../../widgets/media_library_shell.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_view_options.dart';
import 'cloud_drive_directory_session.dart';

/// Turns a tapped cloud file into the existing player session.
class CloudDriveLaunchCoordinator {
  CloudDriveLaunchCoordinator({
    required this.library,
    required this.playlist,
    required this.playback,
  }) {
    playlist.addListener(_checkOwner);
  }
  final LibraryService library;
  final PlaylistManager playlist;
  final MediaPlaybackService playback;
  CloudDriveDirectorySession? _directory;
  Object? _owner;

  void _checkOwner() {
    if (_owner != null && !identical(playlist.queueOwner, _owner)) {
      _directory?.release();
      _directory = null;
      _owner = null;
    }
  }

  void dispose() {
    if (_owner != null && identical(playlist.queueOwner, _owner)) {
      playback.cloudDrivePreparePlaylist = null;
      playback.cloudDriveQueueNeedsCompletion = null;
      playback.cloudDriveLoadNextPlaylistPage = null;
    }
    playlist.removeListener(_checkOwner);
    _directory?.release();
    _directory = null;
    _owner = null;
  }

  Future<VideoItem> _card(CloudDriveEntry entry, {String? openedFromFolderId}) {
    final source = cloudDriveEntrySource(entry);
    library.cloudDriveThumbnails?.rememberEntry(source.cloudDrive!, entry);
    return library.upsertCloudDriveCard(
      source: source,
      title: entry.name,
      libraryItemId: library
          .cloudDriveCardForSource(source.cloudDrive!.sourceKey)
          ?.id,
      openedFromFolderId: openedFromFolderId,
      thumbnailRef: entry.thumbnailRef,
      durationMs: entry.durationMs ?? 0,
      // Playback reuses imported cards, but never creates a library placement.
      persist: false,
      mediaType: entry.kind == CloudDriveEntryKind.audio
          ? MediaType.audio
          : MediaType.video,
    );
  }

  Future<VideoItem> openEntry({
    required BuildContext context,
    required CloudDriveEntry entry,
    required List<CloudDriveEntry> visibleEntries,
    String? openedFromFolderId,
    Future<List<CloudDriveEntry>> Function()? loadNextPage,
    CloudDriveDirectorySession? directory,
    CloudDriveViewOptions options = const CloudDriveViewOptions(),
  }) async {
    final item = await prepareEntry(
      entry: entry,
      visibleEntries: visibleEntries,
      openedFromFolderId: openedFromFolderId,
      loadNextPage: loadNextPage,
      directory: directory,
      options: options,
    );
    if (!context.mounted) return item;
    final route = PlaybackNavigationService.buildPlaybackEntryRoute(item);
    unawaited(playback.play(item, userInitiatedWatch: true));
    await pushAboveMediaLibrary(context, route);
    return item;
  }

  Future<VideoItem> prepareEntry({
    required CloudDriveEntry entry,
    required List<CloudDriveEntry> visibleEntries,
    String? openedFromFolderId,
    Future<List<CloudDriveEntry>> Function()? loadNextPage,
    CloudDriveDirectorySession? directory,
    CloudDriveViewOptions options = const CloudDriveViewOptions(),
  }) async {
    final kind = entry.kind;
    final selected = await _card(entry, openedFromFolderId: openedFromFolderId);
    _directory?.release();
    _directory = directory;
    directory?.retain();
    final owner = Object();
    _owner = owner;
    final initial = directory != null && !directory.complete
        ? [entry]
        : visibleEntries;
    final cards = <VideoItem>[];
    final seen = <String>{};
    for (final file in initial) {
      if (file.kind == kind && seen.add(cloudDriveEntryKey(file))) {
        cards.add(
          cloudDriveEntryKey(file) == cloudDriveEntryKey(entry)
              ? selected
              : await _card(file, openedFromFolderId: openedFromFolderId),
        );
      }
    }
    if (!cards.any((v) => v.id == selected.id)) cards.add(selected);
    playlist.setPlaylist(cards, currentItemId: selected.id, owner: owner);
    Future<void>? preparing;
    var queueReady = directory == null || directory.complete;
    Future<void> prepare() async {
      if (!identical(playlist.queueOwner, owner) || directory == null) return;
      await directory.finish();
      if (!directory.complete) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.network,
          '目录尚未读取完整，请重试切集',
        );
      }
      final sorted = options
          .project(directory.entries)
          .where((e) => e.kind == kind);
      final complete = <VideoItem>[];
      for (final file in sorted) {
        complete.add(
          cloudDriveEntryKey(file) == cloudDriveEntryKey(entry)
              ? selected
              : await _card(file, openedFromFolderId: openedFromFolderId),
        );
      }
      if (!identical(playlist.queueOwner, owner)) return;
      final current = playback.currentItem;
      final anchor = current != null && complete.any((v) => v.id == current.id)
          ? current.id
          : selected.id;
      queueReady = true;
      playlist.setPlaylist(complete, currentItemId: anchor, owner: owner);
    }

    playback.cloudDriveQueueNeedsCompletion = () =>
        identical(playlist.queueOwner, owner) &&
        directory != null &&
        !queueReady;
    playback.cloudDrivePreparePlaylist = directory == null
        ? null
        : () => preparing ??= prepare().whenComplete(() => preparing = null);
    playback.cloudDriveLoadNextPlaylistPage =
        directory != null || loadNextPage == null
        ? null
        : () async {
            final more = await loadNextPage();
            if (!identical(playlist.queueOwner, owner)) {
              return const <VideoItem>[];
            }
            final next = <VideoItem>[];
            for (final file in more.where((e) => e.kind == kind)) {
              next.add(await _card(file));
            }
            if (identical(playlist.queueOwner, owner)) {
              playlist.appendPlaylistItems(next);
            }
            return next;
          };
    if (directory != null && !directory.complete) {
      unawaited(
        playback.cloudDrivePreparePlaylist!().catchError((Object _) {}),
      );
    }
    return selected;
  }
}

bool cloudDriveCardNeedsLogin(VideoItem item) =>
    isCloudDriveMedia(source: item.sourceRef, path: item.path);
