import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/batch_import_screen.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_actions_menu.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

class _Batch extends ChangeNotifier implements BatchImportService {
  final foldersRead = <String?>[];
  @override
  double get fontSize => 14;
  @override
  List<BatchItem> getVideoItems(String? folderId) {
    foldersRead.add(folderId);
    return [];
  }

  @override
  List<BatchItem> getSubtitleItems(String? folderId) => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<_Batch> mount(
    WidgetTester tester,
    Size size,
    Widget home, {
    _Routes? routes,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final batch = _Batch();
    final settings = SettingsService()..resetForTest();
    settings.isActionButtonsCollapsed = false;
    settings.showActionButtonLabels = true;
    addTearDown(batch.dispose);
    addTearDown(settings.resetForTest);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BatchImportService>.value(value: batch),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          navigatorObservers: [?routes],
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return batch;
  }

  for (final size in [const Size(320, 568), const Size(1280, 800)]) {
    for (final entry in ['menu', 'sheet', 'rail', 'horizontal']) {
      testWidgets(
        '$entry opens paired subtitle import with folder context at $size',
        (tester) async {
          const folder = 'chosen-local-folder';
          final batch = await mount(
            tester,
            size,
            Scaffold(
              body: Builder(
                builder: (context) {
                  if (entry == 'menu' || entry == 'sheet') {
                    return TextButton(
                      onPressed: () => entry == 'menu'
                          ? showMediaLibraryActionsMenu(
                              context,
                              collectionId: folder,
                              onTransfer: () {},
                            )
                          : VideoActionButtons.showImportMenu(context, folder),
                      child: const Text('open'),
                    );
                  }
                  return Align(
                    alignment: Alignment.bottomRight,
                    child: VideoActionButtons(
                      collectionId: folder,
                      isHorizontal: entry == 'horizontal',
                    ),
                  );
                },
              ),
            ),
          );
          if (entry == 'menu' || entry == 'sheet') {
            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();
          }
          for (final label in [
            '网站与链接收藏',
            'B站官方播放',
            'YouTube 官方播放',
            '官方网盘与文件页面链接',
            '订阅或导入播客',
            '缓存管理',
          ]) {
            expect(find.text(label), findsNothing);
          }
          final action = entry == 'rail'
              ? find.byKey(const ValueKey('action-button-disc-批量字幕导入'))
              : entry == 'horizontal'
              ? find.widgetWithText(ElevatedButton, '批量字幕导入')
              : find.text('批量字幕导入');
          await tester.ensureVisible(action);
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(find.byType(BatchImportScreen), findsOneWidget);
          expect(find.byType(BatchSubtitleScreen), findsNothing);
          expect(
            tester
                .widget<BatchImportScreen>(find.byType(BatchImportScreen))
                .folderId,
            folder,
          );
          expect(batch.foldersRead, contains(folder));
          expect(find.text('媒体列表'), findsOneWidget);
          expect(find.text('字幕列表'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final entry in <String, void Function(BuildContext)>{
    'Bilibili': (context) => VideoActionButtons.openBilibiliDownloadPage(
      context,
      streamingMode: true,
    ),
    'YouTube': (context) => VideoActionButtons.openYtDlpDownloadPage(context),
    'Website': (context) => VideoActionButtons.openWebMediaPage(context),
    'Douyin': (context) => VideoActionButtons.openDouyinDownloadPage(context),
    'Cloud': (context) =>
        VideoActionButtons.openCloudDrivePage(context, 'folder'),
    'Online cache': (context) =>
        VideoActionButtons.openCacheManagementPage(context),
  }.entries) {
    testWidgets(
      '${entry.key} compatibility entry refuses without opening a route',
      (tester) async {
        final routes = _Routes();
        await mount(
          tester,
          const Size(800, 600),
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => entry.value(context),
                child: const Text('legacy action'),
              ),
            ),
          ),
          routes: routes,
        );
        final before = routes.pushes;
        await tester.tap(find.text('legacy action'));
        await tester.pumpAndSettle();
        expect(routes.pushes, before);
        expect(find.text('社区版仅支持本地媒体，请导入本地文件。'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
