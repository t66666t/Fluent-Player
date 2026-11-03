import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/home_search_preferences.dart';
import 'package:video_player_app/widgets/home_search_scope_menu.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

const _menu = ValueKey('home-search-scope-menu');

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

HomeSearchScope _focused(WidgetTester tester) =>
    HomeSearchScope.values.firstWhere((scope) {
      final tiles = find.widgetWithText(InkWell, scope.label);
      return tiles.evaluate().isNotEmpty &&
          tester.widget<InkWell>(tiles).focusNode!.hasFocus;
    });

Future<void> _openMenu(
  WidgetTester tester, {
  Size size = const Size(960, 720),
  HomeSearchScope selected = HomeSearchScope.library,
  Set<String> providers = const {'baidu', 'quark', 'uc', 'aliyun'},
  ValueChanged<HomeSearchScope?>? onResult,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showHomeSearchScopeMenu(
              context,
              anchor: const Rect.fromLTWH(26, 60, 48, 50),
              selected: selected,
              signedInProviders: providers,
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

Future<void> _openPrompt(WidgetTester tester) async {
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
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Down opens from input; Up folds from first row and preserves the draft',
    (tester) async {
      await _openPrompt(tester);
      await tester.enterText(find.byType(TextField), 'saved draft');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(find.byKey(_menu), findsOneWidget);
      expect(_focused(tester), HomeSearchScope.library);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(find.byKey(_menu), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'saved draft');
      expect(field.focusNode!.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(find.byTooltip('选择搜索范围：播客页'), findsOneWidget);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        HomeSearchPreferences(await SharedPreferences.getInstance()).scope,
        HomeSearchScope.podcasts,
      );
    },
  );

  testWidgets(
    'arrows follow both columns and cross groups without committing until Enter',
    (tester) async {
      HomeSearchScope? result;
      await _openMenu(
        tester,
        providers: {'uc', 'aliyun'},
        onResult: (value) => result = value,
      );
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(tester), HomeSearchScope.podcasts);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester), HomeSearchScope.bilibili);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester), HomeSearchScope.aliyun);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(tester), HomeSearchScope.uc);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester), HomeSearchScope.podcastSearch);
      expect(result, isNull);
      expect(find.text('百度网盘'), findsNothing);
      expect(find.text('夸克网盘'), findsNothing);
      await _key(tester, LogicalKeyboardKey.numpadEnter);
      expect(result, HomeSearchScope.podcastSearch);
      expect(find.byKey(_menu), findsNothing);
    },
  );

  testWidgets('single-column movement scrolls the focused choice into view', (
    tester,
  ) async {
    HomeSearchScope? result;
    await _openMenu(
      tester,
      size: const Size(320, 568),
      onResult: (value) => result = value,
    );
    await _key(tester, LogicalKeyboardKey.end);
    expect(_focused(tester), HomeSearchScope.aliyun);
    final panel = tester.getRect(find.byKey(_menu));
    expect(panel.contains(tester.getCenter(find.text('阿里云盘'))), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(tester), HomeSearchScope.uc);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester), HomeSearchScope.aliyun);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester), HomeSearchScope.aliyun);
    await _key(tester, LogicalKeyboardKey.home);
    expect(_focused(tester), HomeSearchScope.library);
    expect(panel.contains(tester.getCenter(find.text('媒体库'))), isTrue);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester), HomeSearchScope.podcasts);
    await _key(tester, LogicalKeyboardKey.enter);
    expect(result, HomeSearchScope.podcasts);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved choice receives initial focus and is revealed on a short menu',
    (tester) async {
      await _openMenu(
        tester,
        size: const Size(320, 568),
        selected: HomeSearchScope.aliyun,
      );
      expect(_focused(tester), HomeSearchScope.aliyun);
      expect(
        tester
            .getRect(find.byKey(_menu))
            .contains(tester.getCenter(find.text('阿里云盘'))),
        isTrue,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(find.byKey(_menu), findsNothing);
    },
  );

  testWidgets(
    'odd cloud rows use visible neighbors and Tab still supports selection',
    (tester) async {
      HomeSearchScope? result;
      await _openMenu(
        tester,
        providers: {'quark'},
        selected: HomeSearchScope.bilibili,
        onResult: (value) => result = value,
      );
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(tester), HomeSearchScope.quark);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(tester), HomeSearchScope.podcastSearch);
      await _key(tester, LogicalKeyboardKey.tab);
      expect(_focused(tester), HomeSearchScope.bilibili);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result, HomeSearchScope.bilibili);
    },
  );

  testWidgets('IME composition and modified arrows retain text editing', (
    tester,
  ) async {
    await _openPrompt(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.byKey(_menu), findsNothing);
    expect(field.controller!.text, 'zhong');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(find.byKey(_menu), findsNothing);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(find.byKey(_menu), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TextField), findsOneWidget);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.text, 'zhong');
  });

  testWidgets(
    'type icon remains centered and chevron sits on its right centerline',
    (tester) async {
      await _openPrompt(tester);
      final button = tester.getRect(find.byTooltip('选择搜索范围：媒体库'));
      final typeIcon = tester.getRect(
        find.byKey(const ValueKey(HomeSearchScope.library)),
      );
      final chevron = tester.getRect(
        find.byKey(const ValueKey('home-search-scope-chevron')),
      );
      expect(typeIcon.center.dx, closeTo(button.center.dx, .01));
      expect(typeIcon.center.dy, closeTo(button.center.dy, .01));
      expect(chevron.center.dy, closeTo(typeIcon.center.dy, .01));
      expect(chevron.left, greaterThanOrEqualTo(typeIcon.right));
      expect(button.contains(chevron.center), isTrue);
    },
  );
}
