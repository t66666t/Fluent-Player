import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

const _longTitle =
    'A long playback title with enough words to scroll continuously through '
    'the mini playback card when returning from another page';

void main() {
  late MediaPlaybackService playback;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    playback = MediaPlaybackService();
    await playback.stop();
    navigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    await playback.stop();
    SettingsService().resetForTest();
  });

  Future<void> pumpLibrary(
    WidgetTester tester, {
    String title = 'clip',
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'title-continuity',
        path: 'podcast:title-continuity',
        title: title,
        durationMs: 120000,
        lastUpdated: 0,
        type: MediaType.audio,
      ),
      const Duration(seconds: 4),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [AppToast.routeObserver],
          theme: ThemeData.dark().copyWith(
            pageTransitionsTheme: appPageTransitionsTheme,
            textTheme: ThemeData.dark().textTheme
                .apply(fontFamily: 'Ahem', bodyColor: Colors.white)
                .copyWith(
                  bodyMedium: const TextStyle(
                    fontFamily: 'Ahem',
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1.2,
                  ),
                ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          onGenerateRoute: (settings) => buildMediaLibraryShellRoute<void>(
            settings: settings,
            home: const Scaffold(body: Text('library')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder card() => find.byType(MiniPlaybackCard, skipOffstage: false);

  Finder titleText(String title) => find.descendant(
    of: card(),
    matching: find.text(title, skipOffstage: false),
  );

  double titleOffset(WidgetTester tester, String title) {
    final transform = find
        .ancestor(
          of: titleText(title).first,
          matching: find.byType(Transform, skipOffstage: false),
        )
        .first;
    return tester.widget<Transform>(transform).transform.storage[12];
  }

  void expectLiveCard(WidgetTester tester) {
    final route = ModalRoute.of(tester.element(card()))!;
    expect(route.allowSnapshotting, isFalse);
    final snapshots = find.ancestor(
      of: card(),
      matching: find.byType(SnapshotWidget, skipOffstage: false),
    );
    // A live transition can retain paint layers without creating snapshots.
    // If a transition does create them, the moving title must stay live.
    for (final snapshot in tester.widgetList<SnapshotWidget>(snapshots)) {
      expect(
        snapshot.controller.allowSnapshotting,
        isFalse,
        reason: 'A frozen route snapshot must never replace the moving title.',
      );
    }
  }

  Future<void> pushCover(WidgetTester tester, Route<void> cover) async {
    unawaited(navigatorKey.currentState!.push(cover));
    // Start one actual motion frame before fast-forwarding. A long initial
    // frame now preserves the fade rather than consuming the whole entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('return transition paints the library live', (tester) async {
    await pumpLibrary(tester);
    final libraryRoute = ModalRoute.of(tester.element(card()))!;
    expect(libraryRoute.settings.name, Navigator.defaultRouteName);
    expect(libraryRoute.isFirst, isTrue);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    final cover = AppMaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('cover')),
    );
    await pushCover(tester, cover);
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(cover.animation!.status, AnimationStatus.reverse);
    expectLiveCard(tester);
    // Covering pages retain their own snapshot permission. A builder can
    // instead choose live paint layers, so snapshots need not be present.
    expect(cover.allowSnapshotting, isTrue);
    final coverSnapshots = find.ancestor(
      of: find.text('cover'),
      matching: find.byType(SnapshotWidget),
    );
    if (coverSnapshots.evaluate().isNotEmpty) {
      expect(
        tester
            .widgetList<SnapshotWidget>(coverSnapshots)
            .any((snapshot) => snapshot.controller.allowSnapshotting),
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long title measures the painted text and loops without drift', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
    expect(titleText(_longTitle), findsNWidgets(2));
    final titleWidth = tester.getSize(titleText(_longTitle).first).width;
    final before = titleOffset(tester, _longTitle);
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      titleOffset(tester, _longTitle),
      closeTo(before - (titleWidth + 50) * 0.080 / 20, 0.001),
    );
    final phase = titleOffset(tester, _longTitle);
    await tester.pump(const Duration(seconds: 20));
    expect(titleOffset(tester, _longTitle), closeTo(phase, 0.001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final viewport in [
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.iOS, const Size(390, 844)),
    (TargetPlatform.android, const Size(900, 1200)),
    (TargetPlatform.windows, const Size(1440, 900)),
  ]) {
    for (final playbackPage in [false, true]) {
      testWidgets('${viewport.$1} ${viewport.$2}, playback=$playbackPage: '
          'title pauses while covered and returns without a skipped frame', (
        tester,
      ) async {
        await pumpLibrary(tester, title: _longTitle, size: viewport.$2);
        expect(tester.takeException(), isNull);
        final state = tester.state(card());
        final titleWidth = tester.getSize(titleText(_longTitle).first).width;
        final step = (titleWidth + 50) * 0.016 / 20;
        final cover = playbackPage
            ? PlaybackNavigationService.buildPlaybackPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('cover')),
              )
            : AppMaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('cover')),
              );
        await pushCover(tester, cover);
        expect(cover.animation!.status, AnimationStatus.completed);
        final hiddenOffset = titleOffset(tester, _longTitle);
        await tester.pump(const Duration(minutes: 3));
        expect(titleOffset(tester, _longTitle), hiddenOffset);

        navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump();
        expect(titleOffset(tester, _longTitle), closeTo(hiddenOffset, 0.001));
        for (var frame = 0; frame < 24; frame++) {
          final before = titleOffset(tester, _longTitle);
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            titleOffset(tester, _longTitle),
            closeTo(before - step, 0.001),
            reason:
                'frame $frame must move by exactly one frame, including '
                'the end of the return zoom',
          );
          expectLiveCard(tester);
          expect(tester.state(card()), same(state));
          expect(tester.takeException(), isNull);
        }
        expect(playback.position, const Duration(seconds: 4));
        expect(playback.state, PlaybackState.paused);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(viewport.$1));
    }
  }

  testWidgets('large text uses the same measurement as the looping copies', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle, textScale: 1.8);
    final width = tester.getSize(titleText(_longTitle).first).width;
    final before = titleOffset(tester, _longTitle);
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      titleOffset(tester, _longTitle),
      closeTo(before - (width + 50) * 0.080 / 20, 0.001),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('folder and search navigation keep the long title moving', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle);
    final shell = MediaLibraryShell.maybeOf(tester.element(card()))!;
    final nested = shell.libraryNavigator!;
    final state = tester.state(card());
    final width = tester.getSize(titleText(_longTitle).first).width;
    for (final route in [
      buildMediaLibraryFolderRoute<void>(
        folderId: 'folder',
        builder: (_) => const Scaffold(body: Text('folder')),
      ),
      buildMediaLibrarySearchResultsRoute(const Scaffold(body: Text('search'))),
    ]) {
      unawaited(nested.push(route));
      await tester.pump();
      for (var frame = 0; frame < 24; frame++) {
        final before = titleOffset(tester, _longTitle);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          titleOffset(tester, _longTitle),
          closeTo(before - (width + 50) * 0.016 / 20, 0.001),
        );
        expect(tester.state(card()), same(state));
      }
      nested.pop();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new media and shorter titles reset only their own scroll', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle);
    final state = tester.state(card());
    await tester.pump(const Duration(seconds: 2));
    expect(titleOffset(tester, _longTitle), lessThan(0));

    for (final (id, title) in [
      ('next-episode', 'The next episode: $_longTitle'),
      // A metadata rename on the same media also starts at its first letter.
      ('next-episode', 'Renamed: $_longTitle'),
      ('short-episode', 'Short'),
      ('long-again', _longTitle),
    ]) {
      await playback.stop();
      playback.publishRestoredSessionPreview(
        VideoItem(
          id: id,
          path: 'podcast:$id',
          title: title,
          durationMs: 120000,
          lastUpdated: 0,
          type: MediaType.audio,
        ),
        const Duration(seconds: 4),
      );
      await tester.pump();
      expect(tester.state(card()), same(state));
      if (title == 'Short') {
        expect(titleText(title), findsOneWidget);
        await tester.pumpAndSettle();
      } else {
        expect(titleOffset(tester, title), 0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(titleOffset(tester, title), lessThan(0));
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long title stops when disabled and reopens from the beginning', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle);
    final state = tester.state(card());
    final settings = SettingsService();
    await settings.updateSetting('showMiniPlaybackCard', false);
    await tester.pumpAndSettle();
    expect(tester.getSize(card()).height, 0);
    expect(titleText(_longTitle), findsNothing);

    await settings.updateSetting('showMiniPlaybackCard', true);
    await tester.pump();
    expect(titleOffset(tester, _longTitle), 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(titleOffset(tester, _longTitle), lessThan(0));
    expect(tester.state(card()), same(state));
    expect(playback.position, const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interrupting and removing cover routes never catches up time', (
    tester,
  ) async {
    await pumpLibrary(tester, title: _longTitle);
    final state = tester.state(card());
    final width = tester.getSize(titleText(_longTitle).first).width;
    final step = (width + 50) * 0.016 / 20;
    for (var iteration = 0; iteration < 4; iteration++) {
      final cover = AppMaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('cover')),
      );
      unawaited(navigatorKey.currentState!.push(cover));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump();
      for (var frame = 0; frame < 24; frame++) {
        final before = titleOffset(tester, _longTitle);
        await tester.pump(const Duration(milliseconds: 16));
        expect(titleOffset(tester, _longTitle), closeTo(before - step, 0.001));
      }

      final removed = AppMaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('removed')),
      );
      await pushCover(tester, removed);
      final hidden = titleOffset(tester, _longTitle);
      await tester.pump(const Duration(seconds: 40));
      navigatorKey.currentState!.removeRoute(removed);
      await tester.pump();
      await tester.pump();
      expect(titleOffset(tester, _longTitle), closeTo(hidden, 0.001));
      await tester.pump(const Duration(milliseconds: 16));
      expect(titleOffset(tester, _longTitle), closeTo(hidden - step, 0.001));
      expect(tester.state(card()), same(state));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
