import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

const _labels = ['继续学习', '文件夹', '最近添加', '哔哩哔哩'];

/// Root home has no leading button. Its title shares the card-grid inset,
/// with two 40 px actions (search and more) while the sleep timer is inactive.
Widget _homeTopBar({
  required MediaLibraryRootEntry selected,
  required ValueChanged<MediaLibraryRootEntry> onSelected,
  bool reorder = true,
  bool compact = true,
  double? highlightIndex,
  bool settled = true,
  Widget? body,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final inset = MediaLibraryLayoutDefaults.distributeWidth(
          availableWidth: size.width,
          columns: MediaLibraryLayoutDefaults.defaultCardCrossAxisCount(size),
          spacingScale: MediaLibraryLayoutDefaults.defaultSpacingScale,
        ).outerPadding;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: compact ? 44 : 48,
            automaticallyImplyLeading: false,
            titleSpacing: inset,
            title: MediaLibraryEntrySwitcher(
              selected: selected,
              highlightIndex: highlightIndex,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              compact: compact,
              reorderEnabled: reorder && settled,
              onReorder: reorder ? (_, _) {} : null,
              onSelected: onSelected,
            ),
            actions: [
              for (var i = 0; i < 2; i++) const SizedBox(width: 40, height: 44),
            ],
          ),
          body: body,
        );
      },
    ),
  );
}

