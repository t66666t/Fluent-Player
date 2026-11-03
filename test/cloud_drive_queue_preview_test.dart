import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_thumbnails.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/cached_thumbnail_widget.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';
import 'support/cloud_drive_fixture.dart';

class _Previews extends CloudDriveThumbnails {
  _Previews(CloudDriveRuntime runtime)
    : super(
        providers: runtime.providers,
        accounts: runtime.accounts,
        root: Directory.systemTemp,
      );
  final detail = Completer<CloudDriveEntry?>();
  final cover = Completer<String?>();
  int detailCalls = 0;
  int coverCalls = 0;
  @override
  Future<CloudDriveEntry?> metadata(
    CloudDriveSourceRef source, {
    bool refresh = false,
  }) {
    detailCalls++;
    return detail.future;
  }

  @override
  Future<String?> ensure(CloudDriveSourceRef source) {
    coverCalls++;
    return cover.future;
  }
}

void main() {
  for (final panel in [true, false]) {
    testWidgets(
      '${panel ? 'episode picker' : 'mini playlist'} hydrates unplayed cloud rows',
      (tester) async {
        final runtime = await cloudRuntime([FixtureCloudProvider('baidu', {})]);
        final library = runtime.launch.library;
        final previews = _Previews(runtime);
        library.cloudDriveThumbnails = previews;
        final playback = MediaPlaybackService();
        final entry = cloudEntry('unplayed', name: '未播放的下一集.mp4');
        final source = cloudDriveEntrySource(entry);
        final item = VideoItem(
          id: 'alias',
          path: source.cloudDrive!.logicalUri,
          title: '自定义名称',
          durationMs: 0,
          lastUpdated: 0,
          sourceRef: source,
        );
        final playlist = runtime.launch.playlist;
        playlist.setPlaylist([item], currentItemId: item.id);
        Directory? temporary;
        await tester.runAsync(() async {
          temporary = await Directory.systemTemp.createTemp('queue_preview');
          await File('${temporary!.path}/cover.png').writeAsBytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
            ),
          );
        });
        addTearDown(() async {
          library.cloudDriveThumbnails = null;
          await runtime.shutdown();
          library.resetLibraryForTesting();
          await temporary?.delete(recursive: true);
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
              ChangeNotifierProvider<PlaylistManager>.value(value: playlist),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 500,
                  height: 500,
                  child: panel
                      ? EpisodePickerPanel(
                          panelWidth: 500,
                          panelHeight: 500,
                          onClose: () {},
                        )
                      : PlaylistBottomSheet(
                          playlist: [item],
                          currentItemId: item.id,
                          onItemTap: (_) {},
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('时长未知'), findsOneWidget);
        expect(find.text('00:00'), findsNothing);
        previews.detail.complete(entry);
        await tester.pump();
        await tester.pump();
        expect(find.text('02:00'), findsOneWidget);
        expect(item.thumbnailPath, isNull);
        previews.cover.complete('${temporary!.path}/cover.png');
        await tester.pump();
        await tester.pump();
        expect(find.text('02:00'), findsOneWidget);
        expect(item.durationMs, 120000);
        expect(item.title, '自定义名称');
        expect(library.storageVideos, isEmpty);
        expect(
          tester
              .widget<CachedThumbnailWidget>(find.byType(CachedThumbnailWidget))
              .thumbnailPath,
          '${temporary!.path}/cover.png',
        );
        await tester.pump();
        expect(previews.detailCalls, 1);
        expect(previews.coverCalls, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
