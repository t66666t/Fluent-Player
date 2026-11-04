import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_format_page.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_settings_memory.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_settings_page.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('Bilibili cache export defaults on and preserves explicit opt-out', () {
    expect(
      const PortableExportOptions(packageName: 'backup').includeBilibiliCache,
      isTrue,
    );
    expect(
      PortableExportOptions.fromJson(const {}).includeBilibiliCache,
      isTrue,
    );
    final options = PortableExportOptions.fromJson(
      const PortableExportOptions(
        packageName: 'links',
        includeBilibiliCache: false,
      ).toJson(),
    );
    expect(options.includeBilibiliCache, isFalse);
    expect(
      PortableExportRememberedSettings.fromJson(const {}).includeBilibiliCache,
      isTrue,
    );
    expect(
      PortableExportRememberedSettings.fromJson(
        const PortableExportRememberedSettings(
          includeBilibiliCache: false,
        ).toJson(),
      ).includeBilibiliCache,
      isFalse,
    );
  });

  test(
    'broken remembered settings fall back without touching the other format',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PortableExportSettingsMemory.zipKey: '{',
        PortableExportSettingsMemory.fluentPackKey:
            jsonEncode(<String, dynamic>{
              'compression': 'smallest',
              'wrapInFolder': false,
              'includeSidecars': false,
              'verifyChecksums': true,
            }),
      });

      final zip = await PortableExportSettingsMemory.load(
        PortableExportFormat.zip,
      );
      expect(zip.compression, PortableCompression.fast);
      expect(zip.zipEmbedSubtitles, isTrue);
      expect(zip.zipExternalSubtitles, isFalse);
      expect(zip.includeDanmaku, isTrue);

      final pack = await PortableExportSettingsMemory.load(
        PortableExportFormat.fluentPack,
      );
      expect(pack.compression, PortableCompression.smallest);
      expect(pack.wrapInFolder, isFalse);
      expect(pack.includeSidecars, isFalse);
      expect(pack.verifyChecksums, isTrue);
    },
  );

  testWidgets('export settings can return to the format choice', (
    tester,
  ) async {
    final library = LibraryService();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    addTearDown(library.resetLibraryForTesting);
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: 'C:/unused/clip.mp4',
        title: 'clip',
        durationMs: 1000,
        lastUpdated: 1,
        parentId: 'pending',
        hasProbedChapters: true,
      ),
    );
    await library.moveItemToCollection('clip', null);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PortableExportFormatPage(
          library: library,
          rootIds: const <String>['clip'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('export-format-zip')));
    await tester.pumpAndSettle();
    expect(find.text('Zip 导出设置'), findsOneWidget);
    expect(find.text('软字幕内嵌'), findsOneWidget);
    expect(find.text('最外层包一层文件夹'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('选择导出格式'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('export-format-fluentpack')));
    await tester.pumpAndSettle();
    expect(find.text('最外层包一层文件夹'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('选择导出格式'), findsOneWidget);
    expect(find.text('Fluent Pack'), findsOneWidget);
    expect(find.text('Zip'), findsOneWidget);
  });

  testWidgets('export name selects on entry and later clicks place the caret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<void> expectNameSelectedOnClick(
      String formatKey,
      PointerDeviceKind kind,
    ) async {
      debugDefaultTargetPlatformOverride = kind == PointerDeviceKind.mouse
          ? TargetPlatform.windows
          : TargetPlatform.android;
      final library = _exportLibrary();
      addTearDown(library.resetLibraryForTesting);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PortableExportSettingsPage(
            key: ValueKey<String>(formatKey),
            library: library,
            rootIds: const <String>['clip'],
            format: formatKey == 'export-format-zip'
                ? PortableExportFormatChoice.zip
                : PortableExportFormatChoice.fluentPack,
            mediaCount: 1,
            folderCount: 0,
          ),
        ),
      );
      // The form appears after the remembered settings load.
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await tester.ensureVisible(field);
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, isNotEmpty);
      expect(controller.selection.isCollapsed, isTrue);

      Future<void> click() async {
        final gesture = await tester.startGesture(
          tester.getCenter(field),
          kind: kind,
        );
        await tester.pump();
        await gesture.up();
        // One more frame so a focus callback cannot put the caret back.
        await tester.pump();
        await tester.pump();
      }

      await click();
      expect(controller.selection.start, 0);
      expect(controller.selection.end, controller.text.length);

      await tester.pump(const Duration(milliseconds: 400));
      await click();
      expect(controller.selection.isCollapsed, isTrue);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 400));
      await click();
      expect(controller.selection.start, 0);
      expect(controller.selection.end, controller.text.length);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    }

    await expectNameSelectedOnClick(
      'export-format-zip',
      PointerDeviceKind.mouse,
    );
    await expectNameSelectedOnClick(
      'export-format-fluentpack',
      PointerDeviceKind.touch,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('fluent pack and zip remember their own last settings', (
    tester,
  ) async {
    final library = LibraryService();

    await _showExportSettings(tester, library, PortableExportFormatChoice.zip);
    expect(find.text('携带哔哩哔哩在线缓存'), findsNothing);
    expect(_switchValue(tester, '软字幕内嵌'), isTrue);
    expect(_switchValue(tester, '外挂字幕'), isFalse);
    expect(_switchValue(tester, '包含弹幕'), isTrue);
    expect(find.text('极速 · 推荐给视频'), findsOneWidget);

    await _toggle(tester, '软字幕内嵌');
    await _toggle(tester, '外挂字幕');
    await _toggle(tester, '包含弹幕');
    await _chooseCompression(tester, '均衡 · 稍省空间');
    await _leaveSettings(tester);

    await _showExportSettings(tester, library, PortableExportFormatChoice.zip);
    expect(_switchValue(tester, '软字幕内嵌'), isFalse);
    expect(_switchValue(tester, '外挂字幕'), isTrue);
    expect(_switchValue(tester, '包含弹幕'), isFalse);
    expect(find.text('均衡 · 稍省空间'), findsOneWidget);
    await _leaveSettings(tester);

    await _showExportSettings(
      tester,
      library,
      PortableExportFormatChoice.fluentPack,
    );
    expect(_switchValue(tester, '最外层包一层文件夹'), isTrue);
    expect(_switchValue(tester, '包含字幕与附属文件'), isTrue);
    expect(_switchValue(tester, '生成完整性校验'), isTrue);
    expect(find.text('携带哔哩哔哩在线缓存'), findsNothing);
    expect(find.text('极速 · 推荐给视频'), findsOneWidget);
    expect(find.text('软字幕内嵌'), findsNothing);

    await _toggle(tester, '最外层包一层文件夹');
    await _toggle(tester, '生成完整性校验');
    await _chooseCompression(tester, '最小体积 · 耐心模式');
    await _leaveSettings(tester);

    await _showExportSettings(tester, library, PortableExportFormatChoice.zip);
    expect(_switchValue(tester, '软字幕内嵌'), isFalse);
    expect(_switchValue(tester, '外挂字幕'), isTrue);
    expect(find.text('均衡 · 稍省空间'), findsOneWidget);
    await _leaveSettings(tester);

    await _showExportSettings(
      tester,
      library,
      PortableExportFormatChoice.fluentPack,
    );
    expect(_switchValue(tester, '最外层包一层文件夹'), isFalse);
    expect(_switchValue(tester, '包含字幕与附属文件'), isTrue);
    expect(_switchValue(tester, '生成完整性校验'), isFalse);
    expect(find.text('携带哔哩哔哩在线缓存'), findsNothing);
    expect(find.text('最小体积 · 耐心模式'), findsOneWidget);
  });
}

LibraryService _exportLibrary() {
  final library = LibraryService();
  library.writeLibrarySnapshotOverrideForTesting = () async {};
  library.seedVideoForTesting(
    VideoItem(
      id: 'clip',
      path: 'C:/unused/clip.mp4',
      title: 'clip',
      durationMs: 1000,
      lastUpdated: 1,
      parentId: 'pending',
      hasProbedChapters: true,
    ),
  );
  return library;
}

Future<void> _showExportSettings(
  WidgetTester tester,
  LibraryService library,
  PortableExportFormatChoice format,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: PortableExportSettingsPage(
        library: library,
        rootIds: const <String>['clip'],
        format: format,
        mediaCount: 1,
        folderCount: 0,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _leaveSettings(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

bool _switchValue(WidgetTester tester, String title) {
  return tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
      .value;
}

Future<void> _toggle(WidgetTester tester, String title) async {
  final finder = find.widgetWithText(SwitchListTile, title);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chooseCompression(WidgetTester tester, String label) async {
  final dropdown = find.byType(
    CapsuleDropdownButtonFormField<PortableCompression>,
  );
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
