import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_controls.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    settings.mediaLibraryRestoreLastPage = false;
    settings.mediaLibraryStartupEntry = 'bilibili';
  });
  tearDown(() => settings.resetForTest());

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMediaLibrarySettingsBottomSheet(
                context,
                settings,
                showSystemMediaNotificationSetting: false,
              ),
              child: const Text('settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(320, 568), const Size(1280, 800)]) {
    testWidgets(
      'local and podcast startup choices remain while a retired choice falls back at $size',
      (tester) async {
        await open(tester, size);
        expect(find.byType(TextField), findsNothing);
        final picker = find.byKey(const ValueKey('mediaLibraryStartupEntry'));
        expect(
          tester
              .widget<MediaLibrarySettingsDropdown<MediaLibraryRootEntry>>(
                picker,
              )
              .value,
          MediaLibraryRootEntry.folders,
        );
        final dropdown = tester.widget<DropdownButton<MediaLibraryRootEntry>>(
          find.descendant(
            of: picker,
            matching: find.byType(DropdownButton<MediaLibraryRootEntry>),
          ),
        );
        expect(dropdown.items, hasLength(4));
        await tester.ensureVisible(picker);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        for (final entry in [
          'folders',
          'continueLearning',
          'recent',
          'podcasts',
        ]) {
          expect(
            find.byKey(ValueKey('mediaLibraryStartupEntry-$entry')).last,
            findsOneWidget,
          );
        }
        for (final retired in ['bilibili', 'cloudDrive']) {
          expect(
            find.byKey(ValueKey('mediaLibraryStartupEntry-$retired')),
            findsNothing,
          );
        }
        final recent = find.byKey(
          const ValueKey('mediaLibraryStartupEntry-recent'),
        );
        await tester.tap(
          find.ancestor(of: recent.last, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        expect(settings.mediaLibraryStartupEntry, 'recent');
        expect(
          (await SharedPreferences.getInstance()).getString(
            'mediaLibraryStartupEntry',
          ),
          'recent',
        );
        final podcasts = find.byKey(
          const ValueKey('mediaLibraryStartupEntry-podcasts'),
        );
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .ancestor(of: podcasts.last, matching: find.byType(InkWell))
              .first,
        );
        await tester.pumpAndSettle();
        expect(settings.mediaLibraryStartupEntry, 'podcasts');
        expect(
          (await SharedPreferences.getInstance()).getString(
            'mediaLibraryStartupEntry',
          ),
          'podcasts',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'remote settings are removed while local storage and model networking remain',
    (tester) async {
      await open(tester, const Size(390, 844));
      for (final key in [
        'clipboardLinkDetectionEnabled',
        'skipRepeatedClipboardText',
        'bilibiliBackgroundAudioOnly',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      expect(find.text('在线视频缓存'), findsNothing);
      for (final key in [
        'modelCenterSettings',
        'globalNetworkSettings',
        'storageManagement',
        'copyImportedMediaToPrivateStorage',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      final copy = find.byKey(
        const ValueKey('copyImportedMediaToPrivateStorage'),
      );
      await tester.ensureVisible(copy);
      final previous = settings.copyImportedMediaToPrivateStorage;
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(settings.copyImportedMediaToPrivateStorage, !previous);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
