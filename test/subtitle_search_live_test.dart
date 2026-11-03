import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_batch_matcher.dart';

void main() {
  // Opt-in smoke check: no API keys, login, media uploads, or subtitle text in logs.
  test(
    'public providers search and download readable subtitles without credentials',
    () async {
      final dio = Dio(
        BaseOptions(
          headers: {'User-Agent': 'FluentPlayer v1.0'},
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final service = SubtitleSearchService(dio: dio);
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (error, handler) {
            // ignore: avoid_print
            print(
              'Live request failed at ${error.requestOptions.uri.host}${error.requestOptions.uri.path}: ${error.type}',
            );
            handler.next(error);
          },
        ),
      );
      addTearDown(() => dio.close(force: true));
      final works = await service.findWorks('葬送的芙莉莲');
      final work = works.firstWhere((w) => w.id == '36093351');
      final scoped = SubtitleSearchQuery(
        text: '葬送的芙莉莲',
        work: work,
        episode: 1,
        language: 'zh-cn',
      );
      final packs = await service.search(
        SubtitleSearchSource.subhd,
        scoped,
        const SubtitleSearchCredentials(),
      );
      expect(packs.hits, isNotEmpty);
      final pack = packs.hits.firstWhere((h) => h.id == 'L5iSNp');
      expect(pack.detailUri?.path, '/a/L5iSNp');
      final packFiles = await service.files(
        pack,
        scoped,
        const SubtitleSearchCredentials(),
      );
      final packDocs = await service.download(
        pack,
        packFiles.single,
        const SubtitleSearchCredentials(),
      );
      expect(packDocs.length, greaterThanOrEqualTo(28));
      expect(packDocs.any((d) => d.name.contains('[01]')), isTrue);
      final batch = const SubtitleBatchMatcher().match(
        targets: [
          for (var ep = 1; ep <= 28; ep++)
            SubtitleBatchTarget(
              id: '$ep',
              title: '葬送的芙莉莲 - ${ep.toString().padLeft(2, '0')}',
              path: '$ep.mkv',
            ),
        ],
        candidates: [
          for (final doc in packDocs)
            SubtitleBatchCandidate(
              hit: pack,
              file: packFiles.single,
              document: doc,
            ),
        ],
        anchorTitle: '葬送的芙莉莲 - 01',
        preferredName: packDocs.first.name,
        catalogId: pack.catalogId,
      );
      expect(
        batch.every((row) => row.confident && row.options.isNotEmpty),
        isTrue,
        reason:
            'The actual bilingual pack should match all 28 videos in a single consistent edition: ${batch.where((r) => !r.confident).map((r) => '${r.target.id}: ${r.reason} (${r.options.length})').join(', ')}',
      );
      final japanese = await service.search(
        SubtitleSearchSource.jimaku,
        SubtitleSearchQuery(
          text: work.title,
          work: work,
          language: 'ja',
          episode: 1,
        ),
        const SubtitleSearchCredentials(),
      );
      expect(japanese.hits.map((h) => h.id), contains('729'));
      expect(
        japanese.hits.every((h) => h.id == '729'),
        isTrue,
        reason: 'A chosen anime work must not return its sequels or shorts',
      );
      // ignore: avoid_print
      print(
        'SubHD: ${works.length} works, ${packs.hits.length} scoped results, ${packDocs.length} readable subtitles; ${batch.where((r) => r.confident).length} episodes matched',
      );
      for (final (source, title) in [
        (SubtitleSearchSource.xunlei, 'Breaking Bad'),
        (SubtitleSearchSource.jimaku, 'Frieren'),
      ]) {
        final query = SubtitleSearchQuery(text: title, season: 1, episode: 1);
        final results = await service.search(
          source,
          query,
          const SubtitleSearchCredentials(),
        );
        expect(results.hits, isNotEmpty, reason: source.label);
        final hit = results.hits.first;
        final files = await service.files(
          hit,
          query,
          const SubtitleSearchCredentials(),
        );
        expect(files, isNotEmpty, reason: '${source.label} files');
        final documents = await service.download(
          hit,
          files.first,
          const SubtitleSearchCredentials(),
        );
        expect(documents.first.cues.length, greaterThan(10));
        // ignore: avoid_print
        print(
          '${source.label}: ${results.hits.length} results, ${files.length} files, ${documents.first.cues.length} cues',
        );
      }
    },
    skip: Platform.environment['SUBTITLE_SEARCH_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
