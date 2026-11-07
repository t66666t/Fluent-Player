import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/batch_import_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';

class _Batch extends ChangeNotifier implements BatchImportService {
  final state = FolderBatchState();
  int serial = 0;
  int addCalls = 0;
  Completer<void>? addGate;
  @override
  double fontSize = 14;
  void _pad() {
    final length = state.videoItems.length > state.subtitleItems.length
        ? state.videoItems.length
        : state.subtitleItems.length;
    while (state.videoItems.length < length) {
      state.videoItems.add(BatchItem(id: 'empty-media-${serial++}'));
    }
    while (state.subtitleItems.length < length) {
      state.subtitleItems.add(BatchItem(id: 'empty-subtitle-${serial++}'));
    }
  }

  @override
  List<BatchItem> getVideoItems(String? folderId) {
    _pad();
    return state.videoItems;
  }

  @override
  List<BatchItem> getSubtitleItems(String? folderId) {
    _pad();
    return state.subtitleItems;
  }

  @override
  bool isImported(String? folderId, String path) =>
      state.importedVideoIds.containsKey(path);
  @override
  String? getImportedId(String? folderId, String path) =>
      state.importedVideoIds[path];
  @override
  String? getDuration(String? folderId, String path) => '12:34';
  @override
  Future<void> addVideos(
    String? folderId,
    List<String> paths, {
    List<String>? titles,
  }) async {
    addCalls++;
    await addGate?.future;
    _add(state.videoItems, paths);
    _pad();
    notifyListeners();
  }

  @override
  Future<void> addSubtitles(String? folderId, List<String> paths) async {
    _add(state.subtitleItems, paths);
    _pad();
    notifyListeners();
  }

  void _add(List<BatchItem> items, List<String> paths) {
    for (final path in paths) {
      if (items.any((item) => item.path == path)) continue;
      final empty = items.indexWhere((item) => item.path == null);
      if (empty >= 0) {
        items[empty].path = path;
      } else {
        items.add(BatchItem(id: 'file-${serial++}', path: path));
      }
    }
  }

  @override
  Future<void> moveVideo(String? folderId, int from, int to) async {
    state.videoItems.insert(to, state.videoItems.removeAt(from));
    notifyListeners();
  }

  @override
  Future<void> moveSubtitle(String? folderId, int from, int to) async {
    state.subtitleItems.insert(to, state.subtitleItems.removeAt(from));
    notifyListeners();
  }

  @override
  Future<void> removeVideoItem(String? folderId, int index) async {
    state.videoItems.removeAt(index);
    _pad();
    notifyListeners();
  }

  @override
  Future<void> removeSubtitleItem(String? folderId, int index) async {
    state.subtitleItems.removeAt(index);
    _pad();
    notifyListeners();
  }

  @override
  Future<void> removeRow(String? folderId, int index) async {
    state.videoItems.removeAt(index);
    state.subtitleItems.removeAt(index);
    notifyListeners();
  }

  @override
  Future<void> markImported(String? folderId, String path, String id) async {
    state.importedVideoIds[path] = id;
    notifyListeners();
  }

  @override
  Future<void> unmarkImported(String? folderId, String path) async {
    state.importedVideoIds.remove(path);
    notifyListeners();
  }

