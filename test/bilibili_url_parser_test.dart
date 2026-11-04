import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

const String _bvid = 'BV1xx411c7mD'; // av2

void main() {
  group('BilibiliUrlParser', () {
    for (final id in ['ss15549', 'ep551412']) {
      test('classroom links keep their course namespace: $id', () async {
        final url = 'https://www.bilibili.com/cheese/play/$id';
        final target = parseBilibiliLink('$url?t=12')!;
        expect(target.parseInput, url);
        expect(target.isVideo, isFalse);
        expect(target.isCourse, isTrue);
        expect(target.isBangumi, isFalse);
        expect(parseBilibiliLink(id)!.isBangumi, isTrue);
        expect(target.startAt, const Duration(seconds: 12));
        final normalized = BilibiliUrlParser.normalizeInput(url)!;
        expect(
          normalized.type.name,
          id.startsWith('ss') ? 'courseSs' : 'courseEp',
        );
        expect(normalized.id, id);
        final resolved = await resolveBilibiliShortLink(
          Uri.parse('https://b23.tv/4ZO8mRe'),
          fetchRedirect: (_) async => Uri.parse(
            'https://m.bilibili.com/cheese/play/$id?share_source=COPY',
          ),
        );
        expect(resolved.target?.parseInput, url);
      });
    }

    for (final id in [
      'ep273401',
      'ep5528791',
      'ep341309',
      'ep4280680',
      'ep6084344',
      'ep673044',
      'ss28770',
    ]) {
      test('recognizes the explicit bangumi short address $id', () async {
        final url = 'https://b23.tv/$id';
        final input = BilibiliUrlParser.normalizeInput('【分享】 $url');
        expect(input?.cleanedInput, url);
        expect(
          input?.type,
          id.startsWith('ep')
              ? BilibiliUrlType.bangumiEp
              : BilibiliUrlType.bangumiSs,
        );
        expect(input?.id, id);
        final target = parseBilibiliLink(url)!;
        expect(target.bangumiId, id);
        expect(target.needsResolve, isFalse);
        final resolved = await resolveBilibiliShortLink(
          Uri.parse(url),
          fetchRedirect: (_) async => throw StateError('no request needed'),
        );
        expect(resolved.target?.bangumiId, id);
      });
    }

    test('bangumi aliases keep timing and require a whole path segment', () {
      final target = parseBilibiliLink('http://b23.tv/EP273401/?t=12')!;
      expect(target.bangumiId, 'ep273401');
      expect(target.startAt, const Duration(seconds: 12));
      for (final suffix in ['ep273401extra', 'abc?next=ep273401']) {
        final url = 'https://b23.tv/$suffix';
        expect(parseBilibiliLink(url)?.needsResolve, isTrue);
        expect(
          BilibiliUrlParser.normalizeInput(url)?.type,
          BilibiliUrlType.shortLink,
        );
      }
      expect(parseBilibiliLink('https://example.com/ep273401'), isNull);
    });

    test('keeps a b23 short link from shared text for redirect resolution', () {
      final input = BilibiliUrlParser.normalizeInput(
        '【视频标题-哔哩哔哩】 https://b23.tv/PkvvCb4',
      );

      expect(input, isNotNull);
      expect(input?.cleanedInput, 'https://b23.tv/PkvvCb4');
      expect(input?.type, BilibiliUrlType.shortLink);
      expect(input?.id, isNull);
    });

    test('still rejects unsupported links without a Bilibili id', () {
      expect(
        BilibiliUrlParser.normalizeInput('https://example.com/video/123'),
        isNull,
      );
    });
  });

  group('parseBilibiliLink ids', () {
    test('bare BV id, any prefix case', () {
      expect(parseBilibiliLink(_bvid)!.bvid, _bvid);
      expect(parseBilibiliLink(' bv1xx411c7mD ')!.bvid, _bvid);
      final target = parseBilibiliLink(_bvid)!;
      expect(target.page, isNull);
      expect(target.startAt, isNull);
      expect(target.needsResolve, isFalse);
      expect(target.parseInput, _bvid);
    });

    test('BV inside text only when asked to look for it', () {
      const text = '标题：看看这个 BV1xx411c7mD ！';
      expect(parseBilibiliLink(text), isNull);
      expect(parseBilibiliLink(text, findIdInText: true)!.bvid, _bvid);
      expect(
        parseBilibiliLink('xBV1xx411c7mDx', findIdInText: true),
        isNull,
        reason: 'id glued to other letters is not an id',
      );
    });

    test('av id converts to BV', () {
      final target = parseBilibiliLink('av170001')!;
      expect(target.aid, 170001);
      expect(target.bvid, 'BV17x411w7KC');
      expect(parseBilibiliLink('AV2')!.bvid, _bvid);
      expect(parseBilibiliLink('另见 av2 。', findIdInText: true)!.bvid, _bvid);
      expect(bvidFromAid(80433022), 'BV1GJ411x7h7');
      expect(aidFromBvid('BV1GJ411x7h7'), 80433022);
      expect(aidFromBvid('bv17x411w7KC'), 170001);
      expect(bvidFromAid(0), isNull);
      expect(bvidFromAid(1 << 51), isNull);
      expect(aidFromBvid('BV123'), isNull);
    });

    test('full video links on www and m', () {
      expect(
        parseBilibiliLink('https://www.bilibili.com/video/$_bvid/')!.bvid,
        _bvid,
      );
      final mobile = parseBilibiliLink(
        'https://m.bilibili.com/video/av170001',
      )!;
      expect(mobile.aid, 170001);
      expect(mobile.bvid, 'BV17x411w7KC');
      expect(
        parseBilibiliLink(
          '前缀 https://www.bilibili.com/video/$_bvid?p=2 ，后缀',
        )!.page,
        2,
      );
      expect(
        parseBilibiliLink(
          'https://www.bilibili.com/list/watchlater?bvid=$_bvid',
        )!.bvid,
        _bvid,
      );
    });

    test('bangumi links are recognized but are not videos', () {
      final ep = parseBilibiliLink(
        'https://www.bilibili.com/bangumi/play/ep12345',
      )!;
      expect(ep.bangumiId, 'ep12345');
      expect(ep.isVideo, isFalse);
      expect(parseBilibiliLink('SS678')!.parseInput, 'ss678');
    });
  });

  group('parseBilibiliLink part number', () {
    String link(String query) => 'https://www.bilibili.com/video/$_bvid?$query';

    test('p is 1-based', () {
      expect(parseBilibiliLink(link('p=1'))!.page, 1);
      expect(parseBilibiliLink(link('p=3'))!.page, 3);
      expect(parseBilibiliLink(link('p=0'))!.page, isNull);
    });

    test('page is 0-based', () {
      expect(parseBilibiliLink(link('page=0'))!.page, 1);
      expect(parseBilibiliLink(link('page=2'))!.page, 3);
      expect(parseBilibiliLink(link('page=-1'))!.page, isNull);
    });

    test('p wins over page; neither means unspecified', () {
      expect(parseBilibiliLink(link('page=4&p=2'))!.page, 2);
      final none = parseBilibiliLink(link('spm_id_from=333'))!;
      expect(none.page, isNull);
      expect(none.pageOrFirst, 1);
    });
  });

  group('parseBilibiliLink start time', () {
    String link(String query) => 'https://www.bilibili.com/video/$_bvid?$query';

    test('t is seconds', () {
      expect(
        parseBilibiliLink(link('t=90'))!.startAt,
        const Duration(seconds: 90),
      );
      expect(
        parseBilibiliLink(link('p=2&t=12.5'))!.startAt,
        const Duration(milliseconds: 12500),
      );
    });

    test('start_progress is milliseconds', () {
      expect(
        parseBilibiliLink(link('start_progress=45000'))!.startAt,
        const Duration(seconds: 45),
      );
    });

    test('t wins; missing, zero or junk gives null', () {
      expect(
        parseBilibiliLink(link('start_progress=1000&t=5'))!.startAt,
        const Duration(seconds: 5),
      );
      expect(parseBilibiliLink(link('p=1'))!.startAt, isNull);
      expect(parseBilibiliLink(link('t=0'))!.startAt, isNull);
      expect(parseBilibiliLink(link('t=abc'))!.startAt, isNull);
    });
  });

  group('invalid input', () {
    test('returns null instead of throwing', () {
      for (final text in [
        '',
        '   ',
        'flutter 教程',
        'BV号是什么',
        'BV123',
        'av',
        'avocado',
        'https://example.com/video/$_bvid',
        'https://www.youtube.com/watch?v=$_bvid',
        'https://www.bilibili.com/',
        'https://b23.tv/',
        'ftp://b23.tv/abc',
        'https://',
      ]) {
        expect(parseBilibiliLink(text), isNull, reason: text);
        expect(
          parseBilibiliLink(text, findIdInText: true),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('short links', () {
    test(
      'opaque short links can redirect to an explicit bangumi alias',
      () async {
        final fetch = _FakeRedirects({
          'https://b23.tv/abc?t=30': 'https://b23.tv/ep273401',
        });
        final result = await resolveBilibiliShortLink(
          Uri.parse('https://b23.tv/abc?t=30'),
          fetchRedirect: fetch.call,
        );
        expect(result.target?.bangumiId, 'ep273401');
        expect(result.target?.startAt, const Duration(seconds: 30));
        expect(fetch.requests, hasLength(1));
      },
    );

    test('a b23 link needs resolving and keeps its own parameters', () {
      final target = parseBilibiliLink('【标题】 https://b23.tv/AbCdEf?p=2')!;
      expect(target.needsResolve, isTrue);
      expect(target.shortLink, Uri.parse('https://b23.tv/AbCdEf?p=2'));
      expect(target.page, 2);
      expect(target.parseInput, isNull);
    });

    test('follows https redirects to the video with part and time', () async {
      final fetch = _FakeRedirects({
        'https://b23.tv/abc': 'https://b23.tv/hop',
        'https://b23.tv/hop':
            'https://www.bilibili.com/video/$_bvid?p=2&t=30&share_source=x',
      });
      final result = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: fetch.call,
      );
      expect(result.isSuccess, isTrue);
      expect(result.target!.bvid, _bvid);
      expect(result.target!.page, 2);
      expect(result.target!.startAt, const Duration(seconds: 30));
      expect(fetch.requests, hasLength(2));
    });

    test('short link parameters fill in what the target lacks', () async {
      final result = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc?p=3'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc?p=3': '/video/$_bvid',
        }).call,
      );
      // A relative Location stays on b23.tv and is not a video host.
      expect(result.failure, BilibiliShortLinkFailure.noVideo);

      final ok = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc?p=3'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc?p=3': 'https://m.bilibili.com/video/av170001',
        }).call,
      );
      expect(ok.target!.bvid, 'BV17x411w7KC');
      expect(ok.target!.page, 3);
    });

    test('five redirects are allowed, the sixth fails', () async {
      final chain = <String, String>{
        for (var i = 0; i < 4; i++)
          'https://b23.tv/n$i': 'https://b23.tv/n${i + 1}',
        'https://b23.tv/n4': 'https://www.bilibili.com/video/$_bvid',
      };
      final ok = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/n0'),
        fetchRedirect: _FakeRedirects(chain).call,
      );
      expect(ok.target?.bvid, _bvid);

      final endless = _FakeRedirects.endless();
      final result = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/start'),
        fetchRedirect: endless.call,
      );
      expect(result.failure, BilibiliShortLinkFailure.tooManyRedirects);
      expect(result.target, isNull);
      expect(endless.requests, hasLength(kBilibiliShortLinkMaxRedirects));
    });

    test('an http short link is upgraded to https before resolving', () async {
      final fetch = _FakeRedirects({
        'https://b23.tv/abc': 'https://www.bilibili.com/video/$_bvid?p=2',
      });
      final result = await resolveBilibiliShortLink(
        Uri.parse('http://b23.tv/abc'),
        fetchRedirect: fetch.call,
      );
      expect(result.target?.bvid, _bvid);
      expect(result.target?.page, 2);
      expect(fetch.requests.single.scheme, 'https');
      expect(
        upgradeBilibiliShortLink(Uri.parse('http://bili2233.cn/x')).scheme,
        'https',
      );
      expect(
        upgradeBilibiliShortLink(Uri.parse('http://example.com/x')).scheme,
        'http',
      );
    });

    test('a redirect down to http still fails', () async {
      final downgraded = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc': 'http://www.bilibili.com/video/$_bvid',
        }).call,
      );
      expect(downgraded.failure, BilibiliShortLinkFailure.insecureScheme);
      expect(downgraded.message, contains('https'));

      final viaHttpStart = await resolveBilibiliShortLink(
        Uri.parse('http://b23.tv/abc'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc': 'http://b23.tv/next',
        }).call,
      );
      expect(viaHttpStart.failure, BilibiliShortLinkFailure.insecureScheme);
    });

    test('leaving Bilibili fails', () async {
      final fetch = _FakeRedirects({
        'https://b23.tv/abc': 'https://evil.example.com/video/$_bvid',
      });
      final result = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: fetch.call,
      );
      expect(result.failure, BilibiliShortLinkFailure.foreignHost);
      expect(fetch.requests, hasLength(1));

      final lookalike = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc': 'https://notbilibili.com/video/$_bvid',
        }).call,
      );
      expect(lookalike.failure, BilibiliShortLinkFailure.foreignHost);
    });

    test('no redirect or no video gives a clear failure', () async {
      final noRedirect = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: _FakeRedirects({}).call,
      );
      expect(noRedirect.failure, BilibiliShortLinkFailure.noVideo);

      final home = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: _FakeRedirects({
          'https://b23.tv/abc': 'https://www.bilibili.com/',
        }).call,
      );
      expect(home.failure, BilibiliShortLinkFailure.noVideo);
    });

    test('network errors and timeouts are results, not exceptions', () async {
      final broken = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: (_) async => throw StateError('offline'),
      );
      expect(broken.failure, BilibiliShortLinkFailure.network);
      expect(broken.failure!.isRetryable, isTrue);

      final hanging = Completer<Uri?>();
      final slow = await resolveBilibiliShortLink(
        Uri.parse('https://b23.tv/abc'),
        fetchRedirect: (_) => hanging.future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(slow.failure, BilibiliShortLinkFailure.timeout);
      expect(BilibiliShortLinkFailure.foreignHost.isRetryable, isFalse);
    });
  });
}

class _FakeRedirects {
  _FakeRedirects(this.locations) : _endless = false;

  _FakeRedirects.endless() : locations = const {}, _endless = true;

  final Map<String, String> locations;
  final bool _endless;
  final List<Uri> requests = <Uri>[];

  Future<Uri?> call(Uri url) async {
    requests.add(url);
    if (_endless) return Uri.parse('https://b23.tv/hop${requests.length}');
    final location = locations[url.toString()];
    return location == null ? null : Uri.parse(location);
  }
}
