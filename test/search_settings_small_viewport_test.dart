import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/home_search_preferences.dart';
import 'package:video_player_app/widgets/categorized_settings_page.dart';
import 'package:video_player_app/widgets/experimental_layout_widgets.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('search can submit with 200% text and only 60px above the IME', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 220);
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    addTearDown(tester.view.reset);
    Future<String?>? result;
    await tester.pumpWidget(
      _host((context) => result = showMediaLibrarySearchPrompt(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final panel = tester.getRect(
      find.byKey(const ValueKey('media-search-panel')),
    );
    expect(panel.top, greaterThanOrEqualTo(0));
    expect(panel.bottom, lessThanOrEqualTo(60));
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(await result, 'draft');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a signed-out scope keeps its draft in a short scrollable prompt',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        HomeSearchPreferences.scopeKey: 'baidu',
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 220);
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host((context) => showHomeSearchPrompt(context)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'cloud draft');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('百度网盘 · 搜索'), findsOneWidget);
      expect(find.text('百度网盘尚未登录'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'cloud draft',
      );
      final submit = find.descendant(
        of: find.byKey(const ValueKey('media-search-submit')),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(submit).onPressed, isNull);
      expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('media-search-panel')))
            .dy,
        lessThanOrEqualTo(60),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow settings reserve the scaled search field height', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const CategorizedSettingsPage(
          items: [
            SettingsCategoryBoundary(
              ExperimentalSettingsCategory.playback,
              label: '媒体通知',
              keywords: '通知 权限',
            ),
            ListTile(title: Text('显示媒体通知')),
          ],
        ),
      ),
    );
    final field = find.byKey(const ValueKey('settings-search'));
    expect(
      tester.getBottomRight(field).dy,
      lessThanOrEqualTo(tester.getBottomRight(find.byType(AppBar)).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(field, '通知');
    await tester.pumpAndSettle();
    expect(find.text('显示媒体通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(void Function(BuildContext) open) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: Builder(
    builder: (context) =>
        TextButton(onPressed: () => open(context), child: const Text('open')),
  ),
);
