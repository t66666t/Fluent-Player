import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_view_mode.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/hardware_keyboard_shortcuts.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  setUp(() => mediaLibraryAlternateViewsEnabled = true);
  tearDown(() => mediaLibraryAlternateViewsEnabled = false);

  testWidgets('home and collection grids and lists support keyboard selection', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'onboarding.handled.v1': true});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await library.createCollection('Parent', null, id: 'parent');
    for (var i = 0; i < 4; i++) {
      await library.createCollection('Root $i', null, id: 'root$i');
      await library.createCollection('Child $i', 'parent', id: 'child$i');
    }
    final playback = MediaPlaybackService();
    await playback.stop();
    addTearDown(() async {
      await playback.stop();
      library.resetLibraryForTesting();
      settings.resetForTest();
    });

    Widget app(Widget page) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: BatchImportService()),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: MediaLibraryShell(home: page),
      ),
    );

    await tester.pumpWidget(app(const HomeScreen()));
    await tester.pumpAndSettle();
    tester
        .widget<MediaLibraryEntrySwitcher>(
          find.byType(MediaLibraryEntrySwitcher),
        )
        .onSelected(MediaLibraryRootEntry.folders);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final firstCard = _focusedCard(tester);
    expect(firstCard, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<MediaLibraryEntrySwitcher>(),
      isNotNull,
      reason: 'the first row must lead to the page switcher',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedCard(tester), firstCard);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final switcherContext = find.byType(MediaLibraryEntrySwitcher);
    final continueLabel = find.descendant(
      of: switcherContext,
      matching: find.text('继续学习'),
    );
    expect(Focus.of(tester.element(continueLabel)).hasPrimaryFocus, isTrue);
    expect(
      find.ancestor(
        of: continueLabel,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border?.top.color ==
                  Colors.lightBlueAccent,
        ),
      ),
      findsOneWidget,
    );
    final outline = find.ancestor(
      of: continueLabel,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border?.top.color ==
                Colors.lightBlueAccent,
      ),
    );
    final outlineRect = tester.getRect(outline);
    final labelRect = tester.getRect(continueLabel);
    expect(labelRect.left - outlineRect.left, greaterThanOrEqualTo(4));
    expect(
      ((labelRect.left - outlineRect.left) -
              (outlineRect.right - labelRect.right))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'the leading label must be centered inside its focus outline',
    );
    final focusBoundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(of: continueLabel, matching: find.byType(RepaintBoundary))
          .first,
    );
    final bluePixels = await tester.runAsync(() async {
      final focusImage = await focusBoundary.toImage();
      final focusPixels = await focusImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      var count = 0;
      // Sample the top edge itself, so the existing blue underline cannot
      // make this test pass when the surrounding focus outline is missing.
      for (var y = 0; y < 3 && y < focusImage.height; y++) {
        for (
          var x = focusImage.width ~/ 4;
          x < focusImage.width * 3 ~/ 4;
          x++
        ) {
          final offset = (y * focusImage.width + x) * 4;
          if (focusPixels!.getUint8(offset) < 150 &&
              focusPixels.getUint8(offset + 1) > 150 &&
              focusPixels.getUint8(offset + 2) > 200 &&
              focusPixels.getUint8(offset + 3) > 200) {
            count++;
          }
        }
      }
      focusImage.dispose();
      return count;
    });
    expect(
      bluePixels,
      greaterThan(4),
      reason: 'the focused entry must paint a visible blue border',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MediaLibraryEntrySwitcher>(switcherContext).selected,
      MediaLibraryRootEntry.continueLearning,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final foldersLabel = find.descendant(
      of: switcherContext,
      matching: find.text('文件夹'),
    );
    expect(Focus.of(tester.element(foldersLabel)).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MediaLibraryEntrySwitcher>(switcherContext).selected,
      MediaLibraryRootEntry.folders,
    );
    expect(_focusedCard(tester), firstCard);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final remembered = _focusedCard(tester);
    expect(remembered, isNotNull);
    final switcher = tester.widget<MediaLibraryEntrySwitcher>(
      find.byType(MediaLibraryEntrySwitcher),
    );
    final nextEntry =
        switcher.entries[(switcher.entries.indexOf(
                  MediaLibraryRootEntry.folders,
                ) +
                1) %
            switcher.entries.length];
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MediaLibraryEntrySwitcher>(
            find.byType(MediaLibraryEntrySwitcher),
          )
          .selected,
      nextEntry,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MediaLibraryEntrySwitcher>(
            find.byType(MediaLibraryEntrySwitcher),
          )
          .selected,
      MediaLibraryRootEntry.folders,
    );
    expect(_focusedCard(tester), remembered);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    for (final home in [true, false]) {
      for (final listMode in [false, true]) {
        settings.mediaLibraryViewMode = listMode ? 1 : 0;
        await tester.pumpWidget(
          app(
            home
                ? const HomeScreen(returnToSearchResults: true)
                : const CollectionScreen(collectionId: 'parent'),
          ),
        );
        await tester.pumpAndSettle();
        if (_focusedCard(tester) == null) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
        }
        final focusedBefore = _focusedCard(tester);
        expect(focusedBefore, isNotNull, reason: '$home $listMode');
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(_card(tester, focusedBefore!).selected, isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        final ids = home
            ? ['parent', 'root0', 'root1', 'root2', 'root3']
            : ['child0', 'child1', 'child2', 'child3'];
        for (final id in ids) {
          expect(_card(tester, id).selected, isTrue, reason: id);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_focusedCard(tester), focusedBefore);
        if (home && !listMode) {
          final parentCard = find.byWidgetPredicate(
            (widget) =>
                widget is MediaLibraryKeyboardItem && widget.itemId == 'parent',
          );
          final parentFocus = find.descendant(
            of: parentCard.first,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Focus &&
                  widget.focusNode?.debugLabel == 'library card',
            ),
          );
          tester.widget<Focus>(parentFocus.first).focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(CollectionScreen), findsOneWidget);
          expect(_focusedCard(tester), startsWith('child'));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(CollectionScreen), findsNothing);
          expect(_focusedCard(tester), 'parent');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }

    debugNativeTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugNativeTargetPlatformOverride = null);
    settings.mediaLibraryViewMode = 0;
    await tester.pumpWidget(app(const HomeScreen(returnToSearchResults: true)));
    await tester.pumpAndSettle();
    Future<void> androidKey(int code, {bool settle = true}) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.example.video_player_app/hardware_input',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('keyEvent', {
            'keyCode': code,
            'action': 0,
            'eventTime': 20,
          }),
        ),
        (_) {},
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    if (_focusedCard(tester) == null) {
      await androidKey(20); // Down enters the first card.
    }
    final androidCard = _focusedCard(tester);
    expect(
      androidCard,
      isNotNull,
      reason:
          'focus: ${FocusManager.instance.primaryFocus}; cards: ${find.byType(MediaLibraryKeyboardItem).evaluate().length}',
    );
    await androidKey(30); // B enters selection.
    await androidKey(62, settle: false); // Space selects the focused card.
    expect(_card(tester, androidCard!).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // Same physical key.
    await tester.pumpAndSettle();
    expect(_card(tester, androidCard).selected, isTrue);
    await tester.pumpWidget(const SizedBox());
    debugNativeTargetPlatformOverride = null;
  });
}

MediaLibraryKeyboardItem _card(WidgetTester tester, String id) => tester.widget(
  find
      .byWidgetPredicate(
        (widget) => widget is MediaLibraryKeyboardItem && widget.itemId == id,
      )
      .first,
);

String? _focusedCard(WidgetTester tester) {
  for (final element in tester.elementList(
    find.byType(MediaLibraryKeyboardItem),
  )) {
    final item = element.widget as MediaLibraryKeyboardItem;
    final focus = find.descendant(
      of: find.byWidget(item),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Focus && widget.focusNode?.debugLabel == 'library card',
      ),
    );
    if (focus.evaluate().isNotEmpty &&
        tester.widget<Focus>(focus.first).focusNode!.hasPrimaryFocus) {
      return item.itemId;
    }
  }
  return null;
}
