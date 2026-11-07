import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_view_mode.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'package:video_player_app/widgets/media_library_table_header.dart';
import 'package:video_player_app/widgets/media_library_table_row.dart';
import 'package:video_player_app/widgets/media_library_table_sort.dart';
import 'package:video_player_app/widgets/media_library_view_defaults.dart';

MediaListStyleSettings _tableStyle({
  required double rowExtent,
  Set<MediaTableColumn>? columns,
}) {
  return MediaListStyleSettings(
    layout: MediaLibraryContentLayout.table,
    crossAxisCount: 1,
    rowExtent: rowExtent,
    titleSize: 12,
    titleLines: 1,
    crossSpacing: 0,
    mainSpacing: 0,
    outerPadding: 8,
    showThumbnail: true,
    showIndex: false,
    striped: true,
    tableColumns:
        columns ??
        const {
          MediaTableColumn.type,
          MediaTableColumn.duration,
          MediaTableColumn.progress,
          MediaTableColumn.updated,
        },
    titleScale: 0.1,
    heightScale: 1,
    crossSpacingScale: 0,
    mainSpacingScale: 0,
  );
}

Widget _wrapRow({
  required Widget child,
  required double width,
  required double height,
}) {
  return ChangeNotifierProvider<MediaPlaybackService>.value(
    value: MediaPlaybackService(),
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

MediaLibraryTableRow _videoRow({required double rowExtent}) {
  final item = VideoItem(
    id: 'v1',
    path: 'a.mp4',
    title: '示例视频标题',
    durationMs: 125000,
    lastPositionMs: 62000,
    lastUpdated: DateTime(2024, 6, 2).millisecondsSinceEpoch,
    subtitlePath: 'a.srt',
  );
  return MediaLibraryTableRow(
    tile: MediaLibraryListTile.video(
      item: item,
      index: 1,
      showIndex: false,
      showThumbnail: true,
      isSelected: false,
      isSelectionMode: false,
      titleScale: 0.1,
      onTap: () {},
      relativePath: '媒体/示例',
      style: _tableStyle(rowExtent: rowExtent),
    ),
    style: _tableStyle(rowExtent: rowExtent),
    openMenu: () {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sortMediaLibraryContents', () {
    VideoCollection folder(String id, {List<String>? children}) =>
        VideoCollection(
          id: id,
          name: id,
          createTime: 100,
          childrenIds: children ?? const ['a'],
        );

    VideoItem video(String id, {int duration = 1000, int progress = 0}) =>
        VideoItem(
          id: id,
          path: '$id.mp4',
          title: id,
          durationMs: duration,
          lastPositionMs: progress,
          lastUpdated: 200,
        );

    test('manual 原样返回同一列表实例', () {
      final input = <dynamic>[video('b'), folder('f'), video('a')];
      final output = sortMediaLibraryContents(
        input,
        MediaTableSortKey.manual,
        false,
      );
      expect(identical(output, input), isTrue);
    });

    test('文件夹始终排在媒体之前', () {
      final input = <dynamic>[
        video('z'),
        folder('f1'),
        video('a'),
        folder('f0'),
      ];
      final sorted = sortMediaLibraryContents(
        input,
        MediaTableSortKey.title,
        false,
      );
      expect(sorted[0], isA<VideoCollection>());
      expect(sorted[1], isA<VideoCollection>());
      expect(sorted[2], isA<VideoItem>());
      expect(sorted[3], isA<VideoItem>());
    });

    test('标题自然排序且稳定', () {
      final input = <dynamic>[video('张三10'), video('A02'), video('A1')];
      final asc = sortMediaLibraryContents(
        input,
        MediaTableSortKey.title,
        false,
      );
      expect(asc.map((e) => (e as VideoItem).title).toList(), [
        'A1',
        'A02',
        '张三10',
      ]);
      final desc = sortMediaLibraryContents(
        input,
        MediaTableSortKey.title,
        true,
      );
      expect(desc.map((e) => (e as VideoItem).title).toList(), [
        '张三10',
        'A02',
        'A1',
      ]);
    });

    test('时长与进度升降序', () {
      final input = <dynamic>[
        video('a', duration: 100, progress: 10),
        video('b', duration: 300, progress: 150),
        video('c', duration: 200, progress: 50),
      ];
      final byDuration = sortMediaLibraryContents(
        input,
        MediaTableSortKey.duration,
        false,
      );
      expect(byDuration.map((e) => (e as VideoItem).durationMs).toList(), [
        100,
        200,
        300,
      ]);
      final byProgress = sortMediaLibraryContents(
        input,
        MediaTableSortKey.progress,
        true,
      );
      expect(byProgress.map((e) => (e as VideoItem).lastPositionMs).toList(), [
        150,
        50,
        10,
      ]);
    });
  });

  group('MediaLibraryTableRow layout', () {
    for (final height in [28.0, 36.0, 96.0]) {
      testWidgets('宽表格行高 $height 不溢出', (tester) async {
        await tester.pumpWidget(
          _wrapRow(
            width: 900,
            height: height,
            child: _videoRow(rowExtent: height),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('media-table-title')), findsOneWidget);
      });

      testWidgets('窄表格行高 $height 不溢出', (tester) async {
        await tester.pumpWidget(
          _wrapRow(
            width: MediaLibraryViewDefaults.tableCompactBreakpoint - 40,
            height: height,
            child: _videoRow(rowExtent: height),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('表头点击在 manual→升序→降序→manual 间循环', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    final style = _tableStyle(rowExtent: 36);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 40,
            child: MediaLibraryTableHeader(style: style, width: 900),
          ),
        ),
      ),
    );

    expect(settings.mediaTableSort, MediaTableSortKey.manual);

    await tester.tap(find.byKey(const ValueKey('media-table-header-title')));
    await tester.pumpAndSettle();
    expect(settings.mediaTableSort, MediaTableSortKey.title);
    expect(settings.mediaTableSortDescending, isFalse);

    await tester.tap(find.byKey(const ValueKey('media-table-header-title')));
    await tester.pumpAndSettle();
    expect(settings.mediaTableSort, MediaTableSortKey.title);
    expect(settings.mediaTableSortDescending, isTrue);

    await tester.tap(find.byKey(const ValueKey('media-table-header-title')));
    await tester.pumpAndSettle();
    expect(settings.mediaTableSort, MediaTableSortKey.manual);
  });

  testWidgets('existing table title follows the local extension toggle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final row = _videoRow(rowExtent: 36);
    row.tile.video!.title = 'Lesson.mp4';
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: _wrapRow(child: row, width: 1000, height: 36),
      ),
    );
    expect(find.text('Lesson'), findsOneWidget);
    expect(find.text('Lesson.mp4'), findsNothing);
    await settings.updateSetting('showLocalMediaExtensions', true);
    await tester.pump();
    expect(find.text('Lesson.mp4'), findsOneWidget);
    expect(row.tile.video!.title, 'Lesson.mp4');
    expect(row.tile.video!.path, 'a.mp4');
    expect(tester.takeException(), isNull);
  });
}
