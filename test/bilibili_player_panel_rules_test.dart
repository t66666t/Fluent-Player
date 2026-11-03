import 'dart:async';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_video.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/landscape_sidebar_layout.dart';

const _bvid = 'BV1xx411c7mD';
const _bools = <bool>[false, true];

VideoItem _item({String path = 'D:/videos/a.mp4', MediaSourceRef? ref}) =>
    VideoItem(
      id: 'v',
      path: path,
      title: 'a',
      durationMs: 1000,
      lastUpdated: 0,
      sourceRef: ref,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('setting', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
    });
    tearDown(() => SettingsService().resetForTest());

    test('open by default, saved through the app memory', () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.bilibiliPlayerPanelOpen, isTrue);
      final memory = BilibiliPlayerPanelMemory.of(settings);
      memory.userCollapsed();
      await Future<void>.delayed(Duration.zero);
      expect(settings.bilibiliPlayerPanelOpen, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bilibiliPlayerPanelOpen'), isFalse);
    });
  });

  group('auto open rule (640 px of video beside the panel)', () {
    bool mayOpen(double width, {bool mobile = false, double? shortest}) {
      final size = Size(width, shortest ?? 900);
      return bilibiliPanelMayAutoOpen(
        windowWidth: width,
        panelWidth: LandscapeSidebarLayout.functionalWidthFor(size),
        isMobilePlatform: mobile,
        shortestSide: shortest ?? 900,
      );
    }

    test('exactly 640 left opens, one pixel less does not', () {
      expect(
        bilibiliPanelMayAutoOpen(
          windowWidth: 1000,
          panelWidth: 360,
          isMobilePlatform: false,
          shortestSide: 800,
        ),
        isTrue,
      );
      expect(
        bilibiliPanelMayAutoOpen(
          windowWidth: 1000,
          panelWidth: 361,
          isMobilePlatform: false,
          shortestSide: 800,
        ),
        isFalse,
      );
    });

    test('desktop windows with the real panel width', () {
      expect(mayOpen(1920), isTrue);
      expect(mayOpen(1280), isTrue);
      expect(mayOpen(900), isFalse);
      expect(mayOpen(800), isFalse);
    });

    test('phones never open it by themselves, tablets follow the 640 rule', () {
      expect(mayOpen(2400, mobile: true, shortest: 1080 / 3), isFalse);
      expect(mayOpen(915, mobile: true, shortest: 412), isFalse);
      expect(mayOpen(1280, mobile: true, shortest: 800), isTrue);
      expect(mayOpen(1024, mobile: true, shortest: 768), isTrue);
      expect(mayOpen(800, mobile: true, shortest: 700), isFalse);
    });
  });

  group('Bilibili video: remembered x auto open x a panel shown over it', () {
    test('entering the player', () {
      for (final subtitles in _bools) {
        for (final remembered in _bools) {
          for (final allow in _bools) {
            final got = landscapeDefaultSidebar(
              subtitleSidebarRemembered: subtitles,
              isBilibiliVideo: true,
              bilibiliPanelRemembered: remembered,
              allowAutoOpen: allow,
            );
            final expected = remembered && allow
                ? LandscapeSidebarTarget.bilibili
                : (subtitles
                      ? LandscapeSidebarTarget.subtitles
                      : LandscapeSidebarTarget.none);
            expect(
              got,
              expected,
              reason:
                  'subtitles=$subtitles remembered=$remembered allow=$allow',
            );
          }
        }
      }
    });

    test('a tool panel opened over the Bilibili panel goes back to it', () {
      // The page keeps the Bilibili panel as the previous one.
      for (final remembered in _bools) {
        for (final allow in _bools) {
          expect(
            landscapeSidebarAfterClose(
              closing: LandscapeSidebarClosing.toolPanel,
              hasPrevious: true,
              subtitleSidebarRemembered: true,
              isBilibiliVideo: true,
              bilibiliPanelRemembered: remembered,
              allowAutoOpen: allow,
            ),
            LandscapeSidebarTarget.previous,
          );
        }
      }
    });

    test('the subtitle list shown for a moment gives way to the Bilibili '
        'panel when it closes', () {
      for (final subtitles in _bools) {
        for (final remembered in _bools) {
          for (final allow in _bools) {
            final got = landscapeSidebarAfterClose(
              closing: LandscapeSidebarClosing.subtitleList,
              hasPrevious: false,
              subtitleSidebarRemembered: subtitles,
              isBilibiliVideo: true,
              bilibiliPanelRemembered: remembered,
              allowAutoOpen: allow,
            );
            expect(
              got == LandscapeSidebarTarget.bilibili,
              remembered && allow,
              reason:
                  'subtitles=$subtitles remembered=$remembered allow=$allow',
            );
          }
        }
      }
    });

    test('closing the Bilibili panel by hand shows the subtitle list only '
        'when it was left open', () {
      expect(
        landscapeSidebarAfterBilibiliClosed(subtitleSidebarRemembered: true),
        LandscapeSidebarTarget.subtitles,
      );
      expect(
        landscapeSidebarAfterBilibiliClosed(subtitleSidebarRemembered: false),
        LandscapeSidebarTarget.none,
      );
    });
  });

  group('video changed on the same page', () {
    test('the Bilibili panel stays for another Bilibili video', () {
      expect(
        landscapeSidebarOnVideoChange(
          showingBilibili: true,
          showingDefaultBefore: true,
          isBilibiliVideo: true,
          newDefault: LandscapeSidebarTarget.subtitles,
        ),
        isNull,
      );
    });

    test('and gives way to the default for any other video', () {
      expect(
        landscapeSidebarOnVideoChange(
          showingBilibili: true,
          showingDefaultBefore: false,
          isBilibiliVideo: false,
          newDefault: LandscapeSidebarTarget.subtitles,
        ),
        LandscapeSidebarTarget.subtitles,
      );
    });

    test('a page on its default panel follows the new default', () {
      expect(
        landscapeSidebarOnVideoChange(
          showingBilibili: false,
          showingDefaultBefore: true,
          isBilibiliVideo: true,
          newDefault: LandscapeSidebarTarget.bilibili,
        ),
        LandscapeSidebarTarget.bilibili,
      );
      // A panel the user picked stays.
      expect(
        landscapeSidebarOnVideoChange(
          showingBilibili: false,
          showingDefaultBefore: false,
          isBilibiliVideo: true,
          newDefault: LandscapeSidebarTarget.bilibili,
        ),
        isNull,
      );
    });
  });

  group('remembered open / closed state', () {
    late List<bool> writes;
    late bool stored;
    late BilibiliPlayerPanelMemory memory;

    setUp(() {
      writes = <bool>[];
      stored = true;
      memory = BilibiliPlayerPanelMemory(
        read: () => stored,
        write: (open) async {
          writes.add(open);
          stored = open;
        },
      );
    });

    test('the button / shortcut toggles and remembers', () {
      expect(memory.userToggled(showing: true), isFalse);
      expect(memory.userToggled(showing: false), isTrue);
      expect(writes, <bool>[false, true]);
    });

    test('the collapse button remembers closed', () {
      memory.userCollapsed();
      expect(writes, <bool>[false]);
      expect(memory.remembered, isFalse);
    });

    test('reading it writes nothing', () {
      expect(memory.remembered, isTrue);
      expect(writes, isEmpty);
    });
  });

  group('which cards are Bilibili videos', () {
    test('online card: BV id and part from the source', () {
      final video = bilibiliPlayerVideoOf(
        _item(
          path: 'bilibili://stream/$_bvid?cid=1',
          ref: const MediaSourceRef(
            value: _bvid,
            kind: MediaSourceKind.bilibiliStream,
            bvid: _bvid,
            page: 3,
          ),
        ),
      );
      expect(video, (bvid: _bvid, page: 3));
    });

    test('downloaded video that kept its BV id', () {
      expect(
        bilibiliPlayerVideoOf(
          _item(
            ref: const MediaSourceRef(
              value: _bvid,
              kind: MediaSourceKind.bilibiliBv,
            ),
          ),
        ),
        (bvid: _bvid, page: 1),
      );
      expect(
        bilibiliPlayerVideoOf(
          _item(
            ref: const MediaSourceRef(
              value: 'https://b23.tv/abc',
              kind: MediaSourceKind.url,
              bvid: _bvid,
              page: 2,
            ),
          ),
        ),
        (bvid: _bvid, page: 2),
      );
    });

    test('local files, other links and broken ids are not', () {
      expect(bilibiliPlayerVideoOf(_item()), isNull);
      expect(bilibiliPlayerVideoOf(null), isNull);
      expect(
        bilibiliPlayerVideoOf(
          _item(
            ref: const MediaSourceRef(
              value: 'https://example.com/v.mp4',
              kind: MediaSourceKind.url,
            ),
          ),
        ),
        isNull,
      );
      expect(
        bilibiliPlayerVideoOf(
          _item(
            ref: const MediaSourceRef(
              value: 'ep123',
              kind: MediaSourceKind.bilibiliId,
            ),
          ),
        ),
        isNull,
      );
      expect(
        bilibiliPlayerVideoOf(
          _item(
            ref: const MediaSourceRef(
              value: 'BV123',
              kind: MediaSourceKind.bilibiliBv,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('video detail cache', () {
    BilibiliVideoDetail detail(String bvid) =>
        BilibiliVideoDetail(bvid: bvid, title: 'title $bvid');

    test('a kept detail is not asked again', () async {
      var asked = 0;
      final cache = BilibiliVideoDetailCache(
        fetch: (bvid) async {
          asked++;
          return detail(bvid);
        },
      );
      expect((await cache.get(_bvid)).title, 'title $_bvid');
      expect((await cache.get(_bvid)).title, 'title $_bvid');
      expect(asked, 1);
      expect(cache.peek(_bvid), isNotNull);
    });

    test('overlapping requests for one video share a request', () async {
      var asked = 0;
      final answer = Completer<BilibiliVideoDetail>();
      final cache = BilibiliVideoDetailCache(
        fetch: (bvid) {
          asked++;
          return answer.future;
        },
      );
      final first = cache.get(_bvid);
      final second = cache.get(_bvid);
      expect(identical(first, second), isTrue);
      answer.complete(detail(_bvid));
      expect((await first).bvid, _bvid);
      expect((await second).bvid, _bvid);
      expect(asked, 1);
    });

    test('a failure is not kept; the next call asks again', () async {
      var asked = 0;
      final cache = BilibiliVideoDetailCache(
        fetch: (bvid) async {
          asked++;
          if (asked == 1) throw StateError('offline');
          return detail(bvid);
        },
      );
      await expectLater(cache.get(_bvid), throwsStateError);
      expect(cache.peek(_bvid), isNull);
      expect((await cache.get(_bvid)).bvid, _bvid);
      expect(asked, 2);
    });

    test('a request that hangs fails after the timeout', () async {
      final cache = BilibiliVideoDetailCache(
        fetch: (bvid) => Completer<BilibiliVideoDetail>().future,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(cache.get(_bvid), throwsA(isA<TimeoutException>()));
      expect(cache.peek(_bvid), isNull);
    });

    test(
      'keeps at most its capacity, least recently used goes first',
      () async {
        final cache = BilibiliVideoDetailCache(
          fetch: (bvid) async => detail(bvid),
          capacity: 2,
        );
        await cache.get('BV1aa411c7mA');
        await cache.get('BV1bb411c7mB');
        await cache.get('BV1aa411c7mA'); // used again
        await cache.get('BV1cc411c7mC');
        expect(cache.length, 2);
        expect(cache.peek('BV1aa411c7mA'), isNotNull);
        expect(cache.peek('BV1bb411c7mB'), isNull);
        expect(cache.peek('BV1cc411c7mC'), isNotNull);
      },
    );
  });
}
