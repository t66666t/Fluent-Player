import 'dart:io';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/portable_transfer/zip_media_exporter.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'zip export byte-copies a card title and leaves no scratch files',
    () async {
      final originalProvider = PathProviderPlatform.instance;
      final root = await Directory.systemTemp.createTemp('zip_export_run_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = originalProvider;
        if (await root.exists()) await root.delete(recursive: true);
      });

      final library = LibraryService();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(library.resetLibraryForTesting);
      final media = File(p.join(root.path, 'disk-name.mp4'));
      await media.writeAsString('video-bytes');
      library.seedVideoForTesting(
        VideoItem(
          id: 'clip',
          path: media.path,
          title: '卡片名',
          durationMs: 1000,
          lastUpdated: 1,
          parentId: 'pending',
          hasProbedChapters: true,
        ),
      );
      await library.moveItemToCollection('clip', null);

      final service = PortableTransferService.forTesting();
      final output = p.join(root.path, 'out.zip');
      final task = await service.exportSelection(
        library: library,
        rootIds: const <String>['clip'],
        outputPath: output,
        options: const PortableExportOptions(
          packageName: '我的导出',
          format: PortableExportFormat.zip,
          zipEmbedSubtitles: false,
          zipExternalSubtitles: false,
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (task.isActive && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(task.status, PortableTransferStatus.completed, reason: task.error);
      final archive = ZipDecoder().decodeBytes(
        await File(output).readAsBytes(),
      );
      expect(archive.files.map((file) => file.name), contains('卡片名.mp4'));
      expect(archive.files.single.content, 'video-bytes'.codeUnits);
      expect(
        await Directory(
          p.join(root.path, zipExportScratchDirectoryName),
        ).exists(),
        isFalse,
      );
      expect(await File('$output.part').exists(), isFalse);
    },
  );

  test(
    'retired reference-only podcast selections cannot create a media ZIP',
    () async {
      final originalProvider = PathProviderPlatform.instance;
      final root = await Directory.systemTemp.createTemp('zip_podcast_run_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      final library = LibraryService()
        ..writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(() async {
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = originalProvider;
        await root.delete(recursive: true);
      });
      final card = await library.createCollection('节目订阅', null);
      card.podcastRef = const PodcastChannelRef(
        channelId: 'channel',
        feedUrl: 'https://example.com/feed.xml',
      );
      final output = File(p.join(root.path, 'references.zip'));
      await expectLater(
        ZipMediaExporter().run(
          library: library,
          rootIds: [card.id],
          partialPath: output.path,
          options: const PortableExportOptions(
            packageName: 'Retired',
            format: PortableExportFormat.zip,
          ),
          taskId: 'reference-only',
          isCancelled: () => false,
          onProgress: (_, _, _, _) {},
        ),
        throwsStateError,
      );
      expect(await output.exists(), isFalse);
    },
  );

  test(
    'ZIP result reports missing selected subtitle and danmaku without dropping the media',
    () async {
      final originalProvider = PathProviderPlatform.instance;
      final root = await Directory.systemTemp.createTemp(
        'zip_missing_sidecars_',
      );
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      final library = LibraryService()
        ..writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(() async {
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = originalProvider;
        await root.delete(recursive: true);
      });
      final media = File(p.join(root.path, 'source.mp4'));
      await media.writeAsString('original-media');
      library.seedVideoForTesting(
        VideoItem(
          id: 'clip',
          path: media.path,
          title: '视频',
          durationMs: 1000,
          lastUpdated: 1,
          parentId: 'pending',
          hasProbedChapters: true,
          subtitlePath: p.join(root.path, 'missing.srt'),
          danmakuPath: p.join(root.path, 'missing.ass'),
        ),
      );
      await library.moveItemToCollection('clip', null);
      final output = File(p.join(root.path, 'missing.zip'));
      final result = await ZipMediaExporter().run(
        library: library,
        rootIds: ['clip'],
        partialPath: output.path,
        options: const PortableExportOptions(
          packageName: '缺失附件',
          format: PortableExportFormat.zip,
          zipEmbedSubtitles: true,
          zipExternalSubtitles: false,
          includeDanmaku: true,
        ),
        taskId: 'missing-sidecars',
        isCancelled: () => false,
        onProgress: (_, _, _, _) {},
      );
      expect(result.missingSidecars, 2);
      expect(
        result.summary(await output.length()),
        contains('2 个字幕或弹幕文件缺失，未打包'),
      );
      final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
      expect(archive.files.single.name, '视频.mp4');
      expect(utf8.decode(archive.files.single.content), 'original-media');
    },
  );

  for (final (includeDanmaku, existingTimedText) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    test(
      'native ZIP embeds SRT${includeDanmaku ? ' and moving ASS danmaku in MKV' : ' in MP4'}${existingTimedText ? ' retaining existing MP4 timed text' : ''} without reencoding video',
      () async {
        final originalProvider = PathProviderPlatform.instance;
        final root = await Directory.systemTemp.createTemp('zip_native_run_');
        PathProviderPlatform.instance = _FakePathProvider(root.path);
        final library = LibraryService()
          ..writeLibrarySnapshotOverrideForTesting = () async {};
        addTearDown(() async {
          library.resetLibraryForTesting();
          PathProviderPlatform.instance = originalProvider;
          await root.delete(recursive: true);
        });
        final ffmpeg = await FFmpegUtils.ffmpegPath;
        final ffprobe = await FFmpegUtils.ffprobePath;
        if (!await _nativeToolsAvailable(ffmpeg, ffprobe)) {
          markTestSkipped('Native export requires ffmpeg and ffprobe');
          return;
        }
        var source = File(p.join(root.path, 'source.mp4'));
        await _run(ffmpeg, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=black:s=160x90:r=10:d=1',
          '-an',
          '-c:v',
          'mpeg4',
          '-q:v',
          '5',
          source.path,
        ]);
        final subtitle = File(p.join(root.path, 'primary.srt'));
        await subtitle.writeAsString(
          '1\n00:00:00,100 --> 00:00:00,900\nSubtitle marker\n',
        );
        if (existingTimedText) {
          final existing = File(p.join(root.path, 'existing.srt'));
          await existing.writeAsString(
            '1\n00:00:00,100 --> 00:00:00,900\nExisting marker\n',
          );
          final timedSource = File(p.join(root.path, 'timed-source.mp4'));
          await _run(ffmpeg, [
            '-v',
            'error',
            '-y',
            '-i',
            source.path,
            '-i',
            existing.path,
            '-map',
            '0',
            '-map',
            '1:0',
            '-c',
            'copy',
            '-c:s',
            'mov_text',
            '-metadata:s:s:0',
            'handler_name=原有字幕',
            timedSource.path,
          ]);
          source = timedSource;
        }
        final danmaku = File(p.join(root.path, 'danmaku.ass'));
        await danmaku.writeAsString(_movingAss);
        library.seedVideoForTesting(
          VideoItem(
            id: 'clip',
            path: source.path,
            title: 'Native clip',
            durationMs: 1000,
            lastUpdated: 1,
            parentId: 'pending',
            hasProbedChapters: true,
            subtitlePath: subtitle.path,
            danmakuPath: includeDanmaku ? danmaku.path : null,
          ),
        );
        await library.moveItemToCollection('clip', null);
        final output = File(p.join(root.path, 'native.zip'));
        final result = await ZipMediaExporter().run(
          library: library,
          rootIds: ['clip'],
          partialPath: output.path,
          options: PortableExportOptions(
            packageName: 'Native export',
            format: PortableExportFormat.zip,
            zipEmbedSubtitles: true,
            zipExternalSubtitles: false,
            includeDanmaku: includeDanmaku,
          ),
          taskId: 'native-$includeDanmaku',
          isCancelled: () => false,
          onProgress: (_, _, _, _) {},
        );
        expect(result.sidecarFallbacks, 0);
        expect(result.keptOriginals, 0);
        final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
        final entry = archive.files.single;
        expect(entry.name, 'Native clip.${includeDanmaku ? 'mkv' : 'mp4'}');
        final exported = File(p.join(root.path, entry.name));
        await exported.writeAsBytes(entry.content);
        final probe = await _run(ffprobe, [
          '-v',
          'error',
          '-show_streams',
          '-of',
          'json',
          exported.path,
        ]);
        final streams =
            (jsonDecode(probe.stdout.toString()) as Map)['streams'] as List;
        expect(
          streams
              .where((stream) => stream['codec_type'] == 'video')
              .single['codec_name'],
          'mpeg4',
        );
        final subtitles = streams
            .where((stream) => stream['codec_type'] == 'subtitle')
            .toList();
        expect(
          subtitles.length,
          (includeDanmaku ? 2 : 1) + (existingTimedText ? 1 : 0),
        );
        expect(
          subtitles[existingTimedText ? 1 : 0]['codec_name'],
          includeDanmaku ? 'subrip' : 'mov_text',
        );
        final extracted = await _run(ffmpeg, [
          '-v',
          'error',
          '-i',
          exported.path,
          '-map',
          '0:s:${existingTimedText ? 1 : 0}',
          '-f',
          'srt',
          '-',
        ]);
        expect(extracted.stdout.toString(), contains('Subtitle marker'));
        if (existingTimedText) {
          expect(subtitles.first['codec_name'], 'subrip');
          expect((subtitles.first['tags'] as Map).values, contains('原有字幕'));
          final existing = await _run(ffmpeg, [
            '-v',
            'error',
            '-i',
            exported.path,
            '-map',
            '0:s:0',
            '-f',
            'srt',
            '-',
          ]);
          expect(existing.stdout.toString(), contains('Existing marker'));
        }
        if (includeDanmaku) {
          expect(subtitles.last['codec_name'], 'ass');
          expect(subtitles.last['tags']['title'], '弹幕');
          final extractedAss = await _run(ffmpeg, [
            '-v',
            'error',
            '-i',
            exported.path,
            '-map',
            '0:s:${existingTimedText ? 2 : 1}',
            '-c:s',
            'copy',
            '-f',
            'ass',
            '-',
          ]);
          expect(
            extractedAss.stdout.toString(),
            contains(r'{\move(0,20,320,20)}Danmaku marker'),
          );
        }
        final originalHash = await _run(ffmpeg, [
          '-v',
          'error',
          '-i',
          source.path,
          '-map',
          '0:v:0',
          '-c:v',
          'copy',
          '-f',
          'hash',
          '-hash',
          'sha256',
          '-',
        ]);
        final exportedHash = await _run(ffmpeg, [
          '-v',
          'error',
          '-i',
          exported.path,
          '-map',
          '0:v:0',
          '-c:v',
          'copy',
          '-f',
          'hash',
          '-hash',
          'sha256',
          '-',
        ]);
        expect(
          exportedHash.stdout.toString().trim(),
          originalHash.stdout.toString().trim(),
        );
      },
      skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux),
    );
  }

  test(
    'native audio with styled subtitles exports as MKA and remains audio',
    () async {
      final originalProvider = PathProviderPlatform.instance;
      final root = await Directory.systemTemp.createTemp('zip_native_audio_');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      final library = LibraryService()
        ..writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(() async {
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = originalProvider;
        await root.delete(recursive: true);
      });
      final ffmpeg = await FFmpegUtils.ffmpegPath;
      final ffprobe = await FFmpegUtils.ffprobePath;
      if (!await _nativeToolsAvailable(ffmpeg, ffprobe)) {
        markTestSkipped('Native export requires ffmpeg and ffprobe');
        return;
      }
      final source = File(p.join(root.path, 'audio.m4a'));
      await _run(ffmpeg, [
        '-v',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:a',
        'aac',
        source.path,
      ]);
      final subtitle = File(p.join(root.path, 'lyrics.ass'));
      await subtitle.writeAsString(_movingAss);
      library.seedVideoForTesting(
        VideoItem(
          id: 'audio',
          path: source.path,
          title: '音频',
          type: MediaType.audio,
          durationMs: 1000,
          lastUpdated: 1,
          parentId: 'pending',
          subtitlePath: subtitle.path,
          hasProbedChapters: true,
        ),
      );
      await library.moveItemToCollection('audio', null);
      final output = File(p.join(root.path, 'audio.zip'));
      final result = await ZipMediaExporter().run(
        library: library,
        rootIds: ['audio'],
        partialPath: output.path,
        options: const PortableExportOptions(
          packageName: '音频',
          format: PortableExportFormat.zip,
          zipEmbedSubtitles: true,
          zipExternalSubtitles: false,
        ),
        taskId: 'native-audio',
        isCancelled: () => false,
        onProgress: (_, _, _, _) {},
      );
      expect(result.sidecarFallbacks, 0);
      final entry = ZipDecoder()
          .decodeBytes(await output.readAsBytes())
          .files
          .single;
      expect(entry.name, '音频.mka');
      expect(
        LibraryService.supportedAudioExtensions,
        contains(p.extension(entry.name)),
      );
      final exported = File(p.join(root.path, entry.name));
      await exported.writeAsBytes(entry.content);
      final probe = await _run(ffprobe, [
        '-v',
        'error',
        '-show_streams',
        '-of',
        'json',
        exported.path,
      ]);
      final streams =
          (jsonDecode(probe.stdout.toString()) as Map)['streams'] as List;
      expect(streams.map((stream) => stream['codec_type']), [
        'audio',
        'subtitle',
      ]);
      expect(streams.first['codec_name'], 'aac');
      expect(streams.last['codec_name'], 'ass');
    },
    skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux),
  );
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(
    executable,
    arguments,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '$executable failed: ${result.stderr}');
  return result;
}

Future<bool> _nativeToolsAvailable(String ffmpeg, String ffprobe) async {
  try {
    for (final executable in [ffmpeg, ffprobe]) {
      final result = await Process.run(
        executable,
        ['-version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

const _movingAss = r'''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.10,0:00:00.90,Default,,0,0,0,,{\move(0,20,320,20)}Danmaku marker
''';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
