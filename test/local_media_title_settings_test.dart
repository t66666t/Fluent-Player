import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/batch_import_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'package:video_player_app/widgets/media_library_style_sheet.dart';

class _TitleBatch extends ChangeNotifier implements BatchImportService {
  final media = BatchItem(id: 'media', path: '/local/Lesson.m4a');
  final subtitle = BatchItem(id: 'subtitle', path: '/local/Lesson.srt');

  @override
  double get fontSize => 14;
  @override
  List<BatchItem> getVideoItems(String? folderId) => [media];
  @override
  List<BatchItem> getSubtitleItems(String? folderId) => [subtitle];
  @override
  bool isImported(String? folderId, String path) => false;
  @override
  String? getDuration(String? folderId, String path) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
  });

  test(
    'display defaults off, persists and exports independently of filtering',
    () async {
      final settings = SettingsService();
      expect(settings.showLocalMediaExtensions, isFalse);
      expect(settings.localImportFilterMediaExtensions, isTrue);
      await settings.updateSetting('showLocalMediaExtensions', true);
      settings.resetForTest();
      await settings.init();
      expect(settings.showLocalMediaExtensions, isTrue);
      expect(settings.localImportFilterMediaExtensions, isTrue);
      expect(
        settings.exportSettingsSnapshot()['layout'],
        containsPair('showLocalMediaExtensions', true),
      );
      await settings.updateSetting('localImportFilterMediaExtensions', false);
      expect(settings.showLocalMediaExtensions, isTrue);
    },
  );

  testWidgets(
    'batch import titles update while subtitle filenames remain intact',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SettingsService();
      final batch = _TitleBatch();
      addTearDown(batch.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<BatchImportService>.value(value: batch),
          ],
          child: const MaterialApp(home: BatchImportScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lesson'), findsOneWidget);
      expect(find.text('Lesson.srt'), findsOneWidget);
      await settings.updateSetting('showLocalMediaExtensions', true);
      await tester.pumpAndSettle();
      expect(find.text('Lesson.m4a'), findsOneWidget);
      expect(find.text('Lesson.srt'), findsOneWidget);
      expect(batch.media.path, '/local/Lesson.m4a');
      expect(batch.media.title, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final scope in MediaLibraryCardStyleScope.values) {
    testWidgets(
      'style toggle updates existing grid and list titles for $scope',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final settings = SettingsService();
        final item = VideoItem(
          id: 'already-imported',
          path: '/local/lesson.m4a',
          title: '第1.2课.m4a',
          durationMs: 1000,
          lastUpdated: 0,
        );
        final saved = item.toJson();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: MediaPlaybackService(),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      TextButton(
                        onPressed: () => MediaLibraryStyleSheet.show(
                          context: context,
                          scope: scope,
                        ),
                        child: const Text('style'),
                      ),
                      SizedBox(
                        width: 200,
                        height: 200,
                        child: MediaLibraryMediaGridCard(
                          item: item,
                          titleScale: 0.065,
                          onTap: () {},
                          onLocate: () {},
                          showLocate: false,
                          showActivityMenu: false,
                          coverOverride: const ColoredBox(color: Colors.black),
                        ),
                      ),
                      SizedBox(
                        width: 400,
                        height: 80,
                        child: MediaLibraryListTile.video(
                          item: item,
                          index: 0,
                          showIndex: false,
                          showThumbnail: false,
                          isSelected: false,
                          isSelectionMode: false,
                          titleScale: 0.042,
                          showActivityMenu: false,
                          onTap: () {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('第1.2课'), findsNWidgets(2));
        expect(find.text('第1.2课.m4a'), findsNothing);
        await tester.tap(find.text('style'));
        await tester.pumpAndSettle();
        final toggle = find.byKey(
          const ValueKey('show-local-media-extensions'),
        );
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(settings.showLocalMediaExtensions, isTrue);
        expect(find.text('第1.2课.m4a'), findsNWidgets(2));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('第1.2课'), findsNWidgets(2));
        expect(settings.localImportFilterMediaExtensions, isTrue);
        expect(item.toJson(), saved);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
