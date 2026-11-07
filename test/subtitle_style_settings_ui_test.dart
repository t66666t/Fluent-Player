import 'package:video_player_app/services/subtitle_font_service.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_font_license_dialog.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/widgets/subtitle_settings_sheet.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

final _captureKey = GlobalKey();

class _Harness extends StatefulWidget {
  final double panelWidth;
  final double textScale;
  const _Harness({this.panelWidth = 350, this.textScale = 1});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  SubtitleStyle style = const SubtitleStyle();
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, fontFamily: 'MiSans'),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: Scaffold(
          body: RepaintBoundary(
            key: _captureKey,
            child: Row(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xff34464c), Color(0xff17262f)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Stack(
                      children: [
                        const Center(
                          child: Icon(
                            Icons.play_circle_outline,
                            color: Colors.white12,
                            size: 90,
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: SizedBox(
                            height: 180,
                            child: SubtitleOverlayGroup(
                              entries: const [
                                SubtitleOverlayEntry(
                                  text: '风起时，我们再次相遇。',
                                  secondaryText:
                                      'When the wind rises, we meet again.',
                                ),
                              ],
                              style: style,
                              alignment: const Alignment(0, .25),
                              referenceHeight: 500,
                              enableDebugPreview: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: widget.panelWidth,
                  child: SubtitleSettingsSheet(
                    style: style,
                    hideGhostModeToggle: true,
                    onClose: () {},
                    onBack: () {},
                    onTextStyleChanged: (text) =>
                        setState(() => style = style.copyWith(textStyle: text)),
                    onLayoutStyleChanged: (layout) => setState(
                      () => style = style.copyWith(layoutStyle: layout),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openFonts(WidgetTester tester) async {
  await tester.runAsync(() => SubtitleFontService.instance.catalog());
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('subtitle-font-settings')).hitTestable(),
    130,
    scrollable: find
        .descendant(
          of: find.byType(SubtitleSettingsSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(find.byKey(const ValueKey('subtitle-font-settings')));
  await tester.pumpAndSettle();
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/subtitle-style-review');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubtitleDebugSession.instance.resetForTest();
  });
  testWidgets(
    'font subpage preserves panel bounds, preview, settings and scroll',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const _Harness());
      await tester.pumpAndSettle();
      expect(find.text('整体大小'), findsOneWidget);
      expect(find.text('主字号'), findsOneWidget);
      expect(find.text('副字号'), findsOneWidget);
      expect(find.text('自适应屏幕字号'), findsNothing);
      final bounds = tester.getRect(find.byType(SubtitleSettingsSheet));
      await _openFonts(tester);
      expect(tester.getRect(find.byType(SubtitleSettingsSheet)), bounds);
      expect(find.text('通用字体'), findsOneWidget);
      expect(find.byType(SubtitleOverlayGroup), findsOneWidget);
      await tester.tap(find.text('添加语言'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('日文'));
      await tester.pumpAndSettle();
      expect(find.text('日文'), findsOneWidget);
      await tester.tap(find.byTooltip('返回').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-font-settings')).hitTestable(),
        findsOneWidget,
      );
      await _openFonts(tester);
      expect(find.text('日文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'font selector and language addition fit narrow, short and large text panels',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final size in [
        (248.0, 320.0, 1.0),
        (300.0, 700.0, 1.0),
        (360.0, 650.0, 2.0),
        (390.0, 350.0, 1.0),
      ]) {
        await tester.binding.setSurfaceSize(Size(900, size.$2));
        await tester.pumpWidget(
          _Harness(panelWidth: size.$1, textScale: size.$3),
        );
        await tester.pumpAndSettle();
        await _openFonts(tester);
        await tester.tap(find.text('通用字体'));
        await tester.pumpAndSettle();
        expect(find.text('我的'), findsOneWidget);
        expect(find.text('在线'), findsOneWidget);
        expect(find.text('导入'), findsOneWidget);
        await tester.tap(find.text('在线'));
        await tester.pump();
        await tester.runAsync(() => SubtitleFontService.instance.catalog());
        await tester.pumpAndSettle();
        expect(find.text('汉仪风尚黑 75W（个人版）'), findsOneWidget);
        expect(find.text('去官网'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'authorization warning offers both decisions and skips approved fonts',
    (tester) async {
      bool? accepted;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                accepted = await confirmSubtitleFontLicenses(context, const [
                  SubtitleFontAsset(
                    id: 'a',
                    name: '个人版',
                    license: SubtitleFontLicense.personal,
                  ),
                  SubtitleFontAsset(id: 'b', name: '本地字体'),
                ]);
              },
              child: const Text('合成'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('合成'));
      await tester.pumpAndSettle();
      expect(find.text('仅个人使用'), findsOneWidget);
      expect(find.text('授权未知'), findsOneWidget);
      await tester.tap(find.text('返回调整'));
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      await tester.tap(find.text('合成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续合成'));
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
    },
  );
  testWidgets(
    'review screenshots use actual bundled fonts with a visible player',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final chinese = FontLoader('Noto Sans SC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
        final english = FontLoader('Comic Relief')
          ..addFont(rootBundle.load('assets/fonts/ComicRelief-Regular.ttf'));
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await Future.wait([chinese.load(), english.load(), icons.load()]);
      });
      await tester.pumpWidget(const _Harness());
      await tester.pumpAndSettle();
      await _snapshot(tester, 'main');
      await _openFonts(tester);
      await _snapshot(tester, 'fonts');
      await tester.tap(find.text('通用字体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在线'));
      await tester.pump();
      await tester.runAsync(() => SubtitleFontService.instance.catalog());
      await tester.pumpAndSettle();
      await _snapshot(tester, 'online');
      expect(tester.takeException(), isNull);
    },
  );
}
