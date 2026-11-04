import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/sync_folder_picker.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  String? result;
  late bool closed;

  setUp(() async {
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await library.createCollection('课程', null, id: 'courses');
    await library.createCollection('数学', 'courses', id: 'math');
    await library.createCollection('第一章', 'math', id: 'chapter');
    await library.createCollection('旅行', null, id: 'trips');
    await library.createCollection('第一章', 'trips', id: 'trip-chapter');
    result = null;
    closed = false;
  });

  tearDown(() {
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = null;
  });

  Finder row(String id) => find.byKey(ValueKey('folder-picker-folder-$id'));
  Finder radio(String id) => find.byKey(ValueKey('folder-picker-select-$id'));
  Finder getSelection() =>
      find.byKey(const ValueKey('folder-picker-selection'));
  Finder confirm() => find.byKey(const ValueKey('folder-picker-confirm'));

  String? selected(WidgetTester tester) => tester
      .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
      .groupValue;

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double scale = 1,
    GlobalKey? capture,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: size, textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showSyncFolderPicker(
                      context,
                      library: library,
                      title: '选择要发送的文件夹',
                    );
                    closed = true;
                  },
                  child: const Text('选择文件夹'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();
  }

  testWidgets('browsing follows the hierarchy without choosing a folder', (
    tester,
  ) async {
    await open(tester);
    expect(row('courses'), findsOneWidget);
    expect(row('trips'), findsOneWidget);
    expect(row('math'), findsNothing);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(find.byKey(const ValueKey('folder-picker-new')), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    expect(row('math'), findsOneWidget);
    expect(row('trips'), findsNothing);
    expect(row('chapter'), findsNothing);
    expect(selected(tester), isNull);
    expect(closed, isFalse);
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();
    expect(row('chapter'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folder-picker-crumb-courses')));
    await tester.pumpAndSettle();
    expect(row('math'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(row('trips'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection survives browsing and is replaced by one child folder', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(radio('courses'));
    await tester.pumpAndSettle();
    expect(selected(tester), 'courses');
    expect(row('trips'), findsOneWidget);
    expect(tester.widget<Text>(getSelection()).data, '已选：媒体库 / 课程');
    expect(closed, isFalse);

    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    await tester.tap(radio('math'));
    await tester.pumpAndSettle();
    expect(selected(tester), 'math');
    expect(tester.widget<Text>(getSelection()).data, '已选：媒体库 / 课程 / 数学');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(selected(tester), 'math');
    // Confirming at the root must return the chosen child, not the viewed level.
    await tester.tap(confirm());
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, 'math');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty folder can be selected from inside and cancelled', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一章'));
    await tester.pumpAndSettle();
    expect(find.text('这里没有子文件夹'), findsOneWidget);
    expect(selected(tester), isNull);
    await tester.tap(
      find.byKey(const ValueKey('folder-picker-select-current')),
    );
    await tester.pumpAndSettle();
    expect(selected(tester), 'chapter');
    expect(tester.widget<Text>(getSelection()).data, '已选：媒体库 / 课程 / 数学 / 第一章');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search shows parent paths and can choose one matching folder', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('folder-picker-search')),
      '第一章',
    );
    await tester.pumpAndSettle();
    expect(row('chapter'), findsOneWidget);
    expect(row('trip-chapter'), findsOneWidget);
    expect(find.text('媒体库 / 课程 / 数学 · 0 项'), findsOneWidget);
    expect(find.text('媒体库 / 旅行 · 0 项'), findsOneWidget);
    await tester.tap(radio('chapter'));
    await tester.pumpAndSettle();
    await tester.tap(radio('trip-chapter'));
    await tester.pumpAndSettle();
    expect(selected(tester), 'trip-chapter');
    await tester.tap(confirm());
    await tester.pumpAndSettle();
    expect(result, 'trip-chapter');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system back goes up a level while keeping the single selection',
    (tester) async {
      await open(tester);
      await tester.tap(radio('courses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('课程'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(row('trips'), findsOneWidget);
      expect(selected(tester), 'courses');
      expect(closed, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
    },
  );

  testWidgets('recycling an ancestor clears a chosen descendant', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    await tester.tap(radio('math'));
    await tester.pumpAndSettle();
    expect(selected(tester), 'math');
    await tester.runAsync(() => library.moveToRecycleBin(['courses']));
    await tester.pumpAndSettle();
    expect(selected(tester), isNull);
    expect(row('courses'), findsNothing);
    expect(row('trips'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty library cannot confirm the library root', (tester) async {
    library.resetLibraryForTesting();
    await open(tester);
    expect(find.text('媒体库里还没有文件夹，请先在媒体库添加。'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the page back button returns to the caller from the library root',
    (tester) async {
      await open(tester);
      await tester.tap(radio('courses'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
      expect(
        find.byKey(const ValueKey('sync-folder-picker-page')),
        findsNothing,
      );
      expect(find.text('选择文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search keeps the selected path and confirmation above the keyboard',
    (tester) async {
      await open(tester);
      await tester.tap(radio('courses'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-picker-search')),
        '第一章',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(confirm()).dy, lessThanOrEqualTo(844 - 300));
      expect(getSelection().hitTestable(), findsOneWidget);
      expect(tester.widget<Text>(getSelection()).data, '已选：媒体库 / 课程');
      expect(confirm().hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect(result, 'courses');
    },
  );

  testWidgets(
    'phone and desktop use a full page and keep confirmation visible',
    (tester) async {
      for (final (size, scale) in [
        (const Size(320, 640), 1.6),
        (const Size(390, 844), 1.0),
        (const Size(1120, 800), 1.0),
      ]) {
        await open(tester, size: size, scale: scale);
        final page = find.byKey(const ValueKey('sync-folder-picker-page'));
        expect(page, findsOneWidget);
        expect(tester.getSize(page), size);
        expect(
          tester.getSize(find.byType(LibraryFolderPicker)),
          Size(size.width, size.height - kToolbarHeight),
        );
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        await tester.tap(radio('courses'));
        await tester.pumpAndSettle();
        expect(confirm().hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(confirm());
        await tester.pumpAndSettle();
        expect(result, 'courses');
      }
    },
  );

  testWidgets('render folder picker previews', (tester) async {
    if (Platform.environment['SYNC_FOLDER_PICKER_PREVIEW'] != '1') return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final size in [const Size(390, 844), const Size(1120, 800)]) {
      final capture = GlobalKey();
      await open(tester, size: size, capture: capture);
      await tester.tap(find.text('课程'));
      await tester.pumpAndSettle();
      await tester.tap(radio('math'));
      await tester.pumpAndSettle();
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '.artifacts/progress-sync/folder-picker-page-${size.width.toInt()}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
  });
}
