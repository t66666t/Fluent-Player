import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/relocate_local_media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory dataRoot;
  late Directory mediaRoot;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    dataRoot = await Directory.systemTemp.createTemp('relocate_data_');
    mediaRoot = await Directory.systemTemp.createTemp('relocate_media_');
    PathProviderPlatform.instance = _FakePathProvider(dataRoot.path);
    SettingsService().largeDataRootPath = dataRoot.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 4000;
    await library.init();
    RelocateLocalMediaSourceAction.pickPathOverrideForTesting = null;
    RelocateLocalMediaSourceAction.confirmOverrideForTesting = null;
  });

  tearDown(() async {
    RelocateLocalMediaSourceAction.pickPathOverrideForTesting = null;
    RelocateLocalMediaSourceAction.confirmOverrideForTesting = null;
    await MediaPlaybackService().stop();
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    if (await dataRoot.exists()) {
      await dataRoot.delete(recursive: true);
    }
    if (await mediaRoot.exists()) {
      await mediaRoot.delete(recursive: true);
    }
  });

  test('successful relocate keeps identity, activity, and subtitles', () async {
    final missingPath = p.join(mediaRoot.path, 'gone.mp4');
    final replacement = File(p.join(mediaRoot.path, 'found.mp4'));
    await replacement.writeAsBytes(List<int>.filled(48, 7));
    final subtitle = File(p.join(mediaRoot.path, 'keep.srt'));
    await subtitle.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHi\n');
    final playbackCopy = File(p.join(dataRoot.path, 'compat.mp4'));
    await playbackCopy.writeAsBytes(List<int>.filled(8, 1));

    library.seedCollectionForTesting(
      VideoCollection(id: 'folder', name: 'Course', createTime: 1),
    );
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: missingPath,
        playbackPath: playbackCopy.path,
        title: 'Lesson',
        durationMs: 10000,
        lastPositionMs: 2500,
        lastUpdated: 1,
        parentId: 'folder',
        subtitlePath: subtitle.path,
        managedSubtitleAssets: [
          ManagedSubtitleAsset(
            assetId: 'sub-1',
            path: subtitle.path,
            kind: ManagedSubtitleAssetKind.imported,
            displayName: 'keep.srt',
            createdAt: 1,
          ),
        ],
        hasProbedChapters: true,
      ),
    );
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'clip',
        addedAtMs: 111,
        lastPlayedAtMs: 222,
        hidden: true,
        completed: true,
      ),
    );
    await library.pinLibraryItem('clip');
    final batchId = library.beginImportBatch(
      title: 'Lesson',
      sourceKind: LibraryImportSourceKind.localFile,
      targetCollectionId: 'folder',
    );
    library.noteImportedMedia('clip', addedAtMs: 111, batchId: batchId);
    await library.completeImportBatch(batchId!);

    final result = await library.relocateLocalMediaSource(
      mediaId: 'clip',
      pickedPath: replacement.path,
    );

    expect(result.isSuccess, isTrue);
    expect(result.positionClamped, isFalse);
    final updated = library.getVideo('clip')!;
    expect(updated.id, 'clip');
    expect(updated.parentId, 'folder');
    expect(updated.path, replacement.path);
    expect(updated.playbackPath, isNull);
    expect(updated.subtitlePath, subtitle.path);
    expect(updated.managedSubtitleAssets.single.assetId, 'sub-1');
    expect(updated.lastPositionMs, 2500);
    expect(updated.durationMs, 4000);
    expect(updated.title, 'Lesson');
    expect(library.getVideo('clip-2'), isNull);
    expect(library.importBatches, hasLength(1));
    expect(library.importBatches.single.createdMediaIds, ['clip']);
    final activity = library.mediaActivity('clip')!;
    expect(activity.addedAtMs, 111);
    expect(activity.lastPlayedAtMs, 222);
    expect(activity.hidden, isTrue);
    expect(activity.completed, isTrue);
    expect(library.pinnedItemIds, ['clip']);
    expect(await playbackCopy.exists(), isFalse);
  });

  test('validation failures do not mutate the card', () async {
    final missingPath = p.join(mediaRoot.path, 'gone.mp4');
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: missingPath,
        title: 'Lesson',
        durationMs: 10000,
        lastPositionMs: 9000,
        lastUpdated: 1,
      ),
    );
    final snapshot = library.getVideo('clip')!;

    expect(
      (await library.relocateLocalMediaSource(
        mediaId: 'clip',
        pickedPath: p.join(mediaRoot.path, 'nope.mp4'),
      )).status,
      RelocateLocalMediaStatus.missingFile,
    );
    expect(library.getVideo('clip')!.path, snapshot.path);
    expect(library.getVideo('clip')!.lastPositionMs, 9000);

    final audio = File(p.join(mediaRoot.path, 'song.mp3'));
    await audio.writeAsBytes(List<int>.filled(16, 3));
    expect(
      (await library.relocateLocalMediaSource(
        mediaId: 'clip',
        pickedPath: audio.path,
      )).status,
      RelocateLocalMediaStatus.typeMismatch,
    );
    expect(library.getVideo('clip')!.path, snapshot.path);

    expect(
      (await library.relocateLocalMediaSource(
        mediaId: 'clip',
        pickedPath: p.join(mediaRoot.path, 'notes.txt'),
      )).status,
      RelocateLocalMediaStatus.unsupportedType,
    );
  });

  test('shorter duration clamps saved position', () async {
    library.probeMediaDurationOverrideForTesting = (_) => 3000;
    final replacement = File(p.join(mediaRoot.path, 'short.mp4'));
    await replacement.writeAsBytes(List<int>.filled(24, 2));
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: p.join(mediaRoot.path, 'gone.mp4'),
        title: 'Lesson',
        durationMs: 10000,
        lastPositionMs: 9000,
        lastUpdated: 1,
      ),
    );

    final result = await library.relocateLocalMediaSource(
      mediaId: 'clip',
      pickedPath: replacement.path,
    );
    expect(result.positionClamped, isTrue);
    expect(library.getVideo('clip')!.lastPositionMs, 2999);
    expect(library.getVideo('clip')!.durationMs, 3000);
  });

  test('online sources are not locally relocatable', () async {
    final stream = VideoItem(
      id: 'online',
      path: 'https://example.com/a.mp4',
      title: 'Online',
      durationMs: 1000,
      lastUpdated: 1,
      sourceRef: const MediaSourceRef(
        value: 'https://example.com/a.mp4',
        kind: MediaSourceKind.url,
      ),
    );
    library.seedVideoForTesting(stream);
    expect(library.canRelocateLocalMediaSource(stream), isFalse);
    expect(
      (await library.relocateLocalMediaSource(
        mediaId: 'online',
        pickedPath: p.join(mediaRoot.path, 'found.mp4'),
      )).status,
      RelocateLocalMediaStatus.onlineSource,
    );
    expect(library.getVideo('online')!.path, 'https://example.com/a.mp4');
  });

  test('late relocate of A does not replace playing B', () async {
    final replacement = File(p.join(mediaRoot.path, 'a-new.mp4'));
    await replacement.writeAsBytes(List<int>.filled(24, 4));
    library.seedVideoForTesting(
      VideoItem(
        id: 'a',
        path: p.join(mediaRoot.path, 'a-gone.mp4'),
        title: 'A',
        durationMs: 2000,
        lastUpdated: 1,
      ),
    );
    final itemB = VideoItem(
      id: 'b',
      path: p.join(mediaRoot.path, 'b-gone.mp4'),
      title: 'B',
      durationMs: 3000,
      lastUpdated: 1,
    );
    library.seedVideoForTesting(itemB);

    final playlist = PlaylistManager();
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
      libraryService: library,
    );
    playlist.setPlaylist(<VideoItem>[
      library.getVideo('a')!,
      itemB,
    ], startIndex: 1);
    await service.play(itemB);

    expect(service.currentItem?.id, 'b');
    expect(service.isSourceMissing, isTrue);

    final result = await library.relocateLocalMediaSource(
      mediaId: 'a',
      pickedPath: replacement.path,
    );
    expect(result.isSuccess, isTrue);
    await service.reloadAfterSourceRelocate(mediaId: 'a');

    expect(service.currentItem?.id, 'b');
    expect(service.isSourceMissing, isTrue);
    expect(library.getVideo('a')!.path, replacement.path);
  });

  testWidgets('cancel leaves the library untouched', (tester) async {
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: p.join(mediaRoot.path, 'gone.mp4'),
        title: 'Lesson',
        durationMs: 1000,
        lastUpdated: 1,
      ),
    );
    RelocateLocalMediaSourceAction.pickPathOverrideForTesting =
        ({required MediaType expectedType}) async => null;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => RelocateLocalMediaSourceAction.run(
                context,
                library.getVideo('clip')!,
              ),
              child: const Text('go'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(library.getVideo('clip')!.path, p.join(mediaRoot.path, 'gone.mp4'));
  });

  testWidgets('missing panel offers relocate only for local cards', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MissingLocalSourcePanel(
          item: VideoItem(
            id: 'url',
            path: 'https://example.com/a.mp4',
            title: 'Online',
            durationMs: 1,
            lastUpdated: 1,
            sourceRef: const MediaSourceRef(
              value: 'https://example.com/a.mp4',
              kind: MediaSourceKind.url,
            ),
          ),
        ),
      ),
    );
    expect(find.text('没有原媒体'), findsOneWidget);
    expect(find.text('重新定位文件'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: MissingLocalSourcePanel(
          item: VideoItem(
            id: 'local',
            path: p.join(mediaRoot.path, 'gone.mp4'),
            title: 'Local',
            durationMs: 1,
            lastUpdated: 1,
          ),
        ),
      ),
    );
    expect(find.text('文件找不到'), findsOneWidget);
    expect(find.text('重新定位文件'), findsOneWidget);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
