import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_links.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/bilibili_video_link_actions.dart';

const _bvid = 'BV17x411w7KC';
const _otherBvid = 'BV1GJ411x7h7';
const _copyKey = ValueKey('bilibili-panel-copy-link');
const _openKey = ValueKey('bilibili-panel-open-externally');
const _bvKey = ValueKey('bilibili-panel-bvid');
const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Uri> launched;
  late List<String> copied;
  late FutureOr<bool> Function(Uri) launch;
  late FutureOr<void> Function(String) copy;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    launched = <Uri>[];
    copied = <String>[];
    launch = (_) => true;
    copy = (_) {};
    messenger.setMockMethodCallHandler(_launcherChannel, (call) async {
      expect(call.method, 'launch', reason: 'do not gate on canLaunch');
      final arguments = call.arguments as Map;
      expect(arguments['useWebView'], isFalse);
      expect(arguments['useSafariVC'], isFalse);
      final uri = Uri.parse(arguments['url'] as String);
      launched.add(uri);
      return await launch(uri);
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final text = (call.arguments as Map)['text'] as String;
        copied.add(text);
        await copy(text);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_launcherChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Widget host({String bvid = _bvid, int page = 2, double scale = 1}) =>
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: BilibiliVideoLinkActions(bvid: bvid, page: page),
            ),
          ),
        ),
      );

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

  test('public links normalize only the prefix and keep the selected part', () {
    final links = BilibiliVideoLinks.tryParse(' bv17x411w7KC ', page: 3)!;
    expect(links.bvid, _bvid);
    expect(links.web.toString(), 'https://www.bilibili.com/video/$_bvid/?p=3');
    expect(links.app.toString(), 'bilibili://video/170001?page=2');
    final parsed = parseBilibiliLink(links.web.toString())!;
    expect(parsed.bvid, _bvid);
    expect(parsed.page, 3);
    expect(BilibiliVideoLinks.tryParse(_bvid)!.web.hasQuery, isFalse);
    for (final page in <int>[0, -1]) {
      expect(BilibiliVideoLinks.tryParse(_bvid, page: page)!.page, 1);
    }
  });

  test('web parts are 1-based, the official native scheme is 0-based', () {
    for (final page in <int>[1, 2, 7]) {
      final links = BilibiliVideoLinks.tryParse(_bvid, page: page)!;
      expect(links.web.queryParameters['p'] ?? '1', '$page');
      expect(links.app!.queryParameters['page'], '${page - 1}');
    }
  });

  test('malformed identities never become public or native URLs', () {
    for (final value in <String>[
      '',
      'x',
      'xx17x411w7KC',
      'BV123',
      'https://www.bilibili.com/video/$_bvid',
      '$_bvid?evil=true',
      '$_bvid/../',
      'BV17x411w7K中文',
    ]) {
      expect(BilibiliVideoLinks.tryParse(value), isNull, reason: value);
    }
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    test('$platform opens directly with the correct external URL', () async {
      debugDefaultTargetPlatformOverride = platform;
      final links = BilibiliVideoLinks.tryParse(_bvid, page: 2)!;
      expect(
        await links.open(),
        mobile ? BilibiliVideoOpenResult.app : BilibiliVideoOpenResult.browser,
      );
      expect(launched, <Uri>[mobile ? links.app! : links.web]);
    });

    for (final profile in <({Size size, double scale})>[
      (size: const Size(320, 640), scale: 1),
      (size: const Size(240, 320), scale: 1),
      (size: const Size(200, 320), scale: 3),
      (size: const Size(720, 320), scale: 2),
    ]) {
      testWidgets('$platform: ${profile.size}, text ${profile.scale}', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.binding.setSurfaceSize(profile.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(host(scale: profile.scale));
        await tester.pumpAndSettle();
        expect(find.text(_bvid), findsOneWidget);
        expect(find.byTooltip(mobile ? '用哔哩哔哩打开' : '用浏览器打开'), findsOneWidget);
        final bounds = tester.getRect(find.byType(BilibiliVideoLinkActions));
        for (final key in <Key>[_bvKey, _copyKey, _openKey]) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right + 0.01));
        }
        final copyRect = tester.getRect(find.byKey(_copyKey));
        final openRect = tester.getRect(find.byKey(_openKey));
        expect(copyRect.overlaps(openRect), isFalse);
        expect(tester.takeException(), isNull);
        // Even in a short landscape panel each control can be scrolled to.
        await tester.ensureVisible(find.byKey(_openKey));
        await tester.tap(find.byKey(_openKey));
        await tester.pumpAndSettle();
        expect(launched.single.scheme, mobile ? 'bilibili' : 'https');
        await finish(tester);
      });
    }
  }

  for (final platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    for (final throws in <bool>[false, true]) {
      test(
        '$platform: app failure (throws=$throws) falls back to the same P',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          launch = (uri) {
            if (uri.scheme == 'https') return true;
            if (throws) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
            return false;
          };
          final links = BilibiliVideoLinks.tryParse(_bvid, page: 7)!;
          expect(await links.open(), BilibiliVideoOpenResult.browser);
          expect(launched, <Uri>[links.app!, links.web]);
          expect(launched.last.queryParameters['p'], '7');
        },
      );
    }
  }

  test('both native and web launch failures are handled', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    launch = (_) => throw MissingPluginException();
    expect(
      await BilibiliVideoLinks.tryParse(_bvid)!.open(),
      BilibiliVideoOpenResult.failed,
    );
    expect(launched, hasLength(2));
  });

  testWidgets('copy the public link and BV separately without launching', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final before = tester.getRect(find.byType(BilibiliVideoLinkActions));
    final buttonBefore = tester.getRect(find.byKey(_copyKey));
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(BilibiliVideoLinkActions)), before);
    expect(tester.getRect(find.byKey(_copyKey)), buttonBefore);
    expect(copied.last, 'https://www.bilibili.com/video/$_bvid/?p=2');
    expect(find.byTooltip('已复制'), findsOneWidget);
    await tester.tap(find.byKey(_bvKey));
    await tester.pumpAndSettle();
    expect(copied.last, _bvid);
    expect(
      find.descendant(
        of: find.byKey(_bvKey),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(launched, isEmpty);
    await finish(tester);
  });

  testWidgets('copy failures give feedback and allow a retry', (tester) async {
    copy = (_) => throw PlatformException(code: 'clipboard_unavailable');
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    copy = (_) {};
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('repeated taps launch once, then allow another attempt', (
    tester,
  ) async {
    final response = Completer<bool>();
    launch = (_) => response.future;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_openKey));
    await tester.tap(find.byKey(_openKey));
    await tester.pump();
    expect(launched, hasLength(1));
    expect(tester.widget<IconButton>(find.byKey(_openKey)).onPressed, isNull);
    response.complete(true);
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(_openKey)).onPressed,
      isNotNull,
    );
    await finish(tester);
  });

  testWidgets('launch failure gives a useful retry and leaves copy usable', (
    tester,
  ) async {
    launch = (_) => false;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.text('无法打开视频，请复制链接后手动打开'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(copied.single, contains('?p=2'));
    launch = (_) => true;
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(launched, hasLength(2));
    expect(find.text('无法打开视频，请复制链接后手动打开'), findsNothing);
    await finish(tester);
  });

  testWidgets('switching the video cancels an old fallback and updates copy', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final response = Completer<bool>();
    launch = (_) => response.future;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_openKey));
    await tester.pumpWidget(host(bvid: _otherBvid, page: 4));
    response.complete(false);
    await tester.pumpAndSettle();
    expect(launched, hasLength(1), reason: 'no old video in the browser');
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(copied.single, 'https://www.bilibili.com/video/$_otherBvid/?p=4');
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('switching only the part uses the new part and clears feedback', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(page: 3));
    expect(find.byTooltip('已复制'), findsNothing);
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();
    expect(copied.last, endsWith('?p=3'));
    await finish(tester);
  });

  testWidgets('closing during a launch cancels fallback without setState', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final response = Completer<bool>();
    launch = (_) => response.future;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_openKey));
    await finish(tester);
    response.complete(false);
    await tester.pumpAndSettle();
    expect(launched, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending copy cannot show feedback on a new video', (
    tester,
  ) async {
    final response = Completer<void>();
    copy = (_) => response.future;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(_copyKey));
    await tester.pumpWidget(host(bvid: _otherBvid));
    response.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('已复制'), findsNothing);
    expect(
      tester.widget<IconButton>(find.byKey(_copyKey)).onPressed,
      isNotNull,
    );
    await finish(tester);
  });

  for (final succeeds in <bool>[false, true]) {
    testWidgets('links stay usable when details finish (success=$succeeds)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final detail = Completer<BilibiliVideoDetail>();
      final native = Completer<bool>();
      launch = (uri) => uri.scheme == 'bilibili' ? native.future : true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: Scaffold(
            body: BilibiliPlayerPanel(
              bvid: _bvid,
              page: 3,
              fallbackTitle: '标题',
              cache: BilibiliVideoDetailCache(fetch: (_) => detail.future),
              offlineDetails: BilibiliOfflineDetails(),
            ),
          ),
        ),
      );
      await tester.pump();
      final state = tester.state(
        find.ancestor(
          of: find.byKey(_copyKey),
          matching: find.byType(BilibiliVideoLinkActions),
        ),
      );
      await tester.tap(find.byKey(_openKey));
      if (succeeds) {
        detail.complete(const BilibiliVideoDetail(bvid: _bvid, title: '详情标题'));
      } else {
        detail.completeError(
          const BilibiliPublicApiException('离线', isNetworkError: true),
        );
      }
      await tester.pumpAndSettle();
      expect(
        tester.state(
          find.ancestor(
            of: find.byKey(_copyKey),
            matching: find.byType(BilibiliVideoLinkActions),
          ),
        ),
        same(state),
      );
      native.complete(false);
      await tester.pumpAndSettle();
      expect(launched, hasLength(2));
      expect(launched.last.queryParameters['p'], '3');
      expect(find.text('未能唤起哔哩哔哩，已用浏览器打开'), findsOneWidget);
      await tester.tap(find.byKey(_copyKey));
      await tester.pumpAndSettle();
      expect(copied.single, endsWith('?p=3'));
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }

  // Optional visual QA uses the real panel, local CJK font and Material icons.
  if (Platform.environment['BILIBILI_VIDEO_LINKS_PREVIEW'] == '1') {
    testWidgets('render video link previews', (tester) async {
      await (FontLoader('BilibiliPreview')..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  'assets/fonts/NotoSansCJKsc-Regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      const detail = BilibiliVideoDetail(
        bvid: _bvid,
        aid: 170001,
        title: '日常记录：山间徒步与风景分享',
        description: '记录沿途的山川与风景。\n感谢观看，下期再见！',
        owner: BilibiliVideoOwner(mid: 9527, name: '山间漫游'),
        stat: BilibiliVideoStat(
          view: 123456,
          danmaku: 109,
          like: 5432,
          coin: 123,
          favorite: 428,
          reply: 312,
        ),
        parts: <BilibiliVideoPart>[
          BilibiliVideoPart(cid: 1, page: 1, title: '出发'),
          BilibiliVideoPart(cid: 2, page: 2, title: '山间行走'),
        ],
        tags: <String>['旅行', '户外', '风景'],
      );
      for (final profile
          in <({String name, Size size, TargetPlatform platform})>[
            (
              name: 'phone-portrait',
              size: const Size(390, 720),
              platform: TargetPlatform.android,
            ),
            (
              name: 'phone-landscape-panel',
              size: const Size(280, 360),
              platform: TargetPlatform.iOS,
            ),
            (
              name: 'desktop-panel',
              size: const Size(410, 720),
              platform: TargetPlatform.windows,
            ),
          ]) {
        debugDefaultTargetPlatformOverride = profile.platform;
        await tester.binding.setSurfaceSize(profile.size);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'BilibiliPreview',
              ),
            ),
            home: RepaintBoundary(
              key: key,
              child: BilibiliPlayerPanel(
                bvid: _bvid,
                page: 2,
                cache: BilibiliVideoDetailCache(fetch: (_) async => detail),
                offlineDetails: BilibiliOfflineDetails(),
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('bilibili-action-like')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('bilibili-action-coin')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('bilibili-action-favorite')),
          findsNothing,
        );
        await tester.ensureVisible(find.byKey(_copyKey));
        await tester.pumpAndSettle();
        final panelBefore = tester.getRect(find.byKey(_copyKey));
        final episodesBefore = tester.getRect(
          find.byKey(const ValueKey('bilibili-panel-episodes')),
        );
        if (profile.name == 'phone-portrait') {
          expect(
            panelBefore.center.dy,
            tester
                .getCenter(
                  find.byKey(const ValueKey('bilibili-panel-download')),
                )
                .dy,
          );
        }
        for (final copiedState in [false, true]) {
          if (copiedState) {
            await tester.tap(find.byKey(_copyKey));
            await tester.pumpAndSettle();
            expect(find.byTooltip('已复制'), findsOneWidget);
            expect(tester.getRect(find.byKey(_copyKey)), panelBefore);
            expect(
              tester.getRect(
                find.byKey(const ValueKey('bilibili-panel-episodes')),
              ),
              episodesBefore,
            );
          }
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final screenshot = await boundary.toImage(pixelRatio: 2);
            final data = await screenshot.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '.artifacts/bilibili-video-links/${profile.name}${copiedState ? '-copied' : ''}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            screenshot.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await finish(tester);
      }
      await tester.binding.setSurfaceSize(null);
    });
  }
}
