import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_subhd.dart';

import 'subtitle_search_service_test.dart' show cueText, jsonBody;

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

const work = SubtitleSearchWork(
  id: '2373195',
  title: '绝命毒师 第一季',
  originalTitle: 'Breaking Bad',
  year: '2008',
  type: 'TVSeries',
);
String card(String id, String release, {String format = 'ASS'}) =>
    '''
<div class="row pt-2 mb-2"><div><a href="/d/2373195">绝命毒师 第一季</a>
<div class="view-text"><a href="/a/$id">$release</a></div>
<span>双语</span><span>简体</span><span>英语</span><span>$format</span></div></div>''';

void main() {
  SubtitleSearchService service(ResponseBody Function(RequestOptions) respond) {
    final dio = Dio()..httpClientAdapter = _Adapter(respond);
    addTearDown(() => dio.close(force: true));
    return SubtitleSearchService(dio: dio);
  }

  test(
    'verified anime identity excludes the first season when a sequel work is selected',
    () async {
      var refinements = 0;
      String entry(int id, int anilist, String title) =>
          '<div class="entry" data-extra="{&#34;name&#34;:&#34;$title&#34;,&#34;anilist_id&#34;:$anilist,&#34;japanese_name&#34;:&#34;$title&#34;}"><a href="/entry/$id">title</a></div>';
      final s = service((r) {
        expect(r.headers['Authorization'], isNull);
        if (r.uri.host == 'graphql.anilist.co') {
          refinements++;
          return jsonBody({
            'data': {
              'Page': {
                'media': [
                  {
                    'id': 182255,
                    'title': {
                      'native': '葬送のフリーレン 第2期',
                      'english': 'Frieren Season 2',
                    },
                    'synonyms': [],
                    'seasonYear': 2026,
                  },
                ],
              },
            },
          });
        }
        return ResponseBody.fromString(
          r.uri.path == '/dramas'
              ? '<html></html>'
              : '${entry(729, 154587, '葬送のフリーレン')}${entry(999, 182255, '葬送のフリーレン 第2期')}',
          200,
        );
      });
      const query = SubtitleSearchQuery(
        text: '葬送的芙莉莲',
        season: 2,
        work: SubtitleSearchWork(
          id: '36829083',
          title: '葬送的芙莉莲 第二季',
          originalTitle: '葬送のフリーレン 第2期',
          year: '2026',
          type: 'TVSeries',
        ),
      );
      final result = await s.search(
        SubtitleSearchSource.jimaku,
        query,
        const SubtitleSearchCredentials(),
      );
      expect(result.hits.single.id, '999');
      expect(result.hits.single.season, 2);
      await s.search(
        SubtitleSearchSource.jimaku,
        query,
        const SubtitleSearchCredentials(),
      );
      expect(refinements, 1);
    },
  );
  test(
    'catalog preserves year, original title and season identity and caches requests',
    () async {
      var calls = 0;
      final s = service((request) {
        calls++;
        expect(Uri.decodeComponent(request.uri.path), '/searchD/绝命毒师');
        expect(request.headers['Authorization'], isNull);
        return jsonBody({
          'success': true,
          'items': [
            {
              'id': '2373195',
              'title': '绝命毒师 第一季',
              'title2': 'Breaking Bad',
              'year': '2008',
              'type': 'TVSeries',
            },
            {
              'id': '3586996',
              'title': '绝命毒师 第二季',
              'title2': 'Breaking Bad',
              'year': '2009',
              'type': 'TVSeries',
            },
          ],
        });
      });
      final works = await s.findWorks('绝命毒师');
      expect(works.map((w) => w.season), [1, 2]);
      expect(works.first.originalTitle, 'Breaking Bad');
      await s.findWorks('绝命毒师');
      expect(calls, 1);
    },
  );

  test(
    'catalog selection scopes subtitle posts, keeps packs and filters wrong episodes and image-only releases',
    () async {
      final body = [
        card('pack', 'Breaking.Bad.S01.1080p.BluRay'),
        card('one', 'Breaking.Bad.S01E01.WEB-DL'),
        card('two', 'Breaking.Bad.S01E02.WEB-DL'),
        card('other', 'Breaking.Bad.S02E01'),
        card('image', 'Breaking.Bad.S01', format: 'SUP'),
        '<ul class="pagination"><li><a href="/d/2373195/2">2</a></li></ul>',
      ].join();
      final s = service((r) {
        expect(r.uri.path, '/d/2373195');
        return ResponseBody.fromString(body, 200);
      });
      final result = await s.search(
        SubtitleSearchSource.subhd,
        const SubtitleSearchQuery(
          text: 'Breaking Bad',
          work: work,
          season: 1,
          episode: 1,
          language: 'zh-cn',
        ),
        const SubtitleSearchCredentials(),
      );
      expect(result.hits.map((h) => h.id), ['pack', 'one']);
      expect(result.hasMore, isTrue);
      expect(result.hits.first.releaseInfo.pack, isTrue);
      expect(result.hits.last.releaseInfo.episode, 1);
      expect(result.hits.first.detailUri.toString(), 'https://subhd.tv/a/pack');
      expect(result.hits.first.catalogId, '2373195');
    },
  );

  test(
    'normal download handshake retains site cookies, isolates CDN and preserves language folders',
    () async {
      final archive = Archive();
      for (final dir in ['简体', '英语']) {
        archive.addFile(ArchiveFile.string('$dir/Show [01].srt', cueText));
      }
      final zip = ZipEncoder().encode(archive);
      final calls = <String>[];
      final s = service((r) {
        calls.add(r.uri.path);
        expect(r.headers['Authorization'], isNull);
        switch (r.uri.path) {
          case '/a/pack':
            return ResponseBody.fromString(
              '<a class="subtitle-file-name" data-filename="简体/Show [01].srt"></a><a class="subtitle-file-name" data-filename="英语/Show [01].srt"></a>',
              200,
              headers: {
                'set-cookie': ['session=fixture; Path=/; Secure'],
              },
            );
          case '/api/sub/prepare-download':
            expect(r.headers['cookie'], contains('session=fixture'));
            expect(r.headers['Referer'], 'https://subhd.tv/a/pack');
            return jsonBody({'success': true, 'url': '/down/temporary'});
          case '/down/temporary':
            return ResponseBody.fromString('download', 200);
          case '/api/sub/down':
            expect(r.headers['Referer'], 'https://subhd.tv/down/temporary');
            return jsonBody({
              'pass': true,
              'url': 'https://dl.subhd.me/2026/pack.zip',
            });
          case '/2026/pack.zip':
            expect(r.headers['cookie'], isNull);
            return ResponseBody.fromBytes(
              zip,
              200,
              headers: {
                'content-length': ['${zip.length}'],
              },
            );
          default:
            throw StateError('Unexpected request ${r.uri}');
        }
      });
      const hit = SubtitleSearchHit(
        source: SubtitleSearchSource.subhd,
        id: 'pack',
        title: 'Show',
        websiteUrl: 'https://subhd.tv/a/pack',
      );
      final files = await s.files(
        hit,
        const SubtitleSearchQuery(text: 'Show'),
        const SubtitleSearchCredentials(),
      );
      expect(files.single.archiveEntries, hasLength(2));
      expect(files.single.name, isNot(endsWith('.zip')));
      expect(files.single.declaredOnly, isTrue);
      expect(files.single.availabilityLabel, contains('尚未验证'));
      final docs = await s.download(
        hit,
        files.single,
        const SubtitleSearchCredentials(),
      );
      expect(docs.map((d) => d.name).toSet(), {
        '简体/Show [01].srt',
        '英语/Show [01].srt',
      });
      expect(docs.every((d) => d.cues.isNotEmpty), isTrue);
      expect(calls, contains('/api/sub/down'));
    },
  );

  test(
    'untrusted download routes are rejected before making a connection',
    () async {
      final s = service((r) {
        if (r.uri.path == '/a/pack') {
          return ResponseBody.fromString('detail', 200);
        }
        if (r.uri.path == '/api/sub/prepare-download') {
          return jsonBody({
            'success': true,
            'url': 'https://example.com/down/token',
          });
        }
        throw StateError('Unexpected connection ${r.uri}');
      });
      await expectLater(
        s.download(
          const SubtitleSearchHit(
            source: SubtitleSearchSource.subhd,
            id: 'pack',
            title: 'Show',
          ),
          const SubtitleSearchFile(id: 'pack', name: 'pack.zip'),
          const SubtitleSearchCredentials(),
        ),
        throwsA(isA<SubtitleSearchException>()),
      );
    },
  );

  test(
    'a homepage or foreign website is never presented as this subtitle detail page',
    () {
      for (final url in [
        null,
        'https://www.xunlei.com/',
        'https://example.com/detail/1',
        'javascript:alert(1)',
      ]) {
        expect(
          SubtitleSearchHit(
            source: SubtitleSearchSource.xunlei,
            id: '1',
            title: 'Show',
            websiteUrl: url,
          ).detailUri,
          isNull,
        );
      }
    },
  );

  test('pack manifest only exposes supported subtitle files', () {
    expect(
      parseSubhdEntries(
        '<a class="subtitle-file-name" data-filename="show.ass"></a><a class="subtitle-file-name" data-filename="font.exe"></a>',
      ),
      ['show.ass'],
    );
  });
  test(
    'season-only Xunlei queries are sent and conflicting seasons are removed',
    () async {
      final s = service((r) {
        expect(r.uri.queryParameters['name'], 'Show S02');
        return jsonBody({
          'code': 0,
          'data': [
            {
              'cid': 'wrong',
              'name': 'Show.S01E03.srt',
              'url': 'https://subtitle.v.geilijiasu.com/a.srt',
            },
            {
              'cid': 'right',
              'name': 'Show.S02E03.srt',
              'url': 'https://subtitle.v.geilijiasu.com/b.srt',
            },
          ],
        });
      });
      final results = await s.search(
        SubtitleSearchSource.xunlei,
        const SubtitleSearchQuery(text: 'Show', season: 2),
        const SubtitleSearchCredentials(),
      );
      expect(results.hits.single.id, 'right');
    },
  );
  test(
    'an anime absolute episode query does not invent a first season',
    () async {
      final s = service((r) {
        expect(r.uri.queryParameters['name'], 'Show E113');
        return jsonBody({'code': 0, 'data': []});
      });
      await s.search(
        SubtitleSearchSource.xunlei,
        const SubtitleSearchQuery(text: 'Show', episode: 113),
        const SubtitleSearchCredentials(),
      );
    },
  );
}
