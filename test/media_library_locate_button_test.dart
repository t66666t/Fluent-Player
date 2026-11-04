import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/media_library_action_dock.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';

void main() {
  test('grid chips track card width; list chips track row height', () {
    expect(MediaLibraryActionDockMetrics.gridChipSize(100), 19);
    expect(MediaLibraryActionDockMetrics.gridChipSize(200), 38);
    expect(MediaLibraryActionDockMetrics.listChipSize(64), closeTo(30.08, 0.01));
    expect(
      MediaLibraryActionDockMetrics.dockWidth(
        chipSize: 19,
        showMore: true,
        showLocate: true,
      ),
      38,
    );
  });

  testWidgets('点击定位按钮不会穿透并触发媒体卡片播放', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    var cardTapCount = 0;
    var locateTapCount = 0;
    final item = VideoItem(
      id: 'video-1',
      path: 'video.mp4',
      title: '测试媒体',
      durationMs: 60000,
      lastUpdated: 0,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
        child: ChangeNotifierProvider<LibraryService>.value(
          value: LibraryService()..resetLibraryForTesting(),
          child: MaterialApp(
            home: Center(
              child: SizedBox(
                width: 420,
                height: 64,
                child: MediaLibraryListTile.video(
                  item: item,
                  index: 0,
                  showIndex: false,
                  showThumbnail: false,
                  isSelected: false,
                  isSelectionMode: false,
                  titleScale: 0.065,
                  onTap: () => cardTapCount++,
                  onShowInParentFolder: () => locateTapCount++,
                  showActivityMenu: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('show-in-parent-folder-button')),
    );
    await tester.pump();
    expect(locateTapCount, 1);
    expect(cardTapCount, 0);

    await tester.tap(find.text('测试媒体'));
    await tester.pump();
    expect(cardTapCount, 1);
  });

  testWidgets('列表定位底栏贴合右下角，标题折在底栏左侧', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final library = LibraryService()..resetLibraryForTesting();
    final item = VideoItem(
      id: 'video-2',
      path: 'video-2.mp4',
      title: '定位按钮不会挤压标题显示宽度',
      durationMs: 60000,
      lastUpdated: 0,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: ChangeNotifierProvider<MediaPlaybackService>.value(
          value: MediaPlaybackService(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 420,
                height: 64,
                child: MediaLibraryListTile.video(
                  item: item,
                  index: 0,
                  showIndex: false,
                  showThumbnail: false,
                  isSelected: false,
                  isSelectionMode: false,
                  titleScale: 0.065,
                  onTap: () {},
                  onShowInParentFolder: () {},
                  showActivityMenu: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final surface = find.byKey(
      const ValueKey('show-in-parent-folder-button-surface'),
    );
    final card = find.byKey(const ValueKey('media-list-card'));
    final title = find.byKey(const ValueKey('media-list-title'));
    final surfaceRect = tester.getRect(surface);
    final cardRect = tester.getRect(card);
    final titleRect = tester.getRect(title);
    expect(surfaceRect.right, closeTo(cardRect.right, 0.5));
    expect(surfaceRect.bottom, closeTo(cardRect.bottom, 0.5));
    expect(surfaceRect.width, closeTo(surfaceRect.height, 0.5));
    expect(titleRect.right, lessThanOrEqualTo(surfaceRect.left + 1));
    expect(tester.takeException(), isNull);
  });
}
