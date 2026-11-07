import 'package:video_player_app/widgets/media_library_settings_page.dart';
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

  testWidgets(
    'community settings keep local import options without placement rules',
    (tester) async {
      final settings = SettingsService();
      await settings.init();
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      expect(find.byType(MediaLibrarySettingsPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('import-location-settings')),
        findsNothing,
      );
      expect(find.text('导入位置与整理'), findsNothing);
      final copy = find.byKey(
        const ValueKey('copyImportedMediaToPrivateStorage'),
      );
      await tester.ensureVisible(copy);
      expect(copy, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

  test(
    'legacy local rules are retained without counting as download overrides',
    () {
      final rules = ImportPlacementRules(
        overrides: {
          ImportCardGroup.local.ruleKey: const ImportPlacementRule(
            ImportCardPlacement.libraryRoot,
          ),
          ImportCardFeature.fluentPack.storageValue: const ImportPlacementRule(
            ImportCardPlacement.sourceFolder,
          ),
          ImportCardFeature.ytDlp.storageValue: const ImportPlacementRule(
            ImportCardPlacement.currentFolder,
          ),
        },
      );
      expect(rules.configurableOverrideCount, 1);
      expect(
        ImportPlacementRules.decode(rules.encode()).overrides,
        hasLength(3),
      );
    },
  );
}
