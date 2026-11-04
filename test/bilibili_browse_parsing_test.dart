import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/utils/bilibili_description_links.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/utils/bilibili_text.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

const _bvid = 'BV1GJ411x7h7';

void main() {
  group('search highlight', () {
    test('strips keyword em tags and decodes entities', () {
      expect(
        stripBilibiliHighlight(
          '【<em class="keyword">Flutter</em>】入门 &amp; 实战 &lt;3&gt; &#39;ok&#39;',
        ),
        "【Flutter】入门 & 实战 <3> 'ok'",
      );
      expect(stripBilibiliHighlight(null), '');
      expect(stripBilibiliHighlight('a &amp;lt; b'), 'a &lt; b');
    });

    test('search video result uses plain text title and author', () {
      final video = BilibiliSearchVideo.tryParse({
        'bvid': _bvid,
        'title': '<em class="keyword">猫</em>猫合集',
        'author': '<em class="keyword">UP</em>',
        'pic': '//i0.hdslb.com/bfs/archive/a.jpg',
        'duration': '1:02:05',
        'play': '12345',
        'pubdate': 1700000000,
      })!;
      expect(video.title, '猫猫合集');
      expect(video.author, 'UP');
      expect(video.durationSeconds, 3725);
      expect(video.playCount, 12345);
      expect(
        video.coverUrl,
        'https://i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp',
      );
    });
  });

  group('tolerant parsing', () {
    test('search items without BV id are skipped, missing fields default', () {
      expect(BilibiliSearchVideo.tryParse({'title': 'ad'}), isNull);
      final video = BilibiliSearchVideo.tryParse({'bvid': _bvid})!;
      expect(video.title, '未命名视频');
      expect(video.coverUrl, isNull);
      expect(video.durationSeconds, 0);
      expect(video.publishedAt, isNull);

      expect(BilibiliSearchUser.tryParse({'uname': 'x'}), isNull);
      final user = BilibiliSearchUser.tryParse({'mid': '42'})!;
      expect(user.mid, 42);
      expect(user.name, '未知用户');
      expect(user.avatarUrl, isNull);
    });

    test('detail with almost nothing still parses', () {
      final detail = BilibiliVideoDetail.tryParse({
        'bvid': _bvid,
        'owner': 'oops',
        'stat': null,
        'pages': [
          {'cid': 'bad'},
        ],
        'cid': 99,
        'desc': '-',
        'ugc_season': [],
      })!;
      expect(detail.title, '未命名视频');
      expect(detail.owner.name, '未知 UP 主');
      expect(detail.stat.view, 0);
      expect(detail.description, '');
      expect(detail.parts.single.cid, 99);
      expect(detail.season, isNull);
      expect(detail.tags, isEmpty);
      expect(detail.copyright, 0);
      expect(detail.isReprint, isFalse);
      expect(BilibiliVideoDetail.tryParse({'title': 'no id'}), isNull);
    });

    test('detail keeps copyright through withTags', () {
      final reprint = BilibiliVideoDetail.tryParse({
        'bvid': _bvid,
        'copyright': 2,
      })!;
      expect(reprint.isReprint, isTrue);
      expect(reprint.withTags(const ['a']).copyright, 2);
      final original = BilibiliVideoDetail.tryParse({
        'bvid': _bvid,
        'copyright': '1',
      })!;
      expect(original.copyright, 1);
    });

    test('detail parses parts, season and stats', () {
      final detail = BilibiliVideoDetail.tryParse({
        'bvid': _bvid,
        'aid': 170001,
        'title': '标题',
        'pic': 'http://i1.hdslb.com/bfs/archive/c.png',
        'owner': {'mid': 7, 'name': 'UP', 'face': '//i2.hdslb.com/face.jpg'},
        'stat': {'view': 100, 'like': '5', 'coin': -1},
        'pages': [
          {'cid': 1, 'page': 1, 'part': '开头', 'duration': 60},
          {'cid': 2, 'page': 2, 'part': '', 'duration': 30},
        ],
        'ugc_season': {
          'id': 9,
          'title': '系列',
          'sections': [
            {
              'episodes': [
                {'bvid': _bvid, 'title': '第一集'},
                {'bvid': _bvid, 'title': '重复'},
                {
                  'arc': {'bvid': 'BV1xx411c7mD', 'title': '第二集'},
                },
                {'bvid': 'bad'},
              ],
            },
          ],
        },
      })!;
      expect(detail.parts.map((p) => p.title), ['开头', 'P2']);
      expect(detail.stat.like, 5);
      expect(detail.stat.coin, 0);
      expect(detail.owner.avatarUrl, 'https://i2.hdslb.com/face.jpg');
      expect(detail.season!.episodes.map((e) => e.title), ['第一集', '第二集']);
      expect(
        detail.coverUrl,
        'https://i1.hdslb.com/bfs/archive/c.png@320w_200h_1c.webp',
      );
    });

    test('tags are unique, non-empty and capped', () {
      expect(parseBilibiliTags(null), isEmpty);
      expect(
        parseBilibiliTags([
          {'tag_name': '音乐'},
          {'tag_name': '音乐'},
          {'tag_name': ''},
          'junk',
          {'tag_name': '翻唱'},
        ]),
        ['音乐', '翻唱'],
      );
      final many = [
        for (var i = 0; i < 30; i++) {'tag_name': 't$i'},
      ];
      expect(parseBilibiliTags(many), hasLength(16));
    });

    test('search page stops at 50 pages', () {
      const page = BilibiliSearchPage<int>(items: [1], page: 50, numPages: 80);
      expect(page.hasMore, isFalse);
      const mid = BilibiliSearchPage<int>(items: [1], page: 3, numPages: 80);
      expect(mid.hasMore, isTrue);
      const last = BilibiliSearchPage<int>(items: [1], page: 3, numPages: 3);
      expect(last.hasMore, isFalse);
    });
  });

  group('cover url', () {
    test('forces https and adds the cover suffix', () {
      expect(
        bilibiliCoverThumbnailUrl('//i0.hdslb.com/bfs/archive/a.jpg'),
        'https://i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp',
      );
      expect(
        bilibiliCoverThumbnailUrl('http://i0.hdslb.com/bfs/archive/a.jpg'),
        'https://i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp',
      );
      expect(
        bilibiliCoverThumbnailUrl(
          'https://i0.hdslb.com/bfs/archive/a.jpg@100w_100h.jpg?x=1',
        ),
        'https://i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp',
      );
      expect(
        bilibiliCoverThumbnailUrl('https://archive.biliimg.com/bfs/a.png'),
        'https://archive.biliimg.com/bfs/a.png@320w_200h_1c.webp',
      );
    });

    test('rejects other hosts and unsafe forms', () {
      for (final bad in [
        null,
        '',
        'https://evil.com/a.jpg',
        'https://hdslb.com.evil.com/a.jpg',
        'https://evilhdslb.com/a.jpg',
        'https://user@i0.hdslb.com/a.jpg',
        'https://i0.hdslb.com:8443/a.jpg',
        'ftp://i0.hdslb.com/a.jpg',
        'javascript:alert(1)',
      ]) {
        expect(bilibiliCoverThumbnailUrl(bad), isNull, reason: '$bad');
      }
    });

    test('sharp detail cover follows width x devicePixelRatio', () {
      const raw = '//i0.hdslb.com/bfs/archive/a.jpg';
      const base = 'https://i0.hdslb.com/bfs/archive/a.jpg';
      expect(bilibiliCoverSharpUrl(raw, 300), '$base@672w_378h_1c.webp');
      expect(bilibiliCoverSharpUrl(raw, 672), '$base@672w_378h_1c.webp');
      expect(bilibiliCoverSharpUrl(raw, 673), '$base@960w_540h_1c.webp');
      expect(bilibiliCoverSharpUrl(raw, 788 * 1.5), '$base@1280w_720h_1c.webp');
      // Wider than every tier: the original image, no suffix.
      expect(bilibiliCoverSharpUrl(raw, 788 * 2.0), base);
      // A thumbnail URL is upgraded from the same image path.
      expect(
        bilibiliCoverSharpUrl(bilibiliCoverThumbnailUrl(raw), 900),
        '$base@960w_540h_1c.webp',
      );
      // List thumbnails are untouched.
      expect(bilibiliCoverThumbnailUrl(raw), '$base@320w_200h_1c.webp');
    });

    test('player poster stays a 16:9 crop, including the stand-in', () {
      const raw = '//i0.hdslb.com/bfs/archive/a.jpg@320w_200h_1c.webp';
      const base = 'https://i0.hdslb.com/bfs/archive/a.jpg';
      expect(bilibiliCoverFrameUrl(raw), '$base@320w_180h_1c.webp');
      expect(bilibiliCoverVideoFrameUrl(raw, 300), '$base@672w_378h_1c.webp');
      expect(bilibiliCoverVideoFrameUrl(raw, 2000), '$base@1280w_720h_1c.webp');
      expect(bilibiliCoverVideoFrameUrl(raw, double.infinity), isNot(base));
      expect(bilibiliCoverFrameUrl('https://evil.com/a.jpg'), isNull);
    });

    test('sharp detail cover keeps the host rules', () {
      expect(
        bilibiliCoverSharpUrl('http://archive.biliimg.com/bfs/a.png', 500),
        'https://archive.biliimg.com/bfs/a.png@672w_378h_1c.webp',
      );
      for (final bad in [
        null,
        'https://evil.com/a.jpg',
        'https://hdslb.com.evil.com/a.jpg',
        'https://user@i0.hdslb.com/a.jpg',
        'ftp://i0.hdslb.com/a.jpg',
      ]) {
        expect(bilibiliCoverSharpUrl(bad, 800), isNull, reason: '$bad');
      }
    });

    test('avatar is normalized but never cropped', () {
      expect(
        bilibiliAvatarUrl('//i1.hdslb.com/bfs/face/x.jpg'),
        'https://i1.hdslb.com/bfs/face/x.jpg',
      );
      expect(bilibiliAvatarUrl('https://evil.com/x.jpg'), isNull);
    });
  });

  group('BV and link recognition', () {
    test('bare ids', () {
      expect(parseBilibiliLink(_bvid)!.bvid, _bvid);
      expect(parseBilibiliLink('bv1GJ411x7h7')!.bvid, _bvid);
      expect(parseBilibiliLink(' av170001 ')!.aid, 170001);
    });

    test('video links with part number', () {
      final target = parseBilibiliLink(
        '看这个 https://www.bilibili.com/video/$_bvid/?p=3&t=10 很好',
      )!;
      expect(target.bvid, _bvid);
      expect(target.page, 3);
      expect(
        parseBilibiliLink('https://m.bilibili.com/video/av170001')!.aid,
        170001,
      );
      expect(
        parseBilibiliLink(
          'https://www.bilibili.com/list/watchlater?bvid=$_bvid',
        )!.bvid,
        _bvid,
      );
    });

    test('short links need resolving', () {
      final target = parseBilibiliLink('【标题】 https://b23.tv/AbCdEf')!;
      expect(target.needsResolve, isTrue);
      expect(target.shortLink.toString(), 'https://b23.tv/AbCdEf');
    });

    test('ordinary keywords and other sites are searched', () {
      for (final text in [
        'flutter 教程',
        'BV号是什么',
        'av',
        'https://www.youtube.com/watch?v=$_bvid',
        'https://www.bilibili.com/',
      ]) {
        expect(parseBilibiliLink(text), isNull, reason: text);
      }
    });

    test('resolved redirect must stay on bilibili', () {
      expect(
        parseResolvedBilibiliUrl(
          Uri.parse('https://www.bilibili.com/video/$_bvid?p=2'),
        )!.page,
        2,
      );
      expect(
        parseResolvedBilibiliUrl(Uri.parse('https://evil.com/video/$_bvid')),
        isNull,
      );
    });
  });

  group('description links', () {
    test('splits urls, BV and av ids', () {
      final segments = splitBilibiliDescription(
        '前作 $_bvid，另见av170001。官网: https://example.com/a?b=1.',
      );
      expect(segments, const [
        BilibiliDescriptionSegment(BilibiliDescriptionSegmentKind.text, '前作 '),
        BilibiliDescriptionSegment(BilibiliDescriptionSegmentKind.bvid, _bvid),
        BilibiliDescriptionSegment(BilibiliDescriptionSegmentKind.text, '，另见'),
        BilibiliDescriptionSegment(
          BilibiliDescriptionSegmentKind.aid,
          'av170001',
        ),
        BilibiliDescriptionSegment(
          BilibiliDescriptionSegmentKind.text,
          '。官网: ',
        ),
        BilibiliDescriptionSegment(
          BilibiliDescriptionSegmentKind.url,
          'https://example.com/a?b=1',
        ),
        BilibiliDescriptionSegment(BilibiliDescriptionSegmentKind.text, '.'),
      ]);
      expect(splitBilibiliDescription('纯文本'), const [
        BilibiliDescriptionSegment(BilibiliDescriptionSegmentKind.text, '纯文本'),
      ]);
    });
  });

  group('formatting', () {
    test('counts and durations', () {
      expect(formatBilibiliCount(9999), '9999');
      expect(formatBilibiliCount(12345), '1.2万');
      expect(formatBilibiliCount(100000000), '1亿');
      expect(formatBilibiliDuration(75), '01:15');
      expect(formatBilibiliDuration(3725), '1:02:05');
      expect(formatBilibiliDuration(0), '--:--');
      expect(parseBilibiliDurationText('x:1'), 0);
    });
  });
}
