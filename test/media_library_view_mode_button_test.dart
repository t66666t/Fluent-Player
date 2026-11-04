import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_view_mode.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_view_mode_button.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsService> readySettings() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    return settings;
  }

  testWidgets('点击按钮列出四种视图并写入设置', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();
    expect(settings.mediaLibraryViewStyle, MediaLibraryViewMode.grid);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: MediaLibraryViewModeButton(
                key: const ValueKey('host'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaLibraryViewModeButton.buttonKey));
    await tester.pumpAndSettle();

    for (final mode in MediaLibraryViewMode.values) {
      expect(
        find.byKey(MediaLibraryViewModeButton.optionKey(mode)),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(MediaLibraryViewModeButton.optionKey(MediaLibraryViewMode.table)),
    );
    await tester.pumpAndSettle();

    expect(settings.mediaLibraryViewStyle, MediaLibraryViewMode.table);
    expect(find.byKey(MediaLibraryViewModeButton.optionKey(MediaLibraryViewMode.grid)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏以底部面板展示视图菜单', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = await readySettings();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: MediaLibraryViewModeButton(compact: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaLibraryViewModeButton.buttonKey));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('media-library-view-mode-sheet')),
      findsOneWidget,
    );
    expect(find.text('视图风格'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
