import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';
import 'package:video_player_app/widgets/landscape_sidebar_layout.dart';

const _bvid = 'BV1xx411c7mD';
const _detail = BilibiliVideoDetail(
  bvid: _bvid,
  title: '横屏播放时的哔哩哔哩共享侧栏',
  description: '标题、简介和字幕中的文字依然可以选择、复制。',
  owner: BilibiliVideoOwner(mid: 7, name: '测试 UP 主'),
  stat: BilibiliVideoStat(view: 120000, like: 3000),
  parts: [
    BilibiliVideoPart(cid: 1, page: 1, title: '第一节'),
    BilibiliVideoPart(cid: 2, page: 2, title: '第二节'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previewPath = Platform.environment['BILIBILI_SIDEBAR_PREVIEW'];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
  });
  tearDown(SettingsService().resetForTest);

  if (previewPath != null) {
    setUpAll(() async {
      await (FontLoader('SidebarPreview')..addFont(
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
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    double width = 320,
    bool reducedMotion = false,
    GlobalKey? boundary,
  }) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: previewPath == null ? null : 'SidebarPreview',
          ),
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 750,
              child: RepaintBoundary(
                key: boundary,
                child: MediaQuery(
                  data: MediaQueryData(disableAnimations: reducedMotion),
                  child: _Tabs(cache: cache),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [100.0, 180.0, 262.4, 480.0]) {
    testWidgets('Bilibili content fits shared width $width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = GlobalKey();
      await mount(tester, width: width, boundary: boundary);
      expect(tester.takeException(), isNull);
      expect(find.byType(SelectableText), findsWidgets);
      expect(tester.getSize(find.byType(BilibiliPortraitTabs)).width, width);
      if (previewPath != null && width == 262.4) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(previewPath).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets('label changes slide, reverse smoothly and retain panel state', (
    tester,
  ) async {
    await mount(tester);
    final details = find.byType(BilibiliPlayerPanel);
    final detailsState = tester.state(details);
    final origin = tester.getTopLeft(details).dx;
    await tester.tap(
      find.byKey(const ValueKey('bilibili-landscape-tab-subtitles')),
    );
    await tester.pump();
    expect(tester.getTopLeft(details).dx, origin);
    await tester.pump(const Duration(milliseconds: 70));
    final midway = tester.getTopLeft(details).dx;
    expect(midway, inExclusiveRange(origin - 320, origin));
    await tester.tap(
      find.byKey(const ValueKey('bilibili-landscape-tab-details')),
    );
    await tester.pump();
    expect(tester.getTopLeft(details).dx, closeTo(midway, .001));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(details).dx, origin);
    expect(tester.state(details), same(detailsState));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bilibili SelectableText selection blocks touch paging', (
    tester,
  ) async {
    await mount(tester);
    final editableFinder = find
        .descendant(
          of: find.byType(BilibiliPlayerPanel),
          matching: find.byType(EditableText),
        )
        .first;
    final editable = tester.state<EditableTextState>(editableFinder);
    editable.widget.focusNode.requestFocus();
    editable.userUpdateTextEditingValue(
      editable.widget.controller.value.copyWith(
        selection: const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      SelectionChangedCause.longPress,
    );
    await tester.pumpAndSettle();
    await tester.timedDragFrom(
      const Offset(260, 500),
      const Offset(-190, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
          .tab,
      PortraitBilibiliTab.details,
    );
    expect(editable.widget.controller.selection.isCollapsed, isFalse);
    await tester.tap(
      find.byKey(const ValueKey('bilibili-landscape-tab-subtitles')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
          .tab,
      PortraitBilibiliTab.subtitles,
    );
  });

  testWidgets('reduced motion switches without an animation ticker', (
    tester,
  ) async {
    await mount(tester, reducedMotion: true);
    await tester.tap(
      find.byKey(const ValueKey('bilibili-landscape-tab-subtitles')),
    );
    await tester.pump();
    expect(find.byType(BilibiliPlayerPanel), findsNothing);
    final transition = tester.widget<AnimatedBuilder>(
      find
          .descendant(
            of: find.byType(BilibiliPortraitTabs),
            matching: find.byType(AnimatedBuilder),
          )
          .first,
    );
    expect((transition.animation as AnimationController).isAnimating, isFalse);
  });
}

class _Tabs extends StatefulWidget {
  const _Tabs({required this.cache});
  final BilibiliVideoDetailCache cache;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  PortraitBilibiliTab tab = PortraitBilibiliTab.details;

  @override
  Widget build(BuildContext context) => BilibiliPortraitTabs(
    tab: tab,
    detailsLabel: '哔哩哔哩',
    keyPrefix: 'bilibili-landscape',
    onSelect: (value) => setState(() => tab = value),
    onClose: () {},
    details: LandscapeSidebarTheme(
      child: BilibiliPlayerPanel(
        bvid: _bvid,
        cache: widget.cache,
        offlineDetails: BilibiliOfflineDetails(),
        showHeader: false,
      ),
    ),
    subtitles: const ColoredBox(
      color: Color(0xFF1E1E1E),
      child: Center(child: Text('字幕阅读位置')),
    ),
  );
}
