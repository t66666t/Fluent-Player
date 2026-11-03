import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_safe_area.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/mobile_system_bar_surface.dart';
import 'package:video_player_app/widgets/mobile_system_navigation_bar.dart';

class _LibraryPage extends StatefulWidget {
  const _LibraryPage();

  @override
  State<_LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<_LibraryPage> {
  bool selecting = false;
  int actions = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTokens.bgBase,
    extendBody: true,
    appBar: AppBar(
      backgroundColor: AppTokens.bgBase,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: MobileSystemNavigationBar.overlayStyle,
      actions: [
        TextButton(
          key: const ValueKey('toggle-selection'),
          onPressed: () => setState(() => selecting = !selecting),
          child: const Text('Select'),
        ),
      ],
    ),
    body: MediaLibrarySafeArea(
      child: ListView(
        children: [
          for (var i = 0; i < 40; i++) ListTile(title: Text('Row $i')),
          TextButton(
            key: const ValueKey('last-action'),
            onPressed: () => actions++,
            child: const Text('Last'),
          ),
        ],
      ),
    ),
    bottomNavigationBar: selecting
        ? MediaLibrarySelectionBottomBar.folders(
            onMoveToRecycleBin: () => actions++,
            onExportFluentPack: () => actions++,
            onRename: () => actions++,
          )
        : null,
  );
}

