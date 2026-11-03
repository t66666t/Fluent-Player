import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/clipboard_link.dart';

void main() {
  List<ClipboardLink> detect(String text) => ClipboardLinkDetector.detect(text);

  test('extracts both supplied Douyin shares including long text and escapes', () {
    final inputs = [
      r'8.46 复制打开抖音，看看【源史今说的作品】  https\://v.douyin.com/OnCdbJYwbOw/ k@P.XM :4pm EuF:/ 11/06&#x20;',
      '${List.filled(1800, '独居生活，明天仍要继续。').join()} '
          r'https\://v.douyin.com/whHBSfP9sow/ 复制此链接，打开抖音搜索，直接观看视频！ daN:/ x@F.HV 07/09 :2pm&#x20;',
    ];
    for (var i = 0; i < inputs.length; i++) {
      final links = detect(inputs[i]);
      expect(links, hasLength(1));
      expect(links.single.kind, ClipboardLinkKind.douyin);
      expect(
        links.single.url,
        i == 0
            ? 'https://v.douyin.com/OnCdbJYwbOw/'
            : 'https://v.douyin.com/whHBSfP9sow/',
      );
    }
  });

  test('routes the supplied Douyin share without rewriting its ellipsis', () {
    const url = 'https://v.douyin.com/GDXYOBTL3...';
    final link = detect('$url X@m.qE').single;
    expect(link.kind, ClipboardLinkKind.douyin);
    expect(link.url, url);
    expect(link.offersGenericDownload, isFalse);
  });

  test('Douyin domains route by source regardless of path or valid port', () {
    for (final url in [
      'https://douyin.com/',
      'https://www.douyin.com/?modal_id=1234567890123456789',
      'https://m.douyin.com/new-path?opaque=%FF&sig=A%2bB%3d#part!',
      'https://V.DOUYIN.COM/GDXYOBTL3…',
      'https://iesdouyin.com/unfamiliar/path',
      'https://www.iesdouyin.com/',
      'https://live.douyin.com/123456789',
      'https://open.douyin.com/feed',
      'https://m.iesdouyin.com/unfamiliar-path',
      'https://douyin.com:8443/video/1234567890123456789',
      'v.douyin.com/GDXYOBTL3...',
    ]) {
      final link = detect(url).single;
      expect(link.kind, ClipboardLinkKind.douyin, reason: url);
      expect(
        link.url,
        url.startsWith('http') ? url : 'https://$url',
        reason: url,
      );
      expect(link.offersGenericDownload, isFalse, reason: url);
    }
  });

  test('supplied YouTube and X markdown links retain all parameters', () {
    const youtube = 'https://youtu.be/96o0ERdz_G0?is=pPdZbWmmxnEte-DI';
    const x =
        'https://x.com/huxlab/status/2115240099495788552?a=dL0MO6-Cdhqbm6WUm0A&s=19';
    expect(detect('[$youtube]($youtube)').single.url, youtube);
    expect(detect('[$x](${x.replaceAll('&', r'\&')})').single.url, x);
    expect(detect(x).single.label, 'X 链接');
    expect(detect(x).single.kind, ClipboardLinkKind.web);
  });

  test('Markdown uses the destination, never its misleading URL label', () {
    final links = detect(
      '[https://v.douyin.com/abc/](https://other.example/watch)',
    );
    expect(links.single.url, 'https://other.example/watch');
    expect(links.single.kind, ClipboardLinkKind.web);
    expect(
      detect(
        '[嵌套 [https://v.douyin.com/abc/]](https://other.example/watch)',
      ).single.url,
      'https://other.example/watch',
    );
    expect(detect('[https://v.douyin.com/abc/](javascript:alert(1))'), isEmpty);
    expect(detect('[https://v.douyin.com/abc/](relative-page)'), isEmpty);
    expect(
      detect('[分享](<https://example.org/a(b)?x=1&y=2> "标题")').single.url,
      'https://example.org/a(b)?x=1&y=2',
    );
  });

  test(
    'preserves signed URL spelling, encoding, query order and fragments',
    () {
      const signed =
          'https://Example.COM/Case/%41/%2f?q=a+b&x=%7e&x=2&sig=A%2bB%3d#part!';
      expect(detect(signed).single.url, signed);
      expect(
        detect(signed).single.identity,
        'https://example.com/Case/%41/%2f?q=a+b&x=%7e&x=2&sig=A%2bB%3d#part!',
      );
      const punctuation = 'https://example.com/?signature=end.,;!?';
      expect(detect(punctuation).single.url, punctuation);
      for (final exact in [
        'https://example.com/签名/路径!',
        'https://example.com/valid-unmatched)',
        'https://例子.中国/视频?名称=你好',
      ]) {
        expect(detect(exact).single.url, exact);
      }
      const nested =
          'https://example.com/?next=https://v.douyin.com/abc/&q=BV1xx411c7mD';
      expect(detect(nested), hasLength(1));
      expect(detect(nested).single.kind, ClipboardLinkKind.web);
      expect(detect(nested).single.url, nested);
      const malformedQuery =
          'https://www.bilibili.com/video/BV1xx411c7mD?opaque=%FF';
      expect(detect(malformedQuery).single.url, malformedQuery);
      expect(detect('https://%FF.example/a'), isEmpty);
      const embeddedMarkdown =
          'https://evil.example/?q=[label](https://v.douyin.com/abc/)';
      expect(detect(embeddedMarkdown).single.url, embeddedMarkdown);
      expect(detect(embeddedMarkdown).single.kind, ClipboardLinkKind.web);
    },
  );

  test(
    'handles surrounding punctuation without losing balanced URL brackets',
    () {
      const url = 'https://example.com/watch/(demo)?a=1&b=two#part';
      expect(detect('参考：($url)。').single.url, url);
      expect(
        detect('链接：https://example.com/a。 另见').single.url,
        'https://example.com/a',
      );
      expect(
        detect("'https://example.com/a'").single.url,
        'https://example.com/a',
      );
      expect(
        detect('<https://example.com/a>').single.url,
        'https://example.com/a',
      );
      expect(
        detect('视频https://v.douyin.com/abc/ 分享').single.kind,
        ClipboardLinkKind.douyin,
      );
    },
  );

  for (final raw in [
    '1234567890123456789',
    '今天讨论 ep123 和 av170001',
    'hello example.com',
    'name@example.com',
    'https:/example.com',
    'ftp://example.com/video.mp4',
    'file:///C:/video.mp4',
    'javascript:https://v.douyin.com/abc/',
    'data:https://example.com/a',
    'https://douyin.com@evil.example/video/123',
    'https://user:secret@example.com/a',
    'https://localhost/a',
    'https://127.0.0.1/a',
    'https://router.local/a',
    'https://example.com:99999/a',
    'https://example.com:abc/a',
    'https://example.com/%ZZ',
    'https://example.com/a\\b',
    'nothttps://v.douyin.com/abc/',
  ]) {
    test('ignores invalid or incidental text: $raw', () {
      expect(detect(raw), isEmpty);
    });
  }

  for (final raw in [
    'https://v.douyin.com.evil.example/abc/',
    'https://notdouyin.com/video/1234567890123456789',
    'https://evil.example/https://v.douyin.com/abc/',
    'https://evil.example/video/BV1xx411c7mD',
    'https://evil.example/podcast/62694abdb221dd5908417d1e',
    'https://podcasts.apple.com.evil.example/podcast/id123',
    'https://www.xiaoyuzhoufm.com/help',
    'https://example.org/settings.xml',
    'https://douyin.com.evil.example/GDXYOBTL3...',
    'https://evil.example/?url=https://v.douyin.com/GDXYOBTL3...',
  ]) {
    test('does not invent a special destination for $raw', () {
      expect(detect(raw).single.kind, ClipboardLinkKind.web);
    });
  }

  test(
    'recognizes known podcast paths; generic RSS remains only a feed hint',
    () {
      for (final url in [
        'https://podcasts.apple.com/cn/podcast/example/id12345?i=67890',
        'https://podcasts.apple.com/podcast/id12345',
        'https://www.xiaoyuzhoufm.com/podcast/62694abdb221dd5908417d1e',
        'https://www.xiaoyuzhoufm.com/episode/62694abdb221dd5908417d1e',
        'https://www.ximalaya.com/album/12345',
      ]) {
        expect(detect(url).single.kind, ClipboardLinkKind.podcast);
      }
      expect(
        detect('https://example.org/news/rss.xml').single.kind,
        ClipboardLinkKind.feed,
      );
      expect(
        detect('https://example.org/feed').single.kind,
        ClipboardLinkKind.feed,
      );
    },
  );

  test(
    'Bilibili keeps bare IDs, parts, time, short links and course namespaces',
    () {
      expect(detect('BV1xx411c7mD').single.bilibili?.bvid, 'BV1xx411c7mD');
      final target = detect(
        'https://www.bilibili.com/video/BV1xx411c7mD?p=2&t=30',
      ).single.bilibili!;
      expect(target.page, 2);
      expect(target.startAt, const Duration(seconds: 30));
      expect(
        detect('https://b23.tv/abc').single.bilibili?.needsResolve,
        isTrue,
      );
      expect(
        detect(
          'https://www.bilibili.com/cheese/play/ep123',
        ).single.bilibili?.courseId,
        'ep123',
      );
      expect(
        detect('https://www.bilibili.com/article/BV1xx411c7mD').single.bilibili,
        isNull,
      );
    },
  );

  test(
    'scans every URL, deduplicates, preserves order and meaningful parameters',
    () {
      final links = detect(
        'https://example.org/a https://v.douyin.com/abc/ '
        '[重复](https://EXAMPLE.org/a) https://example.org/a?t=30',
      );
      expect(links.map((l) => l.kind), [
        ClipboardLinkKind.web,
        ClipboardLinkKind.douyin,
        ClipboardLinkKind.web,
      ]);
      expect(links.last.url, 'https://example.org/a?t=30');
    },
  );

  test('bounded work never offers a silently truncated link batch', () {
    expect(detect('a' * (ClipboardLinkDetector.maxTextLength + 1)), isEmpty);
    expect(detect('https://example.org/${'a' * 9000}'), isEmpty);
    expect(
      detect(List.generate(33, (i) => 'https://example.org/$i').join(' ')),
      isEmpty,
    );
  });

  test(
    'Douyin sources never offer generic download, even on unfamiliar paths',
    () {
      for (final url in [
        'https://v.douyin.com/OnCdbJYwbOw/',
        'https://www.douyin.com/video/1234567890123456789',
        'https://www.iesdouyin.com/share/video/1234567890123456789/',
        'https://www.douyin.com/?modal_id=1234567890123456789',
        'https://live.douyin.com/123456789',
        'https://WWW.DOUYIN.COM/unfamiliar-path',
      ]) {
        expect(detect(url).single.offersGenericDownload, isFalse, reason: url);
      }
      for (final url in [
        'https://example.org/watch',
        'https://youtu.be/96o0ERdz_G0',
        'https://v.douyin.com.evil.example/abc/',
        'https://example.org/?url=https://v.douyin.com/abc/',
      ]) {
        expect(detect(url).single.offersGenericDownload, isTrue, reason: url);
      }
    },
  );
}
