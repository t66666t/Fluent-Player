import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/widgets/home_search_scope_menu.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('large text and keyboard keep the last option reachable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHomeSearchScopeMenu(
              context,
              anchor: const Rect.fromLTWH(26, 60, 60, 50),
              selected: HomeSearchScope.library,
              signedInProviders: {'baidu', 'quark', 'uc', 'aliyun'},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final panel = tester.getRect(
      find.byKey(const ValueKey('home-search-scope-menu')),
    );
    expect(panel.bottom, lessThanOrEqualTo(844 - 320 - 12));
    await tester.ensureVisible(find.text('阿里云盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阿里云盘'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-search-scope-menu')), findsNothing);
  });

  testWidgets('scope selection preserves input and never submits to library', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHomeSearchPrompt(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'saved query');
    await tester.tap(find.byTooltip('选择搜索范围：媒体库'));
    await tester.pumpAndSettle();
    expect(find.text('登录网盘后将在这里显示'), findsOneWidget);
    await tester.tap(find.text('播客搜索页'));
    await tester.pumpAndSettle();
    expect(find.text('saved query'), findsOneWidget);
    expect(find.text('播客搜索页 · 搜索'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_forward_rounded),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('选择搜索范围：播客搜索页'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-search-scope-menu')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.byTooltip('选择搜索范围：播客搜索页'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('home-search-scope-menu')), findsNothing);
  });

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1440, 900),
  ]) {
    testWidgets('menu fits $size and all cloud choices remain reachable', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      HomeSearchScope? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showHomeSearchScopeMenu(
                  context,
                  anchor: const Rect.fromLTWH(26, 60, 60, 50),
                  selected: HomeSearchScope.library,
                  signedInProviders: {'baidu', 'quark', 'uc', 'aliyun'},
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(
        find.byKey(const ValueKey('home-search-scope-menu')),
      );
      expect(rect.right, lessThanOrEqualTo(size.width - 12));
      expect(rect.bottom, lessThanOrEqualTo(size.height - 12));
      await tester.ensureVisible(find.text('阿里云盘'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阿里云盘'));
      await tester.pumpAndSettle();
      expect(result, HomeSearchScope.aliyun);
    });
  }

  testWidgets('cloud choices are filtered by signed-in provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHomeSearchScopeMenu(
              context,
              anchor: const Rect.fromLTWH(26, 60, 60, 50),
              selected: HomeSearchScope.library,
              signedInProviders: {'quark'},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('夸克网盘'), findsOneWidget);
    expect(find.text('百度网盘'), findsNothing);
    expect(find.text('UC网盘'), findsNothing);
    expect(find.text('阿里云盘'), findsNothing);
    await tester.tapAt(const Offset(750, 550));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-search-scope-menu')), findsNothing);
  });
}
