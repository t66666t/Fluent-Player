import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
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
      'only local startup choices remain and a retired choice falls back at $size',
      (tester) async {
        await open(tester, size);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(ChoiceChip), findsNWidgets(3));
        for (final entry in ['folders', 'continueLearning', 'recent']) {
          expect(
            find.byKey(ValueKey('mediaLibraryStartupEntry-$entry')),
            findsOneWidget,
          );
        }
        final folder = find.byKey(
          const ValueKey('mediaLibraryStartupEntry-folders'),
        );
        expect(tester.widget<ChoiceChip>(folder).selected, isTrue);
        final recent = find.byKey(
          const ValueKey('mediaLibraryStartupEntry-recent'),
        );
        await tester.ensureVisible(recent);
        await tester.tap(recent);
        await tester.pumpAndSettle();
        expect(settings.mediaLibraryStartupEntry, 'recent');
        expect(
          (await SharedPreferences.getInstance()).getString(
            'mediaLibraryStartupEntry',
          ),
          'recent',
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
