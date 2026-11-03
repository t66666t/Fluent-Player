import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/portable_transfer/zip_export_plan.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('zip export plan', () {
    late Directory tempDir;
    late LibraryService library;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('zip_export_plan_');
      library = LibraryService();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
    });

    tearDown(() async {
      library.resetLibraryForTesting();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('names cards, keeps folders, and disambiguates duplicates', () async {
      final folder = await library.createCollection('旅行', null);
      final kyoto = _file(tempDir, 'original-a.mp4');
      final osaka = _file(tempDir, 'original-b.mp4');
      final loose = _file(tempDir, 'disk-name.mkv');
      await _add(
        library,
        id: 'a',
        path: kyoto,
        title: '京都夜景',
        parentId: folder.id,
      );
      await _add(
        library,
        id: 'b',
        path: osaka,
        title: '京都夜景',
        parentId: folder.id,
      );
      await _add(library, id: 'c', path: loose, title: '首页视频', parentId: null);
      await _add(
        library,
        id: 'online',
        path: 'bilibili://stream/1',
        title: '在线',
        parentId: null,
        online: true,
      );

      final layout = buildZipExportLayout(
        library: library,
        rootIds: <String>[folder.id, 'c', 'online'],
        embedSubtitles: false,
        externalSubtitles: false,
        includeDanmaku: false,
        factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
      );

      expect(layout.skippedOnline, 1);
      expect(layout.media.map((item) => item.archivePath), <String>[
        '旅行/京都夜景.mp4',
        '旅行/京都夜景 (2).mp4',
        '首页视频.mkv',
      ]);
      expect(layout.media.every((item) => item.remux), isFalse);
    });

    test(
      'keeps folders only between items picked at different depths',
      () async {
        final level2 = await library.createCollection('第二层', null);
        final level3 = await library.createCollection('第三层', level2.id);
        await _add(
          library,
          id: 'l1',
          path: _file(tempDir, 'l1.mp4'),
          title: '第一层视频',
          parentId: null,
        );
        await _add(
          library,
          id: 'l2',
          path: _file(tempDir, 'l2.mp4'),
          title: '第二层视频',
          parentId: level2.id,
        );
        await _add(
          library,
          id: 'l3',
          path: _file(tempDir, 'l3.mp4'),
          title: '第三层视频',
          parentId: level3.id,
        );

        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['l1', 'l2', 'l3'],
          embedSubtitles: false,
          externalSubtitles: false,
          includeDanmaku: false,
          factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
        );

        expect(layout.media.map((item) => item.archivePath).toSet(), <String>{
          '第一层视频.mp4',
          '第二层/第二层视频.mp4',
          '第二层/第三层/第三层视频.mp4',
        });
      },
    );

    test('omits unused outer folders and skips a missing file', () async {
      final outer = await library.createCollection('外层', null);
      final inner = await library.createCollection('内层', outer.id);
      final kept = _file(tempDir, 'kept.mp4');
      await _add(
        library,
        id: 'kept',
        path: kept,
        title: '保留',
        parentId: inner.id,
      );
      await _add(
        library,
        id: 'missing',
        path: p.join(tempDir.path, 'nope.mp4'),
        title: '缺失',
        parentId: inner.id,
      );

      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['kept', 'missing'],
        embedSubtitles: false,
        externalSubtitles: false,
        includeDanmaku: false,
      );

      expect(layout.skippedMissing, 1);
      expect(layout.media.single.archivePath, '内层/保留.mp4');
    });

    test(
      'embeds associated subtitles and leaves styled tracks in mkv',
      () async {
        final video = _file(tempDir, 'source.mp4');
        final primary = _file(tempDir, 'primary.srt');
        final embedded = _file(tempDir, 'embedded.srt');
        final styled = _file(tempDir, 'styled.ass');
        final danmaku = _file(tempDir, 'danmaku.ass');
        await _add(
          library,
          id: 'clip',
          path: video,
          title: '讲座',
          parentId: null,
          subtitlePath: primary,
          managed: <ManagedSubtitleAsset>[
            ManagedSubtitleAsset(
              assetId: 'emb',
              path: embedded,
              kind: ManagedSubtitleAssetKind.embedded,
              displayName: '内嵌副本',
              createdAt: 1,
            ),
            ManagedSubtitleAsset(
              assetId: 'ass',
              path: styled,
              kind: ManagedSubtitleAssetKind.imported,
              displayName: '中文',
              language: 'zh',
              createdAt: 2,
            ),
          ],
          danmakuPath: danmaku,
        );

        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['clip'],
          embedSubtitles: true,
          externalSubtitles: false,
          includeDanmaku: true,
          factsFor: (_) => const ZipSourceFacts(
            hasAttachedCover: true,
            fileChapters: <MediaChapter>[],
          ),
        );
        final media = layout.media.single;
        expect(media.remux, isTrue);
        expect(media.archivePath, '讲座.mkv');
        expect(media.embedTracks.map((track) => track.title), <String>[
          '主字幕',
          '中文',
          '弹幕',
        ]);
        expect(media.embedTracks.last.isDefault, isFalse);
        expect(media.sidecars, isEmpty);

        final args = buildZipRemuxArguments(
          sourcePath: media.sourcePath,
          outputPath: 'out.mkv',
          tracks: media.embedTracks,
          coverPath: null,
          chapterMetadataPath: null,
          existingSubtitleStreams: 1,
          existingVideoStreams: 1,
          outputIsMp4Family: false,
          progressPipe: true,
        );
        expect(args, contains('copy'));
        expect(args, isNot(contains('libx264')));
        expect(args, isNot(contains('mov_text')));
        expect(args, contains('-c:s:1'));
        expect(args[args.indexOf('-disposition:s:3') + 1], '0');
      },
    );

    test('in-progress remux path keeps the container extension last', () {
      expect(
        zipInProgressRemuxPath(r'C:\scratch\0_0.mp4'),
        r'C:\scratch\0_0.partial.mp4',
      );
      expect(
        zipInProgressRemuxPath(r'C:\scratch\0_1.mkv'),
        r'C:\scratch\0_1.partial.mkv',
      );
      expect(p.extension(zipInProgressRemuxPath('/tmp/2_0.m4a')), '.m4a');
      expect(zipInProgressRemuxPath('noext'), 'noext.partial');
    });

    test(
      'plain subtitles stay in mp4 and chapters already in the file are kept',
      () async {
        final video = _file(tempDir, 'source.mp4');
        final primary = _file(tempDir, 'primary.srt');
        const chapters = <MediaChapter>[
          MediaChapter(title: '开场', startMs: 0, endMs: 1000),
        ];
        await _add(
          library,
          id: 'clip',
          path: video,
          title: '课',
          parentId: null,
          subtitlePath: primary,
          chapters: chapters,
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['clip'],
          embedSubtitles: true,
          externalSubtitles: false,
          includeDanmaku: false,
          factsFor: (_) => const ZipSourceFacts(
            hasAttachedCover: true,
            fileChapters: chapters,
          ),
        );
        final media = layout.media.single;
        expect(media.archivePath, '课.mp4');
        expect(media.replacementChapters, isNull);
        expect(media.embedTracks.single.isDefault, isTrue);
      },
    );

    test(
      'writes app chapters and a cover only when the file does not have them',
      () async {
        final video = _file(tempDir, 'song.m4a');
        final cover = _file(tempDir, 'cover.jpg');
        await _add(
          library,
          id: 'song',
          path: video,
          title: '歌',
          parentId: null,
          thumbnailPath: cover,
          chapters: const <MediaChapter>[
            MediaChapter(title: '副歌', startMs: 5000, endMs: 8000),
          ],
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['song'],
          embedSubtitles: false,
          externalSubtitles: false,
          includeDanmaku: false,
          factsFor: (_) => const ZipSourceFacts(
            hasAttachedCover: false,
            videoStreamCount: 0,
            fileChapters: <MediaChapter>[],
          ),
        );
        final media = layout.media.single;
        expect(media.remux, isTrue);
        expect(media.coverPath, cover);
        expect(media.replacementChapters, isNotNull);
        expect(media.archivePath, '歌.m4a');
      },
    );

    test(
      'external subtitles sit beside the video and danmaku stays named',
      () async {
        final video = _file(tempDir, 'source.mp4');
        final zh = _file(tempDir, 'zh.srt');
        final en = _file(tempDir, 'en.vtt');
        final danmaku = _file(tempDir, 'dm.ass');
        await _add(
          library,
          id: 'clip',
          path: video,
          title: '对话',
          parentId: null,
          subtitlePath: zh,
          secondarySubtitlePath: en,
          danmakuPath: danmaku,
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['clip'],
          embedSubtitles: false,
          externalSubtitles: true,
          includeDanmaku: true,
          factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
        );
        final media = layout.media.single;
        expect(media.remux, isFalse);
        expect(media.embedTracks, isEmpty);
        expect(media.sidecars.map((item) => item.archivePath), <String>[
          '对话.主字幕.srt',
          '对话.副字幕.vtt',
          '对话.弹幕.ass',
        ]);
      },
    );

    test(
      'embeds subtitles and also writes the same files beside the video',
      () async {
        final video = _file(tempDir, 'both.mp4');
        final primary = _file(tempDir, 'both.srt');
        await _add(
          library,
          id: 'both',
          path: video,
          title: '双语',
          parentId: null,
          subtitlePath: primary,
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: const <String>['both'],
          embedSubtitles: true,
          externalSubtitles: true,
          includeDanmaku: false,
          factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
        );
        final media = layout.media.single;
        expect(media.remux, isTrue);
        expect(media.archivePath, '双语.mp4');
        expect(media.embedTracks.single.path, primary);
        expect(media.sidecars.single.archivePath, '双语.srt');
      },
    );

    test('retries the full remux once, then subtitles only, then stops', () {
      const full = ZipRemuxPlan(
        tracks: <ZipSubtitleTrack>[
          ZipSubtitleTrack(
            path: 'a.srt',
            title: '主字幕',
            language: null,
            isDefault: true,
            isDanmaku: false,
          ),
        ],
        includeCover: true,
        includeChapters: true,
      );
      expect(zipRemuxAttemptAfterFailures(full, 1)!.includeCover, isTrue);
      final third = zipRemuxAttemptAfterFailures(full, 2)!;
      expect(third.includeCover, isFalse);
      expect(third.includeChapters, isFalse);
      expect(third.tracks, isNotEmpty);
      expect(zipRemuxAttemptAfterFailures(full, 3), isNull);
      expect(zipRemuxAttemptAfterFailures(full.withoutExtras(), 2), isNull);
    });

    test('sanitizes names and reads ffmpeg progress', () {
      expect(sanitizeZipName('a:b/c'), 'a b c');
      expect(sanitizeZipName('CON'), '_CON');
      expect(sanitizeZipName('   '), '未命名');
      expect(zipFfmpegProgressFraction('out_time_ms=2500000', 5000), 0.5);
      expect(
        buildZipExportSummary(
          mediaCount: 2,
          outputBytes: 2048,
          skippedOnline: 1,
          skippedMissing: 0,
          sidecarFallbacks: 1,
          keptOriginals: 0,
          droppedExtras: 0,
        ),
        '2 个媒体 · 2.0 KB · 已跳过 1 个在线卡片 · 1 个改为外挂字幕',
      );
    });

    test(
      'podcast channel exports a card reference without downloaded episodes',
      () async {
        final channel = await library.createCollection('播客', null);
        await _add(
          library,
          id: 'download',
          path: _file(tempDir, 'private.mp3'),
          title: '已缓存节目',
          parentId: channel.id,
        );
        channel.podcastRef = const PodcastChannelRef(
          channelId: 'channel',
          feedUrl: 'https://example.com/feed.xml',
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: [channel.id],
          embedSubtitles: true,
          externalSubtitles: true,
          includeDanmaku: true,
        );
        expect(layout.isEmpty, isFalse);
        expect(layout.media, isEmpty);
        expect(layout.references.map((entry) => entry.archivePath), [
          '播客.url',
          zipPodcastReferencesPath,
        ]);
        final snapshot =
            (jsonDecode(layout.references.last.contents) as Map)['snapshot']
                as Map;
        expect(snapshot['videos'], isEmpty);
        expect(
          (snapshot['collections'] as List).single['podcastRef']['channelId'],
          'channel',
        );
        expect((snapshot['podcasts'] as List).single['episodes'], isEmpty);
        expect(layout.references.last.contents, isNot(contains(tempDir.path)));
      },
    );

    test(
      'individual podcast episodes export only selected reference records',
      () async {
        final channel = await library.createCollection('播客', null);
        for (final id in ['one', 'two']) {
          await _add(
            library,
            id: id,
            path: _file(tempDir, '$id.mp3'),
            title: id,
            parentId: channel.id,
          );
          final item = library.getVideo(id)!;
          item.sourceRef = MediaSourceRef(
            value: 'https://example.com/$id.mp3',
            kind: MediaSourceKind.podcastEpisode,
            podcast: PodcastEpisodeRef(
              channelId: 'channel',
              episodeId: id,
              feedUrl: 'https://example.com/feed.xml',
              mediaUrl: 'https://example.com/$id.mp3',
            ),
          );
          item.playbackPath = item.path;
          item.subtitlePath = _file(tempDir, '$id.srt');
          await library.moveItemToCollection(id, channel.id);
        }
        channel.podcastRef = const PodcastChannelRef(
          channelId: 'channel',
          feedUrl: 'https://example.com/feed.xml',
        );
        final draft = enumerateZipCandidates(
          library: library,
          rootIds: ['one', 'two'],
        );
        expect(draft.candidates, isEmpty);
        expect(draft.referenceCount, 2);
        final snapshot =
            (jsonDecode(draft.references.last.contents) as Map)['snapshot']
                as Map;
        expect(
          (snapshot['collections'] as List).single['exportId'],
          channel.id,
        );
        expect((snapshot['videos'] as List).length, 2);
        expect((snapshot['podcasts'] as List).single['episodes'].length, 2);
        expect(
          draft.references.last.contents,
          isNot(contains(tempDir.path.replaceAll(r'\', r'\\'))),
        );
        for (final record in snapshot['videos'] as List) {
          expect(record['video']['playbackPath'], isNull);
          expect(record['video']['subtitlePath'], isNull);
        }
      },
    );

    test(
      'uncached cloud media blocks export instead of being silently skipped',
      () async {
        const source = CloudDriveSourceRef(
          providerId: 'quark',
          remoteAccountId: 'account',
          driveId: 'drive',
          fileId: 'file',
        );
        await _add(
          library,
          id: 'cloud',
          path: source.logicalUri,
          title: '网盘视频',
          parentId: null,
        );
        library.getVideo('cloud')!.sourceRef = MediaSourceRef(
          value: source.logicalUri,
          kind: MediaSourceKind.cloudDrive,
          cloudDrive: source,
        );
        expect(
          () => enumerateZipCandidates(library: library, rootIds: ['cloud']),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('完整缓存'),
            ),
          ),
        );
      },
    );

    test(
      'cover-only remux failure cannot add subtitles the user excluded',
      () async {
        await _add(
          library,
          id: 'clip',
          path: _file(tempDir, 'source.mp4'),
          title: '仅封面',
          parentId: null,
          thumbnailPath: _file(tempDir, 'cover.jpg'),
          subtitlePath: _file(tempDir, 'private.srt'),
        );
        final layout = buildZipExportLayout(
          library: library,
          rootIds: ['clip'],
          embedSubtitles: false,
          externalSubtitles: false,
          includeDanmaku: false,
        );
        expect(layout.media.single.remux, isTrue);
        expect(layout.media.single.fallbackTracks, isEmpty);
        expect(
          buildZipFallbackSidecars(
            media: layout.media.single,
            videoArchivePath: '仅封面.mp4',
            names: layout.names,
          ),
          isEmpty,
        );
      },
    );

    test(
      'an imported local cloud file can be exported again without a registry cache',
      () async {
        const source = CloudDriveSourceRef(
          providerId: 'quark',
          remoteAccountId: 'account',
          driveId: 'drive',
          fileId: 'file',
        );
        final path = _file(tempDir, 'imported-cloud.mp4');
        await _add(
          library,
          id: 'cloud-local',
          path: path,
          title: '网盘导入',
          parentId: null,
        );
        library.getVideo('cloud-local')!.sourceRef = MediaSourceRef(
          value: source.logicalUri,
          kind: MediaSourceKind.cloudDrive,
          cloudDrive: source,
        );
        final draft = enumerateZipCandidates(
          library: library,
          rootIds: ['cloud-local'],
        );
        expect(draft.candidates.single.sourcePath, path);
        expect(draft.skippedOnline, 0);
        library.getVideo('cloud-local')!.path = source.logicalUri;
        library.getVideo('cloud-local')!.playbackPath = path;
        expect(
          () => enumerateZipCandidates(
            library: library,
            rootIds: ['cloud-local'],
          ),
          throwsStateError,
        );
      },
    );

    test(
      'podcast references preserve actual enclosing archive folder paths',
      () async {
        final folder = await library.createCollection('文件夹', null);
        final nested = await library.createCollection('订阅', folder.id);
        nested.podcastRef = const PodcastChannelRef(
          channelId: 'channel',
          feedUrl: 'https://example.com/feed.xml',
        );
        await _add(
          library,
          id: 'local',
          path: _file(tempDir, 'video.mp4'),
          title: '本地',
          parentId: folder.id,
        );
        final draft = enumerateZipCandidates(
          library: library,
          rootIds: [folder.id],
        );
        expect(draft.referenceCount, 1);
        expect(draft.references.first.archivePath, '文件夹/订阅.url');
        final snapshot =
            (jsonDecode(draft.references.last.contents) as Map)['snapshot']
                as Map;
        final records = (snapshot['collections'] as List).cast<Map>();
        expect(
          records.singleWhere(
            (record) => record['exportId'] == nested.id,
          )['parentExportId'],
          folder.id,
        );
        expect(
          records.singleWhere(
            (record) => record['exportId'] == folder.id,
          )['archiveDirectory'],
          '文件夹',
        );
        expect(
          records.singleWhere(
            (record) => record['exportId'] == folder.id,
          )['parentExportId'],
          isNull,
        );
      },
    );

    test(
      'missing selected SRT and ASS are counted once and excluded payload stays quiet',
      () async {
        final missingSrt = p.join(tempDir.path, 'missing.srt');
        final missingAss = p.join(tempDir.path, 'missing.ass');
        final embeddedCopy = p.join(tempDir.path, 'embedded.srt');
        final availableSrt = _file(tempDir, 'available.srt');
        await _add(
          library,
          id: 'missing-sidecars',
          path: _file(tempDir, 'source.mp4'),
          title: '缺失附件',
          parentId: null,
          subtitlePath: missingSrt,
          secondarySubtitlePath: embeddedCopy,
          danmakuPath: missingAss,
          managed: [
            ManagedSubtitleAsset(
              assetId: 'missing',
              path: missingSrt,
              kind: ManagedSubtitleAssetKind.imported,
              displayName: 'missing',
              createdAt: 1,
            ),
            ManagedSubtitleAsset(
              assetId: 'available',
              path: availableSrt,
              wordTimingPath: p.join(tempDir.path, 'optional.words.json'),
              kind: ManagedSubtitleAssetKind.ai,
              displayName: 'available',
              createdAt: 1,
            ),
            ManagedSubtitleAsset(
              assetId: 'embedded',
              path: embeddedCopy,
              kind: ManagedSubtitleAssetKind.embedded,
              displayName: 'embedded',
              createdAt: 1,
            ),
          ],
        );
        ZipResolvedMedia planned({
          required bool subtitles,
          required bool danmaku,
        }) => buildZipExportLayout(
          library: library,
          rootIds: ['missing-sidecars'],
          embedSubtitles: subtitles,
          externalSubtitles: false,
          includeDanmaku: danmaku,
        ).media.single;
        final full = planned(subtitles: true, danmaku: true);
        expect(full.missingSidecars, 2);
        expect(full.embedTracks.single.path, availableSrt);
        expect(planned(subtitles: true, danmaku: false).missingSidecars, 1);
        expect(planned(subtitles: false, danmaku: true).missingSidecars, 1);
        expect(planned(subtitles: false, danmaku: false).missingSidecars, 0);
      },
    );
  });
}

String _file(Directory directory, String name) {
  final file = File(p.join(directory.path, name));
  file.writeAsStringSync('x');
  return file.path;
}

Future<void> _add(
  LibraryService library, {
  required String id,
  required String path,
  required String title,
  required String? parentId,
  bool online = false,
  String? subtitlePath,
  String? secondarySubtitlePath,
  String? danmakuPath,
  String? thumbnailPath,
  List<ManagedSubtitleAsset> managed = const <ManagedSubtitleAsset>[],
  List<MediaChapter> chapters = const <MediaChapter>[],
}) async {
  library.seedVideoForTesting(
    VideoItem(
      id: id,
      path: path,
      title: title,
      durationMs: 1000,
      lastUpdated: 1,
      parentId: 'pending',
      hasProbedChapters: true,
      subtitlePath: subtitlePath,
      secondarySubtitlePath: secondarySubtitlePath,
      danmakuPath: danmakuPath,
      thumbnailPath: thumbnailPath,
      managedSubtitleAssets: managed,
      chapters: chapters,
      sourceRef: online
          ? const MediaSourceRef(
              value: 'bv',
              kind: MediaSourceKind.bilibiliStream,
            )
          : null,
    ),
  );
  await library.moveItemToCollection(id, parentId);
}
