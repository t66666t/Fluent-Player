import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/transcript_typography.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('字幕侧栏列表显示设置', () {
    test('横竖屏配置可独立恢复、钳制、持久化并导出', () async {
      SharedPreferences.setMockInitialValues({
        'landscapeSidebarShowTimestamps': false,
        'portraitSidebarShowTimestamps': true,
        'landscapeSidebarTimeColumnRatio': 0.90,
        'portraitSidebarTimeColumnRatio': 0.01,
        'landscapeSidebarLocatePositionPercent': 150,
        'portraitSidebarLocatePositionPercent': -10,
        'subtitleArticleSentencesPerParagraph': 0,
        'transcriptFontWeight': 1100.0,
        'transcriptShowDividers': true,
      });

      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      expect(settings.landscapeSidebarShowTimestamps, isFalse);
      expect(settings.portraitSidebarShowTimestamps, isTrue);
      expect(settings.landscapeSidebarTimeColumnRatio, 0.30);
      expect(settings.portraitSidebarTimeColumnRatio, 0.05);
      expect(settings.landscapeSidebarLocatePositionPercent, 100);
      expect(settings.portraitSidebarLocatePositionPercent, 0);
      expect(settings.subtitleArticleSentencesPerParagraph, 1);
      expect(settings.transcriptFontWeight, 900);
      expect(settings.transcriptShowDividers, isTrue);

      await settings.updateSetting('landscapeSidebarShowTimestamps', true);
      await settings.updateSetting('landscapeSidebarTimeColumnRatio', 0.22);
      await settings.updateSetting('portraitSidebarShowTimestamps', false);
      await settings.updateSetting('portraitSidebarTimeColumnRatio', 0.14);
      await settings.updateSetting('landscapeSidebarLocatePositionPercent', 40);
      await settings.updateSetting('portraitSidebarLocatePositionPercent', 70);
      await settings.updateSetting('subtitleArticleSentencesPerParagraph', 7);
      await settings.updateSetting('transcriptFontWeight', 467.0);
      await settings.updateSetting('transcriptShowDividers', false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('landscapeSidebarShowTimestamps'), isTrue);
      expect(prefs.getDouble('landscapeSidebarTimeColumnRatio'), 0.22);
      expect(prefs.getBool('portraitSidebarShowTimestamps'), isFalse);
      expect(prefs.getDouble('portraitSidebarTimeColumnRatio'), 0.14);
      expect(prefs.getInt('landscapeSidebarLocatePositionPercent'), 40);
      expect(prefs.getInt('portraitSidebarLocatePositionPercent'), 70);
      expect(prefs.getInt('subtitleArticleSentencesPerParagraph'), 7);
      expect(prefs.getDouble('transcriptFontWeight'), 467);
      expect(prefs.getBool('transcriptShowDividers'), isFalse);

      final layout =
          settings.exportSettingsSnapshot()['layout'] as Map<String, dynamic>;
      expect(layout['landscapeSidebarShowTimestamps'], isTrue);
      expect(layout['portraitSidebarShowTimestamps'], isFalse);
      expect(layout['landscapeSidebarTimeColumnRatio'], 0.22);
      expect(layout['portraitSidebarTimeColumnRatio'], 0.14);
      expect(layout['landscapeSidebarLocatePositionPercent'], 40);
      expect(layout['portraitSidebarLocatePositionPercent'], 70);
      expect(layout['subtitleArticleSentencesPerParagraph'], 7);
      expect(layout['transcriptFontWeight'], 467);
      expect(layout['transcriptShowDividers'], isFalse);

      settings.resetForTest();
      await settings.init();
      expect(settings.transcriptFontWeight, 467);
      expect(settings.transcriptShowDividers, isFalse);
    });

    test('新配置默认隐藏时间与分割线，文字只略微加粗', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      expect(settings.landscapeSidebarShowTimestamps, isFalse);
      expect(settings.portraitSidebarShowTimestamps, isFalse);
      expect(settings.transcriptShowDividers, isFalse);
      expect(settings.transcriptFontWeight, 450);
      expect(settings.landscapeSidebarTimeColumnRatio, 0.18);
      expect(settings.portraitSidebarTimeColumnRatio, 0.12);
      expect(settings.landscapeSidebarLocatePositionPercent, 30);
      expect(settings.portraitSidebarLocatePositionPercent, 30);
      expect(settings.subtitleArticleSentencesPerParagraph, 4);
      for (final device in [
        const DefaultSettingsDevice(TargetPlatform.android, Size(390, 844)),
        const DefaultSettingsDevice(TargetPlatform.iOS, Size(768, 1024)),
        const DefaultSettingsDevice(TargetPlatform.windows, Size(1280, 720)),
      ]) {
        final defaults = RecommendedAppDefaults.coreOverrides(device);
        expect(defaults['landscapeSidebarShowTimestamps'], isFalse);
        expect(defaults['portraitSidebarShowTimestamps'], isFalse);
      }
    });

    test('字重限制范围并修正无效数值', () async {
      SharedPreferences.setMockInitialValues({
        'transcriptFontWeight': double.nan,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      expect(settings.transcriptFontWeight, 450);
      await settings.updateSetting('transcriptFontWeight', 20.0);
      expect(settings.transcriptFontWeight, 100);
      await settings.updateSetting('transcriptFontWeight', 456.7);
      expect(settings.transcriptFontWeight, 457);
    });
  });

  group('字幕侧栏列表显示面板', () {
    late VideoPlayerController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'subtitleViewMode': 0,
        'landscapeSidebarShowTimestamps': true,
        'portraitSidebarShowTimestamps': false,
        'landscapeSidebarTimeColumnRatio': 0.18,
        'portraitSidebarTimeColumnRatio': 0.12,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
      controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
    });

    tearDown(() async {
      await controller.dispose();
    });

    testWidgets('带页面存储标识的侧栏打开数字设置不会读到列表位置对象', (tester) async {
      await _pumpSidebar(tester, controller: controller, storageScope: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('30'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.article));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('4'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });

    testWidgets('打开设置后面板悬浮，文稿视口高度不变', (tester) async {
      await _pumpSidebar(tester, controller: controller);
      final before = _tallestScrollableHeight(tester);

      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();

      expect(find.text('字体'), findsOneWidget);
      expect(find.text('字重'), findsOneWidget);
      expect(find.text('分割线'), findsOneWidget);
      expect(_tallestScrollableHeight(tester), before);
    });

    testWidgets('设置项有名称，隐藏时间后不保留时间列', (tester) async {
      await _pumpSidebar(tester, controller: controller);

      expect(find.byKey(const ValueKey('subtitle-time-0')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();

      expect(find.text('字体'), findsOneWidget);
      expect(find.text('时间'), findsOneWidget);
      expect(find.text('宽度'), findsOneWidget);
      expect(find.text('定位位置'), findsOneWidget);
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('subtitle-font-size-slider')),
            )
            .divisions,
        isNull,
      );
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('subtitle-time-column-slider')),
            )
            .divisions,
        isNull,
      );

      final timeToggle = find.byKey(
        const ValueKey('subtitle-show-time-switch'),
      );
      expect(
        find.descendant(of: timeToggle, matching: find.byIcon(Icons.circle)),
        findsOneWidget,
      );
      await tester.tap(timeToggle);
      await tester.pump();

      expect(find.byKey(const ValueKey('subtitle-time-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('subtitle-time-column-0')),
        findsNothing,
      );
      expect(find.text('宽度'), findsNothing);
      expect(
        find.descendant(
          of: timeToggle,
          matching: find.byIcon(Icons.circle_outlined),
        ),
        findsOneWidget,
      );
      expect(find.text('第一条字幕'), findsOneWidget);
    });

    testWidgets('文章视图显示字体和每段句子数设置', (tester) async {
      await _pumpSidebar(tester, controller: controller);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.article));
      await tester.pump();

      expect(find.text('字体'), findsOneWidget);
      expect(find.text('字重'), findsOneWidget);
      expect(find.text('分割线'), findsNothing);
      expect(find.text('每段'), findsOneWidget);
      expect(find.text('定位位置'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-sentences-per-paragraph-input')),
        findsOneWidget,
      );
      expect(find.text('时间'), findsNothing);
      expect(find.text('宽度'), findsNothing);
    });

    testWidgets('共享字重实时应用到列表、段落、连续文章和横竖屏', (tester) async {
      const key = ValueKey('shared-weight-sidebar');
      await _pumpSidebar(tester, controller: controller, sidebarKey: key);
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('subtitle-font-weight-slider'));
      expect(tester.widget<Slider>(slider).divisions, isNull);
      await tester.drag(slider, const Offset(20, 0));
      await tester.pumpAndSettle();
      final weight = SettingsService().transcriptFontWeight;
      expect(weight, isNot(TranscriptTypography.defaultFontWeight));
      expect(
        tester.widget<Text>(find.text('第一条字幕')).style!.fontStyle,
        FontStyle.normal,
      );
      expect(tester.widget<Text>(find.text('第一条字幕')).style!.fontVariations, [
        FontVariation('wght', weight),
      ]);

      await tester.tap(find.byIcon(Icons.article));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SubtitleArticleChunk>(find.byType(SubtitleArticleChunk))
            .fontWeight,
        weight,
      );
      final richText = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(SubtitleArticleChunk),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(
        _findTextSpan(
          richText.text as TextSpan,
          '第一条字幕',
        )!.style!.fontVariations,
        [FontVariation('wght', weight)],
      );

      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: key,
        isPortrait: true,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, weight);
      await SettingsService().updateSetting(
        'subtitleArticleParagraphModeEnabled',
        false,
      );
      await tester.pumpAndSettle();
      final continuous = tester.widget<ContinuousArticleView>(
        find.byType(ContinuousArticleView),
      );
      expect(continuous.style.fontVariations, [FontVariation('wght', weight)]);
      expect(continuous.layout.key.style, continuous.style);
      await SettingsService().updateSetting('transcriptFontWeight', 425.0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ContinuousArticleView>(find.byType(ContinuousArticleView))
            .style
            .fontVariations,
        const [FontVariation('wght', 425)],
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('分割线默认关闭，切换后记忆且横竖屏共用', (tester) async {
      const key = ValueKey('shared-divider-sidebar');
      Finder divider(int index) =>
          find.byKey(ValueKey('subtitle-list-divider-$index'));

      await _pumpSidebar(tester, controller: controller, sidebarKey: key);
      expect(divider(0), findsNothing);
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('subtitle-show-dividers-switch')),
      );
      await tester.pumpAndSettle();
      expect(divider(0), findsOneWidget);
      expect(divider(1), findsNothing, reason: '最后一行后无需分割线');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('transcriptShowDividers'), isTrue);

      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: key,
        isPortrait: true,
      );
      await tester.pumpAndSettle();
      expect(divider(0), findsOneWidget);
      await SettingsService().updateSetting('transcriptShowDividers', false);
      await tester.pumpAndSettle();
      expect(divider(0), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final isPortrait in [false, true]) {
      testWidgets('${isPortrait ? '竖屏' : '横屏'}分割线居中，行距两侧都可点击跳转', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = isPortrait
            ? const Size(390, 844)
            : const Size(800, 600);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = SettingsService();
        await settings.updateSetting('autoScrollSubtitles', false);
        final seeks = <Duration>[];
        await _pumpSidebar(
          tester,
          controller: controller,
          isPortrait: isPortrait,
          onItemTap: seeks.add,
        );
        await tester.pumpAndSettle();

        Finder card(int index) =>
            find.byKey(ValueKey('subtitle-list-card-$index'));
        Rect tapBounds(int index) => tester.getRect(
          find.ancestor(of: card(index), matching: find.byType(InkWell)),
        );
        final first = tester.getRect(card(0));
        final second = tester.getRect(card(1));
        final gap = second.top - first.bottom;
        final middle = first.bottom + gap / 2;
        expect(gap, greaterThan(0));
        final kind = isPortrait
            ? PointerDeviceKind.touch
            : PointerDeviceKind.mouse;

        for (final showDividers in [false, true]) {
          await settings.updateSetting('transcriptShowDividers', showDividers);
          await tester.pumpAndSettle();
          expect(tester.getRect(card(0)), first);
          expect(tester.getRect(card(1)), second);
          expect(tapBounds(0).bottom, closeTo(middle, 0.001));
          expect(tapBounds(1).top, closeTo(middle, 0.001));
          final divider = find.byKey(const ValueKey('subtitle-list-divider-0'));
          if (showDividers) {
            expect(tester.getSize(divider).height, 0.5);
            expect(tester.getCenter(divider).dy, closeTo(middle, 0.001));
          }

          seeks.clear();
          await tester.tapAt(
            Offset(first.center.dx, middle - gap / 4),
            kind: kind,
          );
          await tester.pumpAndSettle();
          await tester.tapAt(
            Offset(first.center.dx, middle + gap / 4),
            kind: kind,
          );
          await tester.pumpAndSettle();
          expect(seeks, [
            const Duration(seconds: 5),
            const Duration(seconds: 9),
          ]);
          await tester.tapAt(Offset(first.center.dx, middle), kind: kind);
          await tester.pumpAndSettle();
          expect(seeks, hasLength(3), reason: '正好点在中线时也应跳转一次');
        }
      });
    }

    for (final sliderName in [
      'subtitle-font-size-slider',
      'subtitle-font-weight-slider',
      'subtitle-time-column-slider',
    ]) {
      testWidgets('$sliderName 拖动时其余设置渐隐，取消和松手均渐显恢复', (tester) async {
        await _pumpSidebar(tester, controller: controller);
        await tester.tap(find.byTooltip('文稿显示设置'));
        await tester.pumpAndSettle();
        final slider = find.byKey(ValueKey(sliderName));
        final background = find.byKey(
          const ValueKey('subtitle-display-settings-background'),
        );
        double opacity(Finder finder) => tester
            .widget<FadeTransition>(
              find
                  .descendant(of: finder, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity
            .value;

        for (final cancel in [true, false]) {
          expect(opacity(background), 1);
          final gesture = await tester.startGesture(tester.getCenter(slider));
          await gesture.moveBy(const Offset(24, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          expect(opacity(background), allOf(greaterThan(0.06), lessThan(1)));
          await tester.pump(const Duration(milliseconds: 100));
          expect(opacity(background), closeTo(0.06, 0.001));
          for (final name in [
            'subtitle-font-size-slider',
            'subtitle-font-weight-slider',
            'subtitle-time-column-slider',
          ]) {
            expect(
              opacity(find.byKey(ValueKey('$name-preview'))),
              closeTo(name == sliderName ? 1 : 0.06, 0.001),
            );
          }
          // A second pointer lifting on the active control must not end the preview.
          final second = await tester.startGesture(tester.getCenter(slider));
          await second.up();
          await tester.pump(const Duration(milliseconds: 200));
          expect(opacity(background), closeTo(0.06, 0.001));
          if (cancel) {
            await gesture.cancel();
          } else {
            await gesture.up();
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          expect(opacity(background), allOf(greaterThan(0.06), lessThan(1)));
          await tester.pumpAndSettle();
          expect(opacity(background), 1);
          expect(tester.takeException(), isNull);
        }
      });
    }

    testWidgets('拖动中切换方向或关闭设置不会留下透明状态或失效手势', (tester) async {
      const key = ValueKey('interrupted-settings-sidebar');
      await _pumpSidebar(tester, controller: controller, sidebarKey: key);
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      final weight = find.byKey(const ValueKey('subtitle-font-weight-slider'));
      var gesture = await tester.startGesture(tester.getCenter(weight));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pumpAndSettle();
      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: key,
        isPortrait: true,
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      final background = find.byKey(
        const ValueKey('subtitle-display-settings-background'),
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: background,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        1,
      );

      gesture = await tester.startGesture(tester.getCenter(weight));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文稿显示设置'));
      await gesture.cancel();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: background,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        1,
      );
      await tester.drag(weight, const Offset(15, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('旋转中结束拖动仍保存原来方向的字号', (tester) async {
      const key = ValueKey('rotate-held-font-size');
      await _pumpSidebar(tester, controller: controller, sidebarKey: key);
      final initialFontSize = tester
          .widget<Text>(find.text('第一条字幕'))
          .style!
          .fontSize!;
      await tester.tap(find.byTooltip('文稿显示设置'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('subtitle-font-size-slider'));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pumpAndSettle();
      final scale =
          tester.widget<Text>(find.text('第一条字幕')).style!.fontSize! /
          initialFontSize;
      expect(scale, isNot(1));
      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: key,
        isPortrait: true,
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(
        SettingsService().landscapeSidebarFontSizeScale,
        closeTo(scale, 0.001),
      );
      expect(SettingsService().portraitSidebarFontSizeScale, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('列表与文章视图使用相同的文字字号和水平边距', (tester) async {
      await _pumpSidebar(tester, controller: controller);

      final listText = tester.widget<Text>(find.text('第一条字幕'));
      final listFontSize = listText.style!.fontSize;
      final listTextLeft = tester
          .getTopLeft(find.byKey(const ValueKey('subtitle-time-0')))
          .dx;

      await tester.tap(find.byIcon(Icons.article));
      await tester.pump();

      final articleRichText = tester.widget<RichText>(
        find.descendant(
          of: find.byType(SubtitleArticleChunk).first,
          matching: find.byType(RichText),
        ),
      );
      final articleRootSpan = articleRichText.text as TextSpan;
      final firstSubtitleSpan = _findTextSpan(articleRootSpan, '第一条字幕')!;

      expect(firstSubtitleSpan.style!.fontSize, listFontSize);
      expect(articleRichText.strutStyle!.fontSize, listFontSize);
      expect(
        tester.getTopLeft(find.byWidget(articleRichText)).dx,
        closeTo(listTextLeft, 0.01),
      );
    });

    testWidgets('每段句子数只接受数字并支持按钮实时分组和持久化', (tester) async {
      await _pumpSidebar(tester, controller: controller);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.article));
      await tester.pump();

      final field = find.byKey(
        const ValueKey('subtitle-sentences-per-paragraph-text-field'),
      );
      expect(tester.widget<TextField>(field).controller!.text, '4');

      final textField = tester.widget<TextField>(field);
      final formatter = textField.inputFormatters!.single;
      expect(
        formatter
            .formatEditUpdate(
              const TextEditingValue(text: '4'),
              const TextEditingValue(text: 'a12b'),
            )
            .text,
        '12',
      );

      textField.onChanged!('1');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '1');
      expect(SettingsService().subtitleArticleSentencesPerParagraph, 1);
      expect(find.byType(SubtitleArticleChunk), findsNWidgets(2));

      final editorFocus = tester.widget<TextField>(field).focusNode!;
      editorFocus.requestFocus();
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey('subtitle-sentences-per-paragraph-increment'),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '2');
      expect(editorFocus.hasFocus, isTrue);
      expect(find.byType(SubtitleArticleChunk), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey('subtitle-sentences-per-paragraph-decrement'),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '1');
      expect(editorFocus.hasFocus, isTrue);
      expect(find.byType(SubtitleArticleChunk), findsNWidgets(2));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('subtitleArticleSentencesPerParagraph'), 1);
    });

    testWidgets('定位位置支持数字输入、固定百分号和每次百分之十步进', (tester) async {
      await _pumpSidebar(tester, controller: controller);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();

      final field = find.byKey(
        const ValueKey('subtitle-locate-position-text-field'),
      );
      expect(tester.widget<TextField>(field).controller!.text, '30');
      expect(
        find.byKey(const ValueKey('subtitle-locate-position-percent-unit')),
        findsOneWidget,
      );

      await tester.tap(field);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.enterText(field, '47');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '47');
      expect(SettingsService().landscapeSidebarLocatePositionPercent, 47);

      await tester.tap(
        find.byKey(const ValueKey('subtitle-locate-position-increment')),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '57');
      expect(SettingsService().landscapeSidebarLocatePositionPercent, 57);

      await tester.tap(
        find.byKey(const ValueKey('subtitle-locate-position-decrement')),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '47');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('landscapeSidebarLocatePositionPercent'), 47);
      expect(prefs.getInt('portraitSidebarLocatePositionPercent'), isNull);
    });

    testWidgets('横竖屏分别恢复定位位置且列表文章共用同一输入项', (tester) async {
      final settings = SettingsService();
      await settings.updateSetting('landscapeSidebarLocatePositionPercent', 40);
      await settings.updateSetting('portraitSidebarLocatePositionPercent', 70);
      const sidebarKey = ValueKey('locate-orientation-aware-sidebar');

      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: sidebarKey,
      );
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      var field = find.byKey(
        const ValueKey('subtitle-locate-position-text-field'),
      );
      expect(tester.widget<TextField>(field).controller!.text, '40');

      await tester.tap(find.byIcon(Icons.article));
      await tester.pump();
      field = find.byKey(const ValueKey('subtitle-locate-position-text-field'));
      expect(tester.widget<TextField>(field).controller!.text, '40');
      await tester.tap(field);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      await _pumpSidebar(
        tester,
        controller: controller,
        isPortrait: true,
        sidebarKey: sidebarKey,
      );
      field = find.byKey(const ValueKey('subtitle-locate-position-text-field'));
      expect(tester.widget<TextField>(field).controller!.text, '70');
      expect(settings.landscapeSidebarLocatePositionPercent, 40);
    });

    testWidgets('同一侧栏切换方向时立即加载对应时间设置', (tester) async {
      const sidebarKey = ValueKey('orientation-aware-sidebar');
      await _pumpSidebar(
        tester,
        controller: controller,
        sidebarKey: sidebarKey,
      );
      expect(find.byKey(const ValueKey('subtitle-time-0')), findsOneWidget);

      await _pumpSidebar(
        tester,
        controller: controller,
        isPortrait: true,
        sidebarKey: sidebarKey,
      );
      expect(find.byKey(const ValueKey('subtitle-time-0')), findsNothing);
    });

    testWidgets('窄侧栏和最大字体下不发生布局溢出', (tester) async {
      final settings = SettingsService();
      await settings.updateSetting('landscapeSidebarFontSizeScale', 3.0);
      await settings.updateSetting('landscapeSidebarTimeColumnRatio', 0.30);

      await _pumpSidebar(tester, controller: controller, height: 500);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await _pumpSidebar(
        tester,
        controller: controller,
        width: 100,
        height: 500,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('第一条字幕'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-time-column-slider')),
        findsOneWidget,
      );
    });

    testWidgets('播放器控制器加载中仍可阅读和设置字幕', (tester) async {
      await _pumpSidebar(tester, controller: null);

      expect(find.text('第一条字幕'), findsOneWidget);
      expect(find.text('第二条用于测试换行的较长字幕文本'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      expect(find.text('字体'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

double _tallestScrollableHeight(WidgetTester tester) {
  final scrollables = find.descendant(
    of: find.byType(SubtitleSidebar),
    matching: find.byType(Scrollable),
  );
  var maxHeight = 0.0;
  for (var index = 0; index < scrollables.evaluate().length; index++) {
    final height = tester.getSize(scrollables.at(index)).height;
    if (height > maxHeight) maxHeight = height;
  }
  return maxHeight;
}

TextSpan? _findTextSpan(TextSpan span, String text) {
  if (span.text == text) return span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is! TextSpan) continue;
    final match = _findTextSpan(child, text);
    if (match != null) return match;
  }
  return null;
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required VideoPlayerController? controller,
  ValueChanged<Duration>? onItemTap,
  bool isPortrait = false,
  Key? sidebarKey,
  double width = 320,
  double height = 600,
  bool storageScope = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => AppTextInputFocus(child: child!),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: storageScope ? const PageStorageKey('player-sidebar') : null,
            width: width,
            height: height,
            child: SubtitleSidebar(
              key: sidebarKey,
              subtitles: [
                SubtitleItem(
                  index: 0,
                  startTime: const Duration(seconds: 5),
                  endTime: const Duration(seconds: 8),
                  text: '第一条字幕',
                ),
                SubtitleItem(
                  index: 1,
                  startTime: const Duration(seconds: 9),
                  endTime: const Duration(seconds: 12),
                  text: '第二条用于测试换行的较长字幕文本',
                ),
              ],
              controller: controller,
              onItemTap: onItemTap,
              isCompact: true,
              isPortrait: isPortrait,
            ),
          ),
        ),
      ),
    ),
  );
}
