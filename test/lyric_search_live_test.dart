import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/lyrics/lyric_search_models.dart';
import 'package:video_player_app/features/lyrics/lyric_media_metadata.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/features/lyrics/lyric_search_service.dart';

void main() {
  test(
    'real local media artist/title tags feed lyric metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lyric_metadata_live_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final path = '${root.path}/tagged.wav';
      final result = await Process.run(await FFmpegUtils.ffmpegPath, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=8000:cl=mono',
        '-t',
        '1',
        '-metadata',
        'title=Tagged Song',
        '-metadata',
        'artist=Tagged Artist',
        '-metadata',
        'album=Test Album',
        path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final metadata = await LyricMediaMetadataProbe.probe(path);
      expect(metadata.title, 'Tagged Song');
      expect(metadata.artist, 'Tagged Artist');
    },
    skip: Platform.environment['LYRIC_SEARCH_LIVE'] != '1',
  );
  // Opt in explicitly; deterministic tests never depend on third-party uptime.
  test(
    'live providers return real synchronized lyrics',
    () async {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 12),
          headers: {'User-Agent': 'FluentPlayer/1.0 (lyrics search)'},
        ),
      );
      final service = LyricSearchService(dio: dio);
      addTearDown(() => dio.close(force: true));
      final results = await service.search(
        'Counting Stars OneRepublic',
        artist: 'OneRepublic',
        mediaDuration: const Duration(milliseconds: 256946),
      );
      for (final source in LyricSource.values) {
        final matches = results.tracks
            .where((t) => t.source == source)
            .toList();
        expect(
          matches,
          isNotEmpty,
          reason: '${source.label}: ${results.errors[source]}',
        );
        final lyrics = await service.fetch(matches.first);
        expect(lyrics.original.length, greaterThan(10));
        expect(
          lyrics.original.every((cue) => cue.endTime > cue.startTime),
          isTrue,
        );
        if (source == LyricSource.netease) {
          expect(lyrics.hasWordTiming, isTrue);
          expect(lyrics.hasChineseTranslation, isTrue);
        }
        // Report metadata only, without recording provider lyric content.
        // ignore: avoid_print
        print(
          '${source.label}: ${matches.length} matches, ${lyrics.original.length} lines, '
          'wordTiming=${lyrics.hasWordTiming}, Chinese=${lyrics.hasChineseTranslation}',
        );
      }
    },
    skip: Platform.environment['LYRIC_SEARCH_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
