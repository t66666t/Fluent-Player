import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/models/subtitle_copy_format.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_card_scale.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';
import 'package:video_player_app/widgets/responsive_icon_button.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';
import 'package:video_player_app/widgets/subtitle_copy_format_popover.dart';
import 'package:video_player_app/widgets/translation_language_controls.dart';

class _LayoutCounter extends SingleChildRenderObjectWidget {
  const _LayoutCounter({required this.onLayout, required Widget sliver})
    : super(child: sliver);

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CountSliverLayout(onLayout);
}

class _CountSliverLayout extends RenderProxySliver {
  _CountSliverLayout(this.onLayout);

  final VoidCallback onLayout;

  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

void main() {
  testWidgets('keyboard alone does not reanchor a fixed browsing list', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    final scroll = PlaybackScrollController();
    addTearDown(scroll.dispose);
    var layouts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackSourceViewport(
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: CustomScrollView(
              controller: scroll,
              slivers: [
                _LayoutCounter(
                  onLayout: () => layouts++,
                  sliver: PlaybackSliverRegion(
                    regionId: 'browse',
                    itemCount: 500,
                    itemKey: (index) => index,
                    sliver: SliverFixedExtentList.builder(
                      itemExtent: 60,
                      itemCount: 500,
                      itemBuilder: (_, index) => Text('result $index'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    scroll.jumpTo(1000);
    await tester.pumpAndSettle();
    final initialLayouts = layouts;
    for (final inset in [40.0, 100.0, 180.0, 320.0, 240.0, 120.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      tester.view.padding = FakeViewPadding(bottom: math.max(0, 24 - inset));
      await tester.pump(const Duration(milliseconds: 8));
      expect(scroll.offset, 1000);
    }
    expect(
      layouts,
      initialLayouts,
      reason: 'IME must not capture/restore anchors and relayout the list',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'language search retains its input and results during IME frames',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final settings = SubtitleTranslateSettings();
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      await settings.setMode(SubtitleTranslationMode.fixed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TranslationLanguageControls(settings: settings)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('translation-target-language')),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('translation-language-search'));
      await tester.enterText(input, '俄语');
      await tester.pumpAndSettle();
      final originalField = tester.widget<TextField>(input);
      final options = find.byKey(
        const ValueKey('translation-language-options'),
      );
      final originalOptions = tester.widget<ListView>(options);
      for (final inset in [20.0, 80.0, 180.0, 320.0, 180.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 8));
        expect(tester.widget(input), same(originalField));
        expect(tester.widget(options), same(originalOptions));
        expect(tester.getRect(input).bottom, lessThan(844 - inset));
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('translation-language-ru')));
      await tester.pumpAndSettle();
      expect(settings.targetLanguage, 'ru');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'copy separator editor only moves its viewport during IME frames',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: SubtitleCopyFormatPopover(
              anchor: const Offset(20, 450),
              format: SubtitleCopyFormat.defaults.copyWith(
                cueJoin: SubtitleCopyCueJoin.custom,
              ),
              previewText: '字幕预览',
              showBilingualOptions: false,
              onFormatChanged: (_) {},
              onReset: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final originalField = tester.widget<TextField>(find.byType(TextField));
      originalField.controller!.text = ' / ';
      for (final inset in [20.0, 80.0, 180.0, 320.0, 180.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 8));
        expect(tester.widget(find.byType(TextField)), same(originalField));
        expect(originalField.focusNode!.hasFocus, isTrue);
        expect(originalField.controller!.text, ' / ');
        expect(
          tester.getRect(find.byType(TextField)).bottom,
          lessThan(844 - inset),
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'root Bilibili input retains page widgets through IME frames',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.mediaLibraryRootEntry = 'bilibili';
      settings.mediaLibraryRootEntryUserChosen = true;
      BilibiliHistoryService.instance.resetForTest();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      final playback = MediaPlaybackService();
      await playback.stop();
      addTearDown(() async {
        debugOnRebuildDirtyWidget = null;
        library.resetLibraryForTesting();
        settings.resetForTest();
        BilibiliHistoryService.instance.resetForTest();
        await playback.stop();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: MaterialApp(
            theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
            home: const MediaLibraryShell(home: HomeScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(BilibiliHomePage),
        matching: find.byType(TextField),
      );
      expect(input, findsOneWidget);
      await tester.tap(input);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(input);
      field.controller!.value = const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await tester.pumpAndSettle();
      final builds = <Type, int>{};
      debugOnRebuildDirtyWidget = (element, _) {
        builds.update(
          element.widget.runtimeType,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      };
      final before = tester.getRect(input);
      for (final inset in [
        8.0,
        16.0,
        24.0,
        48.0,
        80.0,
        120.0,
        180.0,
        260.0,
        320.0,
        320.0,
        280.0,
        300.0,
        310.25,
        310.5,
        240.0,
        160.0,
        80.0,
        24.0,
        0.0,
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        tester.view.padding = FakeViewPadding(
          top: 24,
          bottom: math.max(0, 24 - inset),
        );
        await tester.pump(const Duration(milliseconds: 8));
        expect(tester.getRect(input), before);
        expect(field.focusNode!.hasFocus, isTrue);
        expect(
          field.controller!.value.composing,
          const TextRange(start: 0, end: 2),
        );
        expect(field.controller!.text, 'ni');
        expect(tester.takeException(), isNull);
      }
      debugOnRebuildDirtyWidget = null;
      expect(
        builds[HomeScreen] ?? 0,
        0,
        reason: 'IME must not rebuild the library',
      );
      expect(
        builds[BilibiliHomePage] ?? 0,
        0,
        reason: 'IME must not recreate search/results/history',
      );
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(tester.getRect(input).width, greaterThan(before.width));
      expect(field.controller!.text, 'ni');
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('retained cards and common toolbar sizes ignore IME animation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    settings.mediaLibraryReadableCardDefaults = true;
    addTearDown(settings.resetForTest);
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    var cardBuilds = 0;
    var dimensionsBuilds = 0;
    var imageDpr = 0.0;
    var textScale = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Column(
            children: [
              ResponsiveActionButtons(
                buttons: [
                  ResponsiveIconButton(
                    icon: Icons.search,
                    tooltip: 'Search',
                    onPressed: () {},
                  ),
                ],
              ),
              Builder(
                builder: (context) {
                  dimensionsBuilds++;
                  return SizedBox(
                    height: PlaybackCardLayout.calculate(context).height,
                  );
                },
              ),
              SizedBox(
                width: 180,
                height: 160,
                child: MediaLibraryCardScale(
                  builder: (context) {
                    cardBuilds++;
                    imageDpr = MediaQuery.devicePixelRatioOf(context);
                    textScale = MediaQuery.textScalerOf(context).scale(10);
                    return const Text('retained media card');
                  },
                ),
              ),
              const TextField(),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final initialCardBuilds = cardBuilds;
    final initialDimensionsBuilds = dimensionsBuilds;
    final initialDpr = imageDpr;
    var toolbarBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is ResponsiveIconButton ||
          element.widget is ResponsiveActionButtons) {
        toolbarBuilds++;
      }
    };
    for (final inset in [
      16.0,
      48.0,
      100.0,
      180.0,
      280.0,
      320.0,
      240.0,
      100.0,
      0.0,
    ]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 8));
    }
    debugOnRebuildDirtyWidget = null;
    expect(cardBuilds, initialCardBuilds);
    expect(dimensionsBuilds, initialDimensionsBuilds);
    expect(toolbarBuilds, 0);
    expect(imageDpr, initialDpr);
    // Real layout/accessibility changes still propagate through the boundary.
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    expect(textScale, 14);
    expect(cardBuilds, greaterThan(initialCardBuilds));
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1688);
    await tester.pump();
    expect(imageDpr, closeTo(initialDpr * 2, .001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