Future<void> _setWidth(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder get _tabScroller => find
    .descendant(
      of: find.byType(MediaLibraryEntrySwitcher),
      matching: find.byType(Scrollable),
    )
    .first;

Rect _viewport(WidgetTester tester) => tester.getRect(_tabScroller);

bool _fullyInside(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5;

void _expectReadable(WidgetTester tester) {
  for (final label in _labels) {
    // Titles scrolled out of the row are still laid out at full size.
    final text = find.text(label, skipOffstage: false);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse, reason: label);
    // Rendered size, transforms included: never scaled below ~12 px.
    expect(
      tester.getRect(text).height,
      greaterThanOrEqualTo(12),
      reason: '$label is shrunk',
    );
    final style = tester.widget<Text>(text).style!;
    expect(style.fontSize, greaterThanOrEqualTo(13), reason: label);
  }
}

void main() {
  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets('home tabs at $width px: no overflow, readable, reachable', (
      tester,
    ) async {
      await _setWidth(tester, width);
      var selected = MediaLibraryRootEntry.folders;
      await tester.pumpWidget(
        _homeTopBar(selected: selected, onSelected: (e) => selected = e),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      _expectReadable(tester);
      final viewport = _viewport(tester);
      expect(viewport.right, lessThanOrEqualTo(width - 2 * 40 + 0.5));

      // Scroll from the viewport: a title may already be outside its clip.
      // Podcasts and cloud drive follow Bilibili in the current six-tab row.
      await tester.drag(_tabScroller, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_fullyInside(tester.getRect(find.text('网盘')), viewport), isTrue);
      await tester.tap(find.text('网盘'));
      await tester.pumpAndSettle();
      expect(selected, MediaLibraryRootEntry.cloudDrive);

      // Scrolling back shows the first tab whole.
      await tester.drag(_tabScroller, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(_fullyInside(tester.getRect(find.text('继续学习')), viewport), isTrue);
    });

    testWidgets('home tabs at $width px keep the selected tab in view', (
      tester,
    ) async {
      await _setWidth(tester, width);
      var selected = MediaLibraryRootEntry.continueLearning;
      late StateSetter setOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return _homeTopBar(
              selected: selected,
              onSelected: (e) => setState(() => selected = e),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final viewport = _viewport(tester);
      expect(_fullyInside(tester.getRect(find.text('继续学习')), viewport), isTrue);

      // Switching from elsewhere (a page swipe) brings the tab into view.
      setOuter(() => selected = MediaLibraryRootEntry.bilibili);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_fullyInside(tester.getRect(find.text('哔哩哔哩')), viewport), isTrue);
    });

    testWidgets('tabs without reordering at $width px are readable too', (
      tester,
    ) async {
      await _setWidth(tester, width);
      await tester.pumpWidget(
        _homeTopBar(
          selected: MediaLibraryRootEntry.folders,
          onSelected: (_) {},
          reorder: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _expectReadable(tester);
    });
  }

  for (final reorder in [true, false]) {
    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets('tabs follow swipe progress at $width px, reorder=$reorder', (
        tester,
      ) async {
        await _setWidth(tester, width);
        var selected = MediaLibraryRootEntry.folders;
        var highlight = 2.0;
        late StateSetter update;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return _homeTopBar(
                selected: selected,
                highlightIndex: highlight,
                reorder: reorder,
                onSelected: (entry) => setState(() => selected = entry),
              );
            },
          ),
        );
        await tester.pumpAndSettle();

        double titleX() => tester.getTopLeft(find.text('最近添加')).dx;
        Future<void> dragTo(double value) async {
          update(() => highlight = value);
          await tester.pump();
          await tester.pump();
        }

        final start = titleX();
        await dragTo(2.25);
        final quarter = titleX();
        expect(quarter, lessThan(start - 1));
        await dragTo(2.75);
        expect(titleX(), lessThan(quarter - 1));
        expect(selected, MediaLibraryRootEntry.folders);

        // Reversing the same drag retraces its viewport position immediately.
        await dragTo(2.25);
        expect(titleX(), closeTo(quarter, 0.5));
        await dragTo(2);
        expect(titleX(), closeTo(start, 0.5));

        // A single gesture can travel past several titles before committing.
        await dragTo(4.5);
        final cloudX = tester.getTopLeft(find.text('网盘')).dx;
        await dragTo(5);
        expect(
          tester.getTopLeft(find.text('网盘')).dx,
          lessThanOrEqualTo(cloudX),
        );
        expect(
          _fullyInside(tester.getRect(find.text('网盘')), _viewport(tester)),
          isTrue,
        );
        final parked = tester.getTopLeft(find.text('网盘')).dx;
        update(() => selected = MediaLibraryRootEntry.cloudDrive);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('网盘')).dx, closeTo(parked, 0.5));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('real page drags, reversals and snaps share the tab viewport', (
    tester,
  ) async {
    await _setWidth(tester, 360);
    var selected = MediaLibraryRootEntry.folders;
    final highlight = ValueNotifier<double>(1);
    final settled = ValueNotifier<bool>(true);
    addTearDown(highlight.dispose);
    addTearDown(settled.dispose);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return ValueListenableBuilder<double>(
            valueListenable: highlight,
            builder: (context, value, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: settled,
                builder: (context, parked, _) {
                  return _homeTopBar(
                    selected: selected,
                    highlightIndex: value,
                    settled: parked,
                    onSelected: (entry) => setState(() => selected = entry),
                    body: MediaLibraryRootSurfaceHost(
                      displayedEntry: selected,
                      swipeHighlightIndex: highlight,
                      swipeSettled: settled,
                      onUserSwipe: (entry) => setState(() => selected = entry),
                      continueBuilder: (_, _) => const SizedBox.expand(),
                      foldersBuilder: (_, _) => const SizedBox.expand(),
                      recentBuilder: (_, _) => const SizedBox.expand(),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    ScrollPosition position() =>
        tester.state<ScrollableState>(_tabScroller).position;
    final originalPosition = position();
    final start = position().pixels;
    final origin = tester.getCenter(find.byType(MediaLibraryRootSurfaceHost));
    final gesture = await tester.startGesture(origin);
    await gesture.moveBy(
      const Offset(-90, 0),
      timeStamp: const Duration(milliseconds: 200),
    );
    await tester.pump();
    await tester.pump();
    final forward = position().pixels;
    expect(forward, greaterThan(start + 1));
    expect(selected, MediaLibraryRootEntry.folders);
    expect(settled.value, isFalse);
    expect(position(), same(originalPosition));

    await gesture.moveBy(
      const Offset(45, 0),
      timeStamp: const Duration(milliseconds: 400),
    );
    await tester.pump();
    await tester.pump();
    final reverse = position().pixels;
    expect(reverse, greaterThan(start));
    expect(reverse, lessThan(forward));
    await gesture.up(timeStamp: const Duration(milliseconds: 800));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(position().pixels, lessThan(reverse));
    await tester.pumpAndSettle();
    expect(selected, MediaLibraryRootEntry.folders);
    expect(position().pixels, closeTo(start, 0.5));

    final commit = await tester.startGesture(origin);
    await commit.moveBy(
      const Offset(-180, 0),
      timeStamp: const Duration(milliseconds: 200),
    );
    await tester.pump();
    await tester.pump();
    final held = position().pixels;
    expect(held, greaterThan(start + 1));
    expect(selected, MediaLibraryRootEntry.folders);
    await commit.up(timeStamp: const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(position().pixels, greaterThan(held));
    await tester.pumpAndSettle();
    expect(selected, MediaLibraryRootEntry.recent);
    expect(
      _fullyInside(tester.getRect(find.text('最近添加')), _viewport(tester)),
      isTrue,
    );
    expect(position(), same(originalPosition));
    final finish = position().pixels;
    await tester.pump(const Duration(milliseconds: 250));
    expect(position().pixels, closeTo(finish, 0.01));
    expect(position().isScrollingNotifier.value, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wide screens keep the fixed row', (tester) async {
    await _setWidth(tester, 1000);
    await tester.pumpWidget(
      _homeTopBar(
        selected: MediaLibraryRootEntry.folders,
        onSelected: (_) {},
        compact: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final scrollable = tester.widget<Scrollable>(
      find
          .descendant(
            of: find.byType(MediaLibraryEntrySwitcher),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.physics, isA<NeverScrollableScrollPhysics>());
    final viewport = _viewport(tester);
    for (final label in _labels) {
      expect(_fullyInside(tester.getRect(find.text(label)), viewport), isTrue);
    }
  });
}
