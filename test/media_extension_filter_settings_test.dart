import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_style_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
  });

  test(
    'extension filter defaults are independent and survive reload',
    () async {
      final settings = SettingsService();
      expect(settings.localImportFilterMediaExtensions, isTrue);
      await settings.updateSetting('localImportFilterMediaExtensions', false);
      settings.resetForTest();
      await settings.init();
      expect(settings.localImportFilterMediaExtensions, isFalse);
      final snapshot = settings.exportSettingsSnapshot().toString();
      expect(snapshot, contains('localImportFilterMediaExtensions: false'));
    },
  );

  for (final cloudDrive in [false]) {
    testWidgets(
      'style sheet saves the ${cloudDrive ? "cloud" : "local"} filter only',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final settings = SettingsService();
        await tester.pumpWidget(
          ChangeNotifierProvider<SettingsService>.value(
            value: settings,
            child: MaterialApp(
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
        final toggle = find.byKey(
          ValueKey(
            cloudDrive
                ? 'cloud-media-extension-filter'
                : 'local-media-extension-filter',
          ),
        );
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(settings.localImportFilterMediaExtensions, cloudDrive);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
