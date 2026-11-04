import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

void main() {
  VideoItem item(int index) {
    return VideoItem(
      id: 'video-$index',
      path: '/videos/$index.mp4',
      title: '视频 $index',
      durationMs: 125000,
      lastUpdated: 0,
    );
  }

  /// 打开后的定位是分帧完成的：先等当前行建出来，再按视口高度微调。
  Future<void> pumpSheet(
    WidgetTester tester, {
    required List<VideoItem> playlist,
    required String currentItemId,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: 640,
              width: 400,
              child: PlaylistBottomSheet(
                playlist: playlist,
                currentItemId: currentItemId,
                onItemTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump();
    }
  }

  /// 当前行中心在列表视口里的高度比例。0 是视口顶，1 是视口底。
  double centerFraction(WidgetTester tester, String title) {
    final row = find.ancestor(
      of: find.text(title),
      matching: find.byType(InkWell),
    );
    expect(row, findsOneWidget);
    final rowRect = tester.getRect(row);
    final listRect = tester.getRect(find.byType(ListView));
    return (rowRect.center.dy - listRect.top) / listRect.height;
  }

  testWidgets('当前视频打开时落在列表视口大约 30% 的位置', (tester) async {
    final playlist = List<VideoItem>.generate(40, item);
    await pumpSheet(tester, playlist: playlist, currentItemId: playlist[20].id);

    expect(centerFraction(tester, '视频 20'), closeTo(0.30, 0.05));
    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(controller.position.maxScrollExtent));
  });

  testWidgets('列表开头的视频保持在顶部，不硬推到 30%', (tester) async {
    final playlist = List<VideoItem>.generate(40, item);
    await pumpSheet(tester, playlist: playlist, currentItemId: playlist[0].id);

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, 0);
    expect(centerFraction(tester, '视频 0'), lessThan(0.2));
  });

  testWidgets('列表末尾的视频停在滚动尽头，不硬拉到 30%', (tester) async {
    final playlist = List<VideoItem>.generate(40, item);
    await pumpSheet(
      tester,
      playlist: playlist,
      currentItemId: playlist.last.id,
    );

    final controller = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1));
    expect(centerFraction(tester, '视频 39'), greaterThan(0.5));
  });

  testWidgets('迷你播放卡片那种底部弹窗打开时也会定位到当前视频', (tester) async {
    final playlist = List<VideoItem>.generate(40, item);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Colors.transparent,
                    isScrollControlled: true,
                    builder: (context) {
                      return DraggableScrollableSheet(
                        initialChildSize: 0.6,
                        minChildSize: 0.3,
                        maxChildSize: 0.9,
                        expand: false,
                        builder: (context, scrollController) {
                          return PlaylistBottomSheet(
                            playlist: playlist,
                            currentItemId: playlist[20].id,
                            scrollController: scrollController,
                            onItemTap: (_) {},
                          );
                        },
                      );
                    },
                  );
                },
                child: const Text('播放列表'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('播放列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump();
    }

    expect(centerFraction(tester, '视频 20'), closeTo(0.30, 0.08));
  });
}
