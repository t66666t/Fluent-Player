import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_empty_state.dart';
import 'package:video_player_app/widgets/media_library_empty_viewport.dart';

void main() {
  for (final size in const [
    Size(390, 844),
    Size(844, 390),
    Size(768, 1024),
    Size(1440, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('empty content follows the usable area at $size x $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final bottom = ValueNotifier(0.0);
        addTearDown(bottom.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('媒体库')),
              body: ValueListenableBuilder<double>(
                valueListenable: bottom,
                builder: (_, reservation, _) => MediaLibraryEmptyState(
                  icon: Icons.folder_open_outlined,
                  message: '此文件夹为空',
                  bottomPadding: reservation,
                  actionLabel: '导入媒体',
                  onAction: () {},
                ),
              ),
            ),
          ),
        );
        for (final reservation in [0.0, 146.0, 180.0, 0.0]) {
          bottom.value = reservation;
          await tester.pumpAndSettle();
          final viewport = tester.getRect(find.byType(MediaLibraryEmptyState));
          final group = tester.getRect(
            find
                .ancestor(
                  of: find.text('此文件夹为空'),
                  matching: find.byType(Column),
                )
                .first,
          );
          final availableHeight = viewport.height - reservation;
          final padding = availableHeight < 280 ? 32 : 64;
          if (group.height + padding <= availableHeight) {
            expect(
              group.center.dy,
              closeTo((viewport.top + viewport.bottom - reservation) / 2, 0.5),
            );
            expect(group.center.dx, closeTo(viewport.center.dx, 0.5));
          } else {
            await tester.ensureVisible(find.text('导入媒体'));
            await tester.pumpAndSettle();
          }
          final button = tester.getRect(find.text('导入媒体'));
          expect(button.top, greaterThanOrEqualTo(viewport.top));
          expect(
            button.bottom,
            lessThanOrEqualTo(viewport.bottom - reservation),
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('short viewport scrolls the action above the player', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 320);
    addTearDown(tester.view.reset);
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(3)),
          child: child!,
        ),
        home: Scaffold(
          body: MediaLibraryEmptyState(
            icon: Icons.folder_open_outlined,
            message: '还没有可以显示的媒体内容',
            bottomPadding: 150,
            actionLabel: '导入媒体',
            onAction: () => tapped = true,
          ),
        ),
      ),
    );
    final action = find.text('导入媒体');
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    final button = find.ancestor(of: action, matching: find.byType(TextButton));
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(170));
    expect(button.hitTestable(), findsOneWidget);
    await tester.tap(button);
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a consumed bottom inset is not reserved again', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.only(bottom: 150),
            child: MediaLibraryEmptyViewport(
              child: SizedBox(
                key: ValueKey('empty-group'),
                width: 100,
                height: 80,
              ),
            ),
          ),
        ),
      ),
    );
    final viewport = tester.getRect(find.byType(MediaLibraryEmptyViewport));
    final group = tester.getRect(find.byKey(const ValueKey('empty-group')));
    expect(group.center, viewport.center);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty viewport supports a remaining-space sliver', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: 100)),
              SliverFillRemaining(
                hasScrollBody: false,
                child: MediaLibraryEmptyViewport(child: Text('没有符合条件的节目')),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('没有符合条件的节目').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