Future<Color> _pixel(WidgetTester tester, GlobalKey key, Offset point) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return Color.fromARGB(
        data.getUint8(offset + 3),
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MediaPlaybackService playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
    playback = MediaPlaybackService();
    await playback.stop();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'safe-area',
        path: 'clip.mp4',
        title: 'Clip',
        durationMs: 120000,
        lastUpdated: 0,
      ),
      Duration.zero,
    );
  });

  tearDown(() async {
    await playback.stop();
    SettingsService().resetForTest();
  });

  const profiles = [
    (
      name: 'compact phone',
      size: Size(320, 568),
      padding: EdgeInsets.only(top: 24),
      ratio: 1.0,
      gesture: 0.0,
    ),
    (
      name: 'notched phone',
      size: Size(390, 844),
      padding: EdgeInsets.only(top: 59, bottom: 34),
      ratio: 3.0,
      gesture: 20.0,
    ),
    (
      name: 'three-button phone',
      size: Size(412, 915),
      padding: EdgeInsets.only(top: 28, bottom: 48),
      ratio: 2.0,
      gesture: 0.0,
    ),
    (
      name: 'landscape side navigation',
      size: Size(844, 390),
      padding: EdgeInsets.only(left: 44, right: 48),
      ratio: 2.0,
      gesture: 0.0,
    ),
    (
      name: 'gesture-only metrics',
      size: Size(430, 932),
      padding: EdgeInsets.only(top: 32),
      ratio: 3.0,
      gesture: 24.0,
    ),
    (
      name: 'portrait tablet',
      size: Size(834, 1194),
      padding: EdgeInsets.only(top: 24, bottom: 20),
      ratio: 2.0,
      gesture: 20.0,
    ),
    (
      name: 'tablet taskbar',
      size: Size(1194, 834),
      padding: EdgeInsets.only(top: 24, bottom: 80),
      ratio: 1.5,
      gesture: 24.0,
    ),
    (
      name: 'split view',
      size: Size(375, 1024),
      padding: EdgeInsets.only(top: 24, bottom: 20),
      ratio: 2.0,
      gesture: 20.0,
    ),
  ];

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final profile in profiles) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$platform ${profile.name} text=$scale: colors, card, selection and last row',
          (tester) async {
            final size = profile.size;
            final padding = profile.padding;
            final ratio = profile.ratio;
            tester.view.devicePixelRatio = ratio;
            tester.view.physicalSize = size * ratio;
            final physicalPadding = FakeViewPadding(
              top: padding.top * ratio,
              bottom: padding.bottom * ratio,
              left: padding.left * ratio,
              right: padding.right * ratio,
            );
            tester.view.padding = physicalPadding;
            tester.view.viewPadding = physicalPadding;
            tester.view.systemGestureInsets = FakeViewPadding(
              bottom: profile.gesture * ratio,
            );
            addTearDown(tester.view.reset);
            final boundary = GlobalKey();
            await tester.pumpWidget(
              ChangeNotifierProvider.value(
                value: playback,
                child: MaterialApp(
                  theme: ThemeData.dark(useMaterial3: true),
                  builder: (_, child) => MediaQuery.withClampedTextScaling(
                    minScaleFactor: scale,
                    maxScaleFactor: scale,
                    child: MobileSystemNavigationBar(
                      child: RepaintBoundary(key: boundary, child: child!),
                    ),
                  ),
                  home: const MediaLibraryShell(home: _LibraryPage()),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final state = tester.state<_LibraryPageState>(
              find.byType(_LibraryPage),
            );
            final card = find.byType(MiniPlaybackCard);
            final bottom = math.max(padding.bottom, profile.gesture);
            final rect = tester.getRect(card);
            expect(rect.left, 0);
            expect(rect.right, closeTo(size.width, .01));
            expect(rect.bottom, closeTo(size.height - bottom - 6, .01));
            final slider = tester.getRect(find.byType(Slider));
            expect(slider.left, greaterThanOrEqualTo(padding.left));
            expect(slider.right, lessThanOrEqualTo(size.width - padding.right));
            expect(
              await _pixel(tester, boundary, Offset(size.width / 2, 0)),
              AppTokens.bgBase,
            );
            expect(
              await _pixel(
                tester,
                boundary,
                Offset(size.width / 2, size.height - 1),
              ),
              AppTokens.bgCard,
            );

            final scroll = tester.state<ScrollableState>(
              find.descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              ),
            );
            // Jump to the end and let lazy slivers finish measuring. This
            // tests the content reservation independently of bounce physics.
            for (var i = 0; i < 2; i++) {
              scroll.position.jumpTo(scroll.position.maxScrollExtent);
              await tester.pumpAndSettle();
            }
            expect(
              tester.getRect(find.byKey(const ValueKey('last-action'))).bottom,
              lessThanOrEqualTo(rect.top + .1),
            );
            await tester.tap(find.byKey(const ValueKey('last-action')));
            expect(state.actions, 1);

            await tester.tap(find.byKey(const ValueKey('toggle-selection')));
            await tester.pumpAndSettle();
            final bar = tester.getRect(
              find.byType(MediaLibrarySelectionBottomBar),
            );
            expect(tester.getRect(card).bottom, closeTo(bar.top - 6, .1));
            expect(
              await _pixel(
                tester,
                boundary,
                Offset(size.width / 2, size.height - 1),
              ),
              AppTokens.bgRaised,
            );
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(
              tester.getRect(find.byKey(const ValueKey('last-action'))).bottom,
              lessThanOrEqualTo(tester.getRect(card).top + .1),
            );
            final recycle = find.descendant(
              of: find.byType(MediaLibrarySelectionBottomBar),
              matching: find.byIcon(Icons.delete),
            );
            expect(recycle.hitTestable(), findsOneWidget);
            expect(
              tester.getRect(recycle).bottom,
              lessThanOrEqualTo(size.height - bottom),
            );
            await tester.tap(recycle);
            expect(state.actions, 2);

            await tester.tap(find.byKey(const ValueKey('toggle-selection')));
            await tester.pumpAndSettle();
            expect(tester.getRect(card).bottom, closeTo(rect.bottom, .01));
            unawaited(
              SettingsService().updateSetting('showMiniPlaybackCard', false),
            );
            await tester.pumpAndSettle();
            expect(tester.getSize(card).height, 0);
            expect(
              await _pixel(
                tester,
                boundary,
                Offset(size.width / 2, size.height - 1),
              ),
              AppTokens.bgBase,
            );
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(platform),
        );
      }
    }
  }

  testWidgets('selection remeasures after text and window changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
    addTearDown(tester.view.reset);
    final scale = ValueNotifier(1.0);
    addTearDown(scale.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          builder: (_, child) => ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (_, value, child) => MediaQuery.withClampedTextScaling(
              minScaleFactor: value,
              maxScaleFactor: value,
              child: child!,
            ),
            child: child,
          ),
          home: const MediaLibraryShell(home: _LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-selection')));
    await tester.pumpAndSettle();
    final card = find.byType(MiniPlaybackCard);
    final bar = find.byType(MediaLibrarySelectionBottomBar);
    final previousHeight = tester.getSize(bar).height;
    scale.value = 2;
    await tester.pumpAndSettle();
    // The action row now stays bounded and scales its labels to fit. Its
    // obstruction must still be measured after both text and window changes.
    expect(tester.getSize(bar).height, greaterThanOrEqualTo(previousHeight));
    expect(
      tester.getRect(card).bottom,
      closeTo(tester.getRect(bar).top - 6, .1),
    );
    tester.view.physicalSize = const Size(844, 390);
    tester.view.padding = const FakeViewPadding(left: 44, right: 48);
    tester.view.viewPadding = const FakeViewPadding(left: 44, right: 48);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(card).bottom,
      closeTo(tester.getRect(bar).top - 6, .1),
    );
    expect(tester.getRect(find.byType(Slider)).left, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a centered tablet pane extends its own colors and preserves gutters',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(834, 1194);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      const panelColor = Color(0xFF1E1E1E);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: MobileSystemBarSurface(
                    topColor: Colors.black,
                    bottomColor: panelColor,
                    child: SafeArea(
                      child: ColoredBox(
                        color: panelColor,
                        child: Center(
                          child: TextButton(
                            onPressed: () {},
                            child: const Text('Action'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        await _pixel(tester, boundary, const Offset(417, 0)),
        Colors.black,
      );
      expect(
        await _pixel(tester, boundary, const Offset(417, 1193)),
        panelColor,
      );
      expect(
        await _pixel(tester, boundary, const Offset(10, 1193)),
        Colors.black,
      );
      expect(find.text('Action').hitTestable(), findsOneWidget);
    },
  );
}
