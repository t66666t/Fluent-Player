import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/library_rename_dialog.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  const nameKey = ValueKey('library-rename-name-field');
  const coverKey = ValueKey('library-rename-cover-field');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    library.seedVideoForTesting(
      VideoItem(
        id: 'media',
        path: '/media.mp4',
        title: '原始媒体标题',
        durationMs: 1000,
        lastUpdated: 1,
      ),
    );
    library.seedCollectionForTesting(
      VideoCollection(id: 'folder', name: '原始文件夹', createTime: 1),
    );
  });

  tearDown(() {
    library.resetLibraryForTesting();
    settings.resetForTest();
  });

  Future<void> confirm(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    // Keep the singleton's serialized save chain in the real async zone across
    // widget tests, and wait for the queued rename before checking dismissal.
    await tester.runAsync(() async {
      await action();
      await library.saveLibraryForTesting();
    });
    await tester.pumpAndSettle();
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    String id = 'media',
    bool menu = false,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          builder: (context, child) => AppTextInputFocus(child: child!),
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => menu
                    ? MediaLibraryActivityMenuButton(
                        targetId: id,
                        isCollection: id == 'folder',
                      )
                    : TextButton(
                        onPressed: () => showLibraryRenameDialog(
                          context: context,
                          itemId: id,
                          currentName:
                              library.getCollection(id)?.name ??
                              library.getVideo(id)!.title,
                        ),
                        child: const Text('旧入口'),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      menu
          ? find.byKey(const ValueKey('media-library-activity-menu'))
          : find.text('旧入口'),
    );
    await tester.pumpAndSettle();
    if (menu) {
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'old rename entry selects the whole name on desktop and touch devices',
    (tester) async {
      await pumpHost(tester);
      final field = tester.widget<TextField>(find.byKey(nameKey));
      final selection = field.controller!.selection;
      expect(field.focusNode!.hasFocus, isTrue);
      expect(selection.start, 0);
      expect(selection.end, field.controller!.text.length);
      expect(selection.extentOffset, 0);
      expect(field.style!.fontWeight, FontWeight.w500);

      tester.testTextInput.updateEditingValue(
        field.controller!.value.replaced(selection, '新名称'),
      );
      await tester.pump();
      await confirm(
        tester,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      expect(library.getVideo('media')!.title, '新名称');
      expect(find.byKey(nameKey), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final id in ['media', 'folder']) {
    testWidgets('card overflow renames $id through the shared dialog', (
      tester,
    ) async {
      await pumpHost(tester, id: id, menu: true);
      final field = tester.widget<TextField>(find.byKey(nameKey));
      expect(field.controller!.selection.start, 0);
      expect(field.controller!.selection.end, field.controller!.text.length);
      expect(
        field.style!.fontWeight,
        id == 'folder' ? FontWeight.w600 : FontWeight.w500,
      );
      await tester.enterText(find.byKey(nameKey), '重命名后的卡片');
      await confirm(tester, () => tester.tap(find.text('确定')));
      expect(
        library.getCollection(id)?.name ?? library.getVideo(id)?.title,
        '重命名后的卡片',
      );
      expect(find.byKey(nameKey), findsNothing);
    });
  }

  testWidgets('long titles wrap and remain usable above a phone keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    library.getVideo('media')!.title = List.filled(
      12,
      '这是一个需要完整展示以便编辑的很长的媒体标题',
    ).join(' · ');
    await pumpHost(tester);
    final field = tester.widget<TextField>(find.byKey(nameKey));
    final editable = find.descendant(
      of: find.byKey(nameKey),
      matching: find.byType(EditableText),
    );
    final longHeight = tester.getSize(editable).height;
    expect(field.maxLines, 8);
    expect(longHeight, greaterThan(80));
    expect(field.controller!.selection.start, 0);
    expect(field.controller!.selection.end, field.controller!.text.length);
    expect(tester.getRect(find.text('确定')).bottom, lessThan(544));
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(nameKey), '短标题');
    await tester.pumpAndSettle();
    expect(tester.getSize(editable).height, lessThan(longHeight));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(library.getVideo('media')!.title, contains('很长的媒体标题'));
  });

  testWidgets('folder cover letters still follow the edited name', (
    tester,
  ) async {
    settings.folderPlaceholderSettings = settings.folderPlaceholderSettings
        .copyWith(showCoverText: true, maxCoverTextLength: 4);
    await pumpHost(tester, id: 'folder');
    await tester.enterText(find.byKey(nameKey), '英语学习');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(coverKey)).controller!.text,
      '英语学习',
    );
    await confirm(tester, () => tester.tap(find.text('确定')));
    expect(library.getCollection('folder')!.name, '英语学习');
    expect(library.getCollection('folder')!.coverLabel, isNull);
  });
}
