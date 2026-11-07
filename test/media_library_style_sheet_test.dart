import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_view_mode.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_style_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => mediaLibraryAlternateViewsEnabled = true);
  tearDown(() => mediaLibraryAlternateViewsEnabled = false);

  Future<SettingsService> readySettings() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    return settings;
  }

  Future<void> pumpSheet(WidgetTester tester, SettingsService settings) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => MediaLibraryStyleSheet.show(
                  context: context,
                  scope: MediaLibraryCardStyleScope.home,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final size in [
    (name: 'phone', width: 390.0, height: 844.0),
    (name: 'desktop', width: 1440.0, height: 900.0),
  ]) {
    testWidgets('${size.name} 四种风格面板不溢出', (tester) async {
      tester.view.physicalSize = Size(size.width, size.height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final settings = await readySettings();
      await pumpSheet(tester, settings);

      expect(find.byKey(MediaLibraryStyleSheet.bodyKey), findsOneWidget);

      for (final mode in MediaLibraryViewMode.values) {
        await tester.tap(find.text(mode.label).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('调整媒体行栏数与表格列写入设置', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    await pumpSheet(tester, settings);

    await tester.tap(find.text(MediaLibraryViewMode.rows.label).first);
    await tester.pumpAndSettle();

    final rowsSlider = find.byKey(
      const ValueKey('media-library-style-rows-columns'),
    );
    await tester.drag(rowsSlider, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(settings.rowsStyleFor(const Size(800, 1200)).crossAxisCount, isNot(1));

    await tester.tap(find.text(MediaLibraryViewMode.table.label).first);
    await tester.pumpAndSettle();

    final typeColumn = find.byKey(
      const ValueKey('media-library-style-table-column-type'),
    );
    await tester.scrollUntilVisible(
      typeColumn,
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(typeColumn);
    await tester.pumpAndSettle();
    expect(
      settings.tableStyleFor(const Size(800, 1200)).tableColumns,
      contains(MediaTableColumn.type),
    );
    expect(tester.takeException(), isNull);
  });
}
