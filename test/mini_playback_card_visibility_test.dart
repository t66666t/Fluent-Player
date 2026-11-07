import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/mobile_system_navigation_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late MediaPlaybackService playback;
  late GlobalKey<NavigatorState> navigatorKey;
  late GlobalKey boundaryKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'showMiniPlaybackCard': false,
    });
    settings = SettingsService()..resetForTest();
    await settings.init();
    playback = MediaPlaybackService();
    await playback.stop();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'visibility-clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 120000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 4),
    );
    navigatorKey = GlobalKey<NavigatorState>();
    boundaryKey = GlobalKey();
  });

  tearDown(() async {
    await playback.stop();
    settings.resetForTest();
  });

  Future<void> pumpLibrary(
    WidgetTester tester,
    Size size,
    double bottomInset,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [AppToast.routeObserver],
          theme: ThemeData.dark(useMaterial3: true),
          builder: (_, child) => MobileSystemNavigationBar(child: child!),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: EdgeInsets.only(bottom: bottomInset),
              viewPadding: EdgeInsets.only(bottom: bottomInset),
              systemGestureInsets: EdgeInsets.only(bottom: bottomInset),
            ),
            child: RepaintBoundary(
              key: boundaryKey,
              child: MediaLibraryShell(
                home: Scaffold(
                  backgroundColor: AppTokens.bgBase,
                  body: Builder(
                    builder: (context) => Center(
                      child: TextButton(
                        onPressed: () => showMediaLibrarySettingsBottomSheet(
                          context,
                          settings,
                        ),
                        child: const Text('Open library settings'),
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
  }

  Future<Uint8List> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage().timeout(
        const Duration(seconds: 10),
      );
      try {
        final data = await image
            .toByteData(format: ui.ImageByteFormat.rawRgba)
            .timeout(const Duration(seconds: 10));
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;
  }

  void expectHidden(WidgetTester tester) {
    expect(playback.shouldShowMiniPlaybackCard, isFalse);
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('播放列表'), findsNothing);
    expect(tester.getSize(find.byType(MiniPlaybackCard)).height, 0);
    expect(tester.takeException(), isNull);
  }

  void setVisible(bool visible) {
    // Match the settings sheet: update UI synchronously, persist separately.
    unawaited(settings.updateSetting('showMiniPlaybackCard', visible));
  }

  for (final viewport in [
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.android, const Size(900, 1200)),
    (TargetPlatform.android, const Size(1200, 900)),
    (TargetPlatform.iOS, const Size(390, 844)),
  ]) {
    testWidgets(
      '${viewport.$1} ${viewport.$2}: bottom colors stay continuous',
      (tester) async {
        final size = viewport.$2;
        await pumpLibrary(tester, size, 32);

        Future<void> expectBottomColor(int firstRow, Color color) async {
          final data = await pixels(tester);
          final x = size.width ~/ 2;
          for (var y = firstRow; y < size.height.toInt(); y++) {
            final offset = (y * size.width.toInt() + x) * 4;
            expect(data.sublist(offset, offset + 4), [
              (color.toARGB32() >> 16) & 255,
              (color.toARGB32() >> 8) & 255,
              color.toARGB32() & 255,
              255,
            ], reason: 'background at row $y');
          }
        }

        await expectBottomColor(size.height.toInt() - 32, AppTokens.bgBase);
        setVisible(true);
        await tester.pumpAndSettle();
        final cardBottom = tester
            .getBottomRight(find.byType(MiniPlaybackCard))
            .dy;
        // Include the card's bottom padding, the entire gap and the safe area.
        // A shadow painted over the fill would make the first gap rows darker.
        await expectBottomColor(cardBottom.floor() - 2, AppTokens.bgCard);
        setVisible(false);
        await tester.pumpAndSettle();
        await expectBottomColor(size.height.toInt() - 32, AppTokens.bgBase);
      },
      variant: TargetPlatformVariant.only(viewport.$1),
    );
  }

  for (final viewport in <({String name, Size size, double inset})>[
    (name: 'phone', size: const Size(390, 844), inset: 0),
    (name: 'Android tablet', size: const Size(900, 1200), inset: 24),
    (name: 'desktop', size: const Size(1440, 900), inset: 48),
  ]) {
    testWidgets(
      '${viewport.name}: disabled card leaves no pixels or controls',
      (tester) async {
        await pumpLibrary(tester, viewport.size, viewport.inset);
        expectHidden(tester);
        final blank = await pixels(tester);
        final cardState = tester.state(find.byType(MiniPlaybackCard));

        setVisible(true);
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsOneWidget);
        expect(listEquals(await pixels(tester), blank), isFalse);
        final position = playback.position;
        final state = playback.state;

        setVisible(false);
        // The first rebuilt frame must already be completely blank.
        await tester.pump();
        expectHidden(tester);
        expect(listEquals(await pixels(tester), blank), isTrue);
        expect(playback.currentItem?.id, 'visibility-clip');
        expect(playback.position, position);
        expect(playback.state, state);

        // Switch off midway through a new slide-in, then reopen successfully.
        setVisible(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        setVisible(false);
        await tester.pump();
        expectHidden(tester);
        expect(listEquals(await pixels(tester), blank), isTrue);
        setVisible(true);
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsOneWidget);
        expect(tester.state(find.byType(MiniPlaybackCard)), same(cardState));
        setVisible(false);
        await tester.pumpAndSettle();
        expectHidden(tester);
        expect(listEquals(await pixels(tester), blank), isTrue);
      },
    );
  }

  testWidgets(
    'tablet settings switch fully hides card after sheet is dismissed',
    (tester) async {
      await pumpLibrary(tester, const Size(900, 1200), 48);
      final blank = await pixels(tester);
      setVisible(true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open library settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('showMiniPlaybackCard')));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expectHidden(tester);
      expect(listEquals(await pixels(tester), blank), isTrue);
    },
  );

  testWidgets('switching off while covered cannot resume a hidden animation', (
    tester,
  ) async {
    await pumpLibrary(tester, const Size(900, 1200), 24);
    final blank = await pixels(tester);
    setVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Playback page')),
      ),
    );
    await tester.pumpAndSettle();
    setVisible(false);
    await tester.pump();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expectHidden(tester);
    expect(listEquals(await pixels(tester), blank), isTrue);
  });

  testWidgets('search and rapid nested navigation preserve the card state', (
    tester,
  ) async {
    await pumpLibrary(tester, const Size(390, 844), 24);
    setVisible(true);
    await tester.pumpAndSettle();
    final card = tester.state(find.byType(MiniPlaybackCard));
    final shellContext = tester.element(find.byType(MiniPlaybackCard));
    final nested = MediaLibraryShell.maybeOf(shellContext)!.libraryNavigator!;
    for (var i = 0; i < 5; i++) {
      unawaited(
        nested.push(
          buildMediaLibrarySearchResultsRoute(
            const Scaffold(body: Text('Search results')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.state(find.byType(MiniPlaybackCard)), same(card));
      unawaited(
        nested.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Folder')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
      nested.pop();
      await tester.pump(const Duration(milliseconds: 30));
      nested.pop();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(MiniPlaybackCard)), same(card));
      expect(find.text('clip'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'covered card freezes title, subtitle and progress until return',
    (tester) async {
      await pumpLibrary(tester, const Size(390, 844), 24);
      setVisible(true);
      playback.setSubtitles([
        SubtitleItem(
          index: 0,
          startTime: Duration.zero,
          endTime: const Duration(minutes: 2),
          text: 'Old primary subtitle',
        ),
      ]);
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      final previousSync = playback.beforeLibraryPlayback;
      playback.beforeLibraryPlayback = (_) => gate.future;
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Player')),
          ),
        ),
      );
      final pending = playback.play(
        VideoItem(
          id: 'next-episode',
          path: 'next.mp4',
          title: 'Next episode',
          durationMs: 90000,
          lastUpdated: 0,
        ),
        startPosition: const Duration(seconds: 25),
      );
      try {
        playback.setSubtitles([
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(minutes: 2),
            text: 'New primary subtitle',
          ),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final card = find.byType(MiniPlaybackCard, skipOffstage: false);
        Finder textInCard(String value) => find.descendant(
          of: card,
          matching: find.text(value, skipOffstage: false),
        );
        expect(textInCard('clip'), findsOneWidget);
        expect(textInCard('Old primary subtitle'), findsOneWidget);
        expect(textInCard('00:04 / 02:00'), findsOneWidget);
        expect(textInCard('Next episode'), findsNothing);
        await playback.cancelPendingPlay(keepBookmark: true);
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Next episode'), findsOneWidget);
        expect(find.text('New primary subtitle'), findsOneWidget);
        expect(find.text('00:25 / 01:30'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        playback.beforeLibraryPlayback = previousSync;
        gate.complete();
        await pending;
      }
      expect(playback.currentItem?.id, 'next-episode');
      expect(playback.shouldShowMiniPlaybackCard, isTrue);
    },
  );

  testWidgets(
    'removing a cover and interrupting entry recovers a settled card',
    (tester) async {
      await pumpLibrary(tester, const Size(390, 844), 24);
      setVisible(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final cover = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Cover')),
      );
      unawaited(navigatorKey.currentState!.push(cover));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.removeRoute(cover);
      await tester.pumpAndSettle();
      final card = find.byType(MiniPlaybackCard);
      final slide = tester.widget<SlideTransition>(
        find.descendant(of: card, matching: find.byType(SlideTransition)).first,
      );
      expect(slide.position.value, Offset.zero);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('clip'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
