import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/home_search_scope_menu.dart';

Future<void> _openMenu(
  WidgetTester tester, {
  Size size = const Size(960, 720),
  double scale = 1,
  double keyboardInset = 0,
  HomeSearchScope selected = HomeSearchScope.library,
  ValueChanged<HomeSearchScope?>? onResult,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showHomeSearchScopeMenu(
              context,
              anchor: const Rect.fromLTWH(26, 60, 48, 50),
              selected: selected,
              signedInProviders: {'baidu', 'quark', 'uc', 'aliyun'},
              keyboardNavigation: true,
            );
            onResult?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1440, 900),
  ]) {
    testWidgets('compatibility menu offers only the library at $size', (
      tester,
    ) async {
      HomeSearchScope? result;
      await _openMenu(
        tester,
        size: size,
        selected: HomeSearchScope.bilibili,
        onResult: (value) => result = value,
      );
      final menu = tester.getRect(
        find.byKey(const ValueKey('home-search-scope-menu')),
      );
      expect(menu.right, lessThanOrEqualTo(size.width - 12));
      expect(menu.bottom, lessThanOrEqualTo(size.height - 12));
      expect(find.text(HomeSearchScope.library.label), findsOneWidget);
      for (final scope in HomeSearchScope.values.skip(1)) {
        expect(find.text(scope.label), findsNothing);
      }
      await tester.tap(find.text(HomeSearchScope.library.label));
      await tester.pumpAndSettle();
      expect(result, HomeSearchScope.library);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'large text, keyboard and a stale scope still expose the local choice',
    (tester) async {
      await _openMenu(
        tester,
        size: const Size(390, 844),
        scale: 2,
        keyboardInset: 320,
        selected: HomeSearchScope.aliyun,
      );
      final menu = tester.getRect(
        find.byKey(const ValueKey('home-search-scope-menu')),
      );
      expect(menu.bottom, lessThanOrEqualTo(844 - 320 - 12));
      final library = find.widgetWithText(
        InkWell,
        HomeSearchScope.library.label,
      );
      expect(tester.widget<InkWell>(library).focusNode!.hasFocus, isTrue);
      expect(menu.contains(tester.getCenter(library)), isTrue);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-search-scope-menu')),
        findsNothing,
      );
    },
  );

  testWidgets('legacy keyboard navigation cannot select retired sources', (
    tester,
  ) async {
    HomeSearchScope? result;
    await _openMenu(
      tester,
      selected: HomeSearchScope.podcastSearch,
      onResult: (value) => result = value,
    );
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.home,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InkWell>(find.widgetWithText(InkWell, '媒体库'))
            .focusNode!
            .hasFocus,
        isTrue,
      );
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, HomeSearchScope.library);
  });
}