  @override
  Future<void> setFontSize(double size) async {
    fontSize = size;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends ChangeNotifier implements LibraryService {
  final imported = <VideoItem>[];
  final parents = <String?>[];
  final removed = <String>[];
  String? failPath;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #resolveImportCardParentId) {
      final parent = invocation.namedArguments[#openedFromFolderId] as String?;
      parents.add(parent);
      return Future<String?>.value(parent);
    }
    if (invocation.memberName == #addSingleVideo) {
      final item = invocation.positionalArguments.single as VideoItem;
      if (item.path == failPath) {
        return Future<String?>.error(
          const FileSystemException('unreadable file'),
        );
      }
      imported.add(item);
      return Future<String?>.value(item.id);
    }
    if (invocation.memberName == #removeSingleVideo) {
      expect(invocation.namedArguments[#keepFile], isTrue);
      removed.add(invocation.positionalArguments.single as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Picker extends FilePicker {
  List<String> paths = [];
  final requests = <List<String>?>[];
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(allowMultiple, isTrue);
    expect(withData, isFalse);
    requests.add(allowedExtensions);
    return FilePickerResult([
      for (final path in paths)
        PlatformFile(name: p.basename(path), path: path, size: 0),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FilePicker.platform = _Picker();
  late Directory root;
  late _Batch batch;
  late _Library library;
  late _Picker picker;
  late FilePicker originalPicker;
  final navigator = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('paired_import_ui_');
    batch = _Batch();
    library = _Library();
    picker = _Picker();
    originalPicker = FilePicker.platform;
    FilePicker.platform = picker;
  });
  tearDown(() async {
    FilePicker.platform = originalPicker;
    batch.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });
  Future<String> file(String name) async {
    final target = File(p.join(root.path, name));
    target.writeAsStringSync('fixture');
    return target.path;
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<BatchImportService>.value(value: batch),
          ChangeNotifierProvider<LibraryService>.value(value: library),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'PreviewCJK',
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: const BatchImportScreen(folderId: 'course'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void drop(WidgetTester tester, List<String> paths) =>
      tester
          .widget<DropTarget>(
            find.byKey(const ValueKey('batch-import-drop-target')),
          )
          .onDragDone!(
        DropDoneDetails(
          files: paths.map(DropItemFile.new).toList(),
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
  Future<void> settleFiles(WidgetTester tester) async {
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mixed picker is shared by all five platforms; other files are ignored',
    (tester) async {
      final a = await file('02.mp4');
      final b = await file('01.flac');
      final sub = await file('02.SRT');
      final ignored = await file('cover.png');
      picker.paths = [sub, a, ignored, b, a];
      await mount(tester, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('batch-import-pick-files')));
      await settleFiles(tester);
      expect(
        batch.state.videoItems.map((item) => item.path).whereType<String>(),
        [a, b],
      );
      expect(
        batch.state.subtitleItems.map((item) => item.path).whereType<String>(),
        [sub],
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(
        picker.requests.single,
        containsAll(['mp4', 'flac', 'srt', 'zip']),
      );
      expect(
        tester.widget<DropTarget>(find.byType(DropTarget)).enable,
        {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform),
      );
      expect(
        library.imported,
        isEmpty,
      ); // Adding files requires a later explicit import.
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'desktop drops queue in order, deduplicate and leave covered routes alone',
    (tester) async {
      final a = await file('02.mp4');
      final b = await file('01.mp4');
      final sub = await file('02.srt');
      final gate = Completer<void>();
      batch.addGate = gate;
      await mount(tester);
      drop(tester, [a, sub]);
      for (var i = 0; i < 20 && batch.addCalls == 0; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      drop(tester, [a, b]);
      await tester.pump();
      expect(batch.addCalls, 1);
      gate.complete();
      await settleFiles(tester);
      expect(batch.state.videoItems.map((item) => item.path), [a, b]);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final target = tester.widget<DropTarget>(
        find.byType(DropTarget, skipOffstage: false),
      );
      expect(target.enable, isFalse);
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(await file('not-added.mp4'))],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(batch.addCalls, 2);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'subtitle ZIP drops only add subtitles and keep adjacent input order',
    (tester) async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('inside.srt', 'subtitle'))
        ..addFile(ArchiveFile.string('ignore.mp4', 'media'))
        ..addFile(ArchiveFile.string('ignore.txt', 'notes'));
      final zip = File(p.join(root.path, 'subtitles.zip'));
      zip.writeAsBytesSync(ZipEncoder().encode(archive));
      final before = await file('before.srt');
      final after = await file('after.vtt');
      await mount(tester);
      drop(tester, [before, zip.path, after]);
      await settleFiles(tester);
      final added = batch.state.subtitleItems
          .map((item) => item.path!)
          .toList();
      expect(added.map(p.basename), ['before.srt', 'inside.srt', 'after.vtt']);
      expect(
        batch.state.videoItems.where((item) => item.path != null),
        isEmpty,
      );
      expect(library.imported, isEmpty);
      await tester.pumpWidget(const SizedBox());
      // Extracted subtitles intentionally survive the page; remove this test's cache.
      Directory(p.dirname(added[1])).deleteSync(recursive: true);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'bulk import preserves row pairs and folder, continues failures, retry skips successes; undo keeps files',
    (tester) async {
      final a = await file('a.mp4');
      final b = await file('b.mp3');
      final c = await file('c.mp4');
      final subA = await file('a.srt');
      final subB = await file('b.srt');
      await batch.addVideos('course', [a, b, c]);
      await batch.addSubtitles('course', [subA, subB]);
      library.failPath = b;
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('batch-import-all')));
      await tester.pumpAndSettle();
      expect(library.imported.map((item) => item.path), [a, c]);
      expect(library.imported.map((item) => item.subtitlePath), [subA, null]);
      expect(library.parents, everyElement('course'));
      expect(find.text('1 项未导入'), findsOneWidget);
      library.failPath = null;
      await tester.tap(find.byKey(const ValueKey('batch-import-all')));
      await tester.pumpAndSettle();
      expect(library.imported.map((item) => item.path), [a, c, b]);
      expect(library.imported.last.subtitlePath, subB);
      await tester.tap(find.byTooltip('撤回导入（保留文件）').first);
      await tester.pumpAndSettle();
      expect(library.removed, hasLength(1));
      expect(File(a).existsSync(), isTrue);
      expect(batch.isImported('course', a), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(640, 360),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'populated table and controls fit $size with enlarged text',
      (tester) async {
        await batch.addVideos('course', [
          await file('A long lesson title.mp4'),
        ]);
        await batch.addSubtitles('course', [
          await file('A long subtitle name.srt'),
        ]);
        batch.fontSize = 30;
        await mount(tester, size: size, textScale: 2);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('batch-import-all')).hitTestable(),
          findsOneWidget,
        );
        final scroll = tester.widget<SingleChildScrollView>(
          find.byKey(const ValueKey('batch-import-horizontal-scroll')),
        );
        expect(
          scroll.controller!.position.maxScrollExtent,
          size.width < 640 ? greaterThan(0) : 0,
        );
        if (scroll.controller!.position.maxScrollExtent > 0) {
          await tester.drag(
            find.byKey(const ValueKey('batch-import-horizontal-scroll')),
            const Offset(-400, 0),
          );
          await tester.pumpAndSettle();
          expect(scroll.controller!.position.pixels, greaterThan(0));
          expect(
            batch.state.videoItems.where((item) => item.path != null),
            hasLength(1),
          );
          expect(
            batch.state.subtitleItems.where((item) => item.path != null),
            hasLength(1),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    'compact rows show both files and retain import, undo and removal',
    (tester) async {
      final media = await file('lesson.mp4');
      final subtitle = await file('lesson.srt');
      await batch.addVideos('course', [media]);
      await batch.addSubtitles('course', [subtitle]);
      await mount(tester, size: const Size(320, 568));
      for (final filename in ['lesson', 'lesson.srt']) {
        final rect = tester.getRect(find.text(filename));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }
      final horizontal = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('batch-import-horizontal-scroll')),
      );
      expect(horizontal.controller!.position.maxScrollExtent, 0);

      Future<void> action(String label) async {
        await tester.tap(
          find.byKey(const ValueKey('batch-import-row-actions-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is PopupMenuItem &&
                widget.child is Text &&
                (widget.child as Text).data == label,
          ),
        );
        await tester.pumpAndSettle();
      }

      await action('导入');
      expect(library.imported.single.subtitlePath, subtitle);
      expect(batch.isImported('course', media), isTrue);
      await action('撤回导入');
      expect(batch.isImported('course', media), isFalse);
      expect(library.removed, hasLength(1));
      await action('移除字幕');
      expect(
        batch.state.subtitleItems.where((item) => item.path != null),
        isEmpty,
      );
      expect(batch.state.videoItems.single.path, media);
      await action('移除整行');
      expect(batch.state.videoItems, isEmpty);
      expect(File(media).existsSync(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'column actions open the correct picker without another page',
    (tester) async {
      final media = await file('lesson.mp4');
      final subtitle = await file('lesson.srt');
      await mount(tester, size: const Size(390, 844));
      picker.paths = [media];
      await tester.tap(find.byKey(const ValueKey('batch-import-add-media')));
      await settleFiles(tester);
      expect(picker.requests.last, contains('mp4'));
      expect(picker.requests.last, isNot(contains('srt')));
      picker.paths = [subtitle];
      await tester.tap(
        find.byKey(const ValueKey('batch-import-add-subtitles')),
      );
      await settleFiles(tester);
      expect(picker.requests.last, containsAll(['srt', 'zip']));
      expect(picker.requests.last, isNot(contains('mp4')));
      expect(batch.state.videoItems.single.path, media);
      expect(batch.state.subtitleItems.single.path, subtitle);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'font size, gallery access and keyboard help remain reachable',
    (tester) async {
      await mount(tester, size: const Size(320, 568));
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(
        find.text('从相册添加'),
        {
              TargetPlatform.android,
              TargetPlatform.iOS,
            }.contains(defaultTargetPlatform)
            ? findsOneWidget
            : findsNothing,
      );
      await tester.tap(find.text('字号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      expect(batch.fontSize, 20);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('快捷键'), findsOneWidget);
      expect(find.text('I'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mouse drags each column independently using the file icon',
    (tester) async {
      final media = [for (var i = 0; i < 3; i++) await file('media-$i.mp4')];
      final subtitles = [
        for (var i = 0; i < 3; i++) await file('subtitle-$i.srt'),
      ];
      await batch.addVideos('course', media);
      await batch.addSubtitles('course', subtitles);
      await mount(tester);

      Future<void> reorder(List<BatchItem> items) async {
        final first = find.byKey(
          ValueKey('batch-import-grip-${items.first.id}'),
        );
        final last = find.byKey(ValueKey('batch-import-grip-${items.last.id}'));
        final from = tester.getCenter(first);
        final to = tester.getCenter(last) + const Offset(0, 16);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: from + const Offset(80, 0));
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(from);
        await tester.pump();
        expect(
          find.descendant(
            of: first,
            matching: find.byIcon(Icons.drag_handle_rounded),
          ),
          findsOneWidget,
        );
        await gesture.down(from);
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump();
        for (var step = 1; step <= 16; step++) {
          await gesture.moveTo(
            Offset.lerp(from + const Offset(0, 10), to, step / 16)!,
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();
        await gesture.removePointer();
      }

      final cell = find.byKey(
        ValueKey('batch-cell-media-${batch.state.videoItems.first.id}'),
      );
      expect(tester.getSize(cell).height, lessThanOrEqualTo(40));
      expect(tester.getTopLeft(cell).dy, lessThan(100));
      await reorder(batch.state.videoItems);
      expect(batch.state.videoItems.map((item) => item.path), [
        media[1],
        media[2],
        media[0],
      ]);
      expect(batch.state.subtitleItems.map((item) => item.path), subtitles);
      await reorder(batch.state.subtitleItems);
      expect(batch.state.subtitleItems.map((item) => item.path), [
        subtitles[1],
        subtitles[2],
        subtitles[0],
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'touch long press reorders a file while quick swipes scroll the list',
    (tester) async {
      final media = [for (var i = 0; i < 20; i++) await file('touch-$i.mp4')];
      final subtitles = [
        for (var i = 0; i < 20; i++) await file('touch-$i.srt'),
      ];
      await batch.addVideos('course', media);
      await batch.addSubtitles('course', subtitles);
      await mount(tester, size: const Size(390, 640));
      final firstCell = find.byKey(
        ValueKey('batch-cell-media-${batch.state.videoItems.first.id}'),
      );
      expect(tester.getSize(firstCell).height, greaterThanOrEqualTo(48));
      expect(tester.getTopLeft(firstCell).dy, lessThan(120));
      final from = tester.getCenter(find.text('touch-0'));
      final target =
          tester.getCenter(find.text('touch-2')) + const Offset(0, 20);
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 600));
      for (var step = 1; step <= 16; step++) {
        await gesture.moveTo(Offset.lerp(from, target, step / 16)!);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(batch.state.videoItems.take(3).map((item) => item.path), [
        media[1],
        media[2],
        media[0],
      ]);
      expect(batch.state.subtitleItems.map((item) => item.path), subtitles);
      final beforeScroll = batch.state.videoItems
          .map((item) => item.path)
          .toList();
      await tester.dragFrom(
        tester.getCenter(find.text('touch-1')),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byKey(const ValueKey('batch-media-list')),
      );
      expect(list.scrollController!.position.pixels, greaterThan(0));
      expect(batch.state.videoItems.map((item) => item.path), beforeScroll);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('page previews', (tester) async {
    if (Platform.environment['BATCH_IMPORT_PREVIEW'] != '1') return;
    final font = FontLoader('PreviewCJK')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await tester.runAsync(font.load);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await tester.runAsync(icons.load);
    await batch.addVideos('course', [
      await file('01 · 从一段视频开始.mp4'),
      await file('02 · 学习笔记与复习.mp4'),
      await file('03 · 听懂一段播客.mp3'),
    ]);
    await batch.addSubtitles('course', [
      await file('01 · 中文字幕.srt'),
      await file('02 · 英文字幕.vtt'),
    ]);
    for (final (label, size) in [
      ('desktop', const Size(1200, 800)),
      ('mobile', const Size(390, 844)),
    ]) {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = label == 'desktop'
          ? TargetPlatform.windows
          : TargetPlatform.android;
      await mount(tester, size: size);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1.5);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File(
          '.dart_tool/batch_import_$label.png',
        ).writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}
