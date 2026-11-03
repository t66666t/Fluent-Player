import 'package:video_player_app/widgets/categorized_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  test('新配置默认集中根目录，已有来源目录名保留', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.importCardPlacementMode, ImportCardPlacement.libraryRoot);
    expect(
      settings.importSourceFolderName(ImportCardFeature.bilibiliOnline),
      '哔哩哔哩',
    );
    expect(settings.importSourceFolderName(ImportCardFeature.ytDlp), 'yt-dlp');

    await settings.updateSetting('importCardPlacement', 'sourceFolder');
    await settings.updateSetting(
      ImportSourceFolders.namesKey,
      '{"ytDlp":"  油管下载/ ","missing":"忽略"}',
    );

    settings.resetForTest();
    await settings.init();
    expect(settings.importCardPlacementMode, ImportCardPlacement.sourceFolder);
    expect(settings.importSourceFolderName(ImportCardFeature.ytDlp), '油管下载');
    expect(
      settings.importSourceFolderName(ImportCardFeature.bilibiliDownload),
      '哔哩哔哩',
    );
  });

  testWidgets('媒体库设置进入二级页，保存后应用位置方案', (tester) async {
    final settings = SettingsService();
    await settings.init();

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    expect(find.byType(CategorizedSettingsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);
    final entry = find.byKey(const ValueKey('import-location-settings'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('importCardPlacement-sourceFolder')),
    );
    await tester.pumpAndSettle();

    expect(settings.importCardPlacementMode, ImportCardPlacement.libraryRoot);
    await tester.tap(find.byKey(const ValueKey('import-location-save')));
    await tester.pumpAndSettle();
    expect(settings.importCardPlacementMode, ImportCardPlacement.sourceFolder);
  });

  test('旧用户明确保存的方案与B站目标迁移保留', () async {
    SharedPreferences.setMockInitialValues({
      'importCardPlacement': 'currentFolder',
      'bilibiliImportTarget': 'folder:existing-folder',
    });
    final settings = SettingsService();
    await settings.init();
    expect(settings.importCardPlacementMode, ImportCardPlacement.currentFolder);
    final rule = settings.importPlacementRules.effectiveRule(
      ImportCardFeature.bilibiliPage,
      settings.importCardPlacementMode,
    );
    expect(rule.placement, ImportCardPlacement.fixedFolder);
    expect(rule.folderId, 'existing-folder');
  });
}
