import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_workspace.dart';
import 'package:video_player_app/models/subtitle_model.dart';

import 'subtitle_search_service_test.dart' show MemorySubtitleSecrets;

class FixtureSubtitleSearchService extends SubtitleSearchService {
  int searches = 0, fileReads = 0, downloads = 0;
  bool failXunlei = false;
  Completer<void>? hold;
  final queries = <String>[];
  final requests = <SubtitleSearchQuery>[];
  List<SubtitleSearchWork> works = [];
  int workLookups = 0;
  @override
  Future<List<SubtitleSearchWork>> findWorks(
    String text, {
    CancelToken? cancelToken,
  }) async {
    workLookups++;
    return works;
  }

  @override
  Future<SubtitleSearchPage> search(
    SubtitleSearchSource source,
    SubtitleSearchQuery query,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
  }) async {
    searches++;
    requests.add(query);
    queries.add(query.text);
    await hold?.future;
    if (source == SubtitleSearchSource.xunlei && failXunlei) {
      throw const SubtitleSearchException('来源暂时不可用');
    }
    return SubtitleSearchPage([
      SubtitleSearchHit(
        source: source,
        id: '${source.name}-${query.text}',
        title: '${query.text} · 示例剧集',
        release: '${query.text}.S01E01.1080p.WEB-DL.srt',
        language: source == SubtitleSearchSource.jimaku ? 'ja' : 'zh-cn',
        format: 'SRT',
        websiteUrl: switch (source) {
          SubtitleSearchSource.subhd => 'https://subhd.tv/a/L5iSNp',
          SubtitleSearchSource.jimaku => 'https://jimaku.cc/entry/729',
          _ => null,
        },
      ),
    ]);
  }

  @override
  Future<List<SubtitleSearchFile>> files(
    SubtitleSearchHit hit,
    SubtitleSearchQuery query,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
  }) async {
    fileReads++;
    return [
      const SubtitleSearchFile(
        id: 'file',
        name: '示例剧集.S01E01.srt',
        url: 'https://jimaku.cc/file.srt',
      ),
    ];
  }

  @override
  Future<List<SubtitleSearchDocument>> download(
    SubtitleSearchHit hit,
    SubtitleSearchFile file,
    SubtitleSearchCredentials credentials, {
    CancelToken? cancelToken,
    void Function(double)? onProgress,
  }) async {
    downloads++;
    return [
      SubtitleSearchDocument(
        name: '示例剧集.S01E01.srt',
        content: 'fixture',
        cues: [
          for (var i = 0; i < 12; i++)
            SubtitleItem(
              index: i + 1,
              startTime: Duration(seconds: i * 4 + 1),
              endTime: Duration(seconds: i * 4 + 3),
              text: i.isEven ? '旅の終わりに、もう一度会いましょう。' : '旅途结束时，让我们再次相见。',
            ),
        ],
      ),
    ];
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  SubtitleSearchWorkspace workspace(FixtureSubtitleSearchService service) {
    final result = SubtitleSearchWorkspace(
      service: service,
      secrets: MemorySubtitleSecrets(),
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'returning to the same video keeps results, selection, preview and scroll without requests',
    () async {
      final service = FixtureSubtitleSearchService();
      final w = workspace(service);
      final first = w.acquire('one', 'Frieren S01E01.mkv');
      await first.restored;
      await first.search();
      await first.select(first.hits.first);
      await first.preview();
      first.scrollOffset = 240;
      final selected = first.selected;
      w.release(first);
      final reopened = w.acquire('one', 'Changed display title');
      expect(identical(first, reopened), isTrue);
      expect(reopened.selected, selected);
      expect(reopened.document?.cues, hasLength(12));
      expect(reopened.scrollOffset, 240);
      await reopened.search();
      await reopened.preview();
      expect(service.searches, 3);
      expect(service.fileReads, 1);
      expect(service.downloads, 1);
    },
  );
  test(
    'a search can finish while the route is closed and is reused on return',
    () async {
      final service = FixtureSubtitleSearchService()..hold = Completer<void>();
      final w = workspace(service);
      final session = w.acquire('one', 'Title');
      await session.restored;
      final pending = session.search();
      await Future<void>.delayed(Duration.zero);
      expect(session.searching, isTrue);
      w.release(session);
      service.hold!.complete();
      await pending;
      final reopened = w.acquire('one', 'Title');
      expect(reopened.hits, hasLength(3));
      expect(reopened.searching, isFalse);
      expect(service.searches, 3);
    },
  );
  test(
    'an unavailable provider does not discard successful results and can retry independently',
    () async {
      final service = FixtureSubtitleSearchService()..failXunlei = true;
      final session = workspace(service).acquire('one', 'Title');
      await session.restored;
      await session.search();
      expect(
        session.hits.map((h) => h.source),
        containsAll([SubtitleSearchSource.subhd, SubtitleSearchSource.jimaku]),
      );
      expect(session.errors.keys, contains(SubtitleSearchSource.xunlei));
      service.failXunlei = false;
      await session.search(force: true, retry: SubtitleSearchSource.xunlei);
      expect(session.hits, hasLength(3));
      expect(session.errors, isEmpty);
      expect(service.searches, 4);
    },
  );
  test(
    'late results after cancellation cannot replace a newer query',
    () async {
      final service = FixtureSubtitleSearchService()..hold = Completer<void>();
      final session = workspace(service).acquire('one', 'Old');
      await session.restored;
      final old = session.search();
      await Future<void>.delayed(Duration.zero);
      session.cancelSearch();
      final held = service.hold!;
      service.hold = null;
      session.text = 'New';
      await session.search();
      held.complete();
      await old;
      expect(session.hits.every((hit) => hit.title.startsWith('New')), isTrue);
      expect(session.completedQuery!.text, 'New');
    },
  );
  test(
    'different videos keep independent drafts, results and previews',
    () async {
      final w = workspace(FixtureSubtitleSearchService());
      final one = w.acquire('one', 'One');
      final two = w.acquire('two', 'Two');
      await Future.wait([one.restored, two.restored]);
      one.language = 'ja';
      await one.search();
      await two.search();
      expect(two.language, '');
      expect(one.hits.first.title, startsWith('One'));
      expect(two.hits.first.title, startsWith('Two'));
    },
  );
  test(
    'draft survives process workspace recreation without persisting credentials',
    () async {
      final first = workspace(FixtureSubtitleSearchService());
      final session = first.acquire('one', 'Old');
      await session.restored;
      session.text = '新片名';
      session.language = 'ja';
      session.episode = '7';
      await first.saveDraft(session);
      final second = workspace(FixtureSubtitleSearchService());
      final restored = second.acquire('one', 'Old');
      await restored.restored;
      expect(restored.text, '新片名');
      expect(restored.language, 'ja');
      expect(restored.episode, '7');
    },
  );
}
