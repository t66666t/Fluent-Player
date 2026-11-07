import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/podcasts/podcast_episode_press.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_haptics.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_item_interaction_wrapper.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

const _light = 'HapticFeedbackType.lightImpact';
const _selection = 'HapticFeedbackType.selectionClick';

void main() {
  final feedback = <Object?>[];
  late SettingsService settings;
  late MediaPlaybackService playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    playback = MediaPlaybackService();
    await playback.stop();
    feedback.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() async {
    await playback.stop();
    settings.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
    ],
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  VideoItem media() => VideoItem(
    id: 'card-media',
    path: 'card.mp4',
    title: 'Media item',
    durationMs: 120000,
    lastUpdated: 0,
  );
  VideoCollection folder() =>
      VideoCollection(id: 'card-folder', name: 'Folder item', createTime: 0);

  Widget card(String kind, VoidCallback onTap, {VoidCallback? onHold}) {
    final folderCard = MediaLibraryFolderGridCard(
      collection: folder(),
      titleScale: 1,
      onTap: onTap,
      showActivityMenu: false,
      onLongPress: kind == 'adaptive-folder' ? null : onHold,
    );
    return switch (kind) {
      'media-grid' => MediaLibraryMediaGridCard(
        item: media(),
        titleScale: 1,
        onTap: onTap,
        onLocate: () {},
        showLocate: false,
        showActivityMenu: false,
        coverOverride: const ColoredBox(color: Colors.blue),
      ),
      'folder-grid' => folderCard,
      'media-list' => MediaLibraryListTile.video(
        item: media(),
        index: 0,
        showIndex: false,
        showThumbnail: false,
        isSelected: false,
        isSelectionMode: false,
        titleScale: 1,
        onTap: onTap,
      ),
      'folder-list' => MediaLibraryListTile.collection(
        collection: folder(),
        index: 0,
        showIndex: false,
        showThumbnail: false,
        isSelected: false,
        isSelectionMode: false,
        titleScale: 1,
        onTap: onTap,
      ),
      'podcast-episode' => Material(
        child: PodcastEpisodePress(
          selecting: false,
          onOpen: onTap,
          onLongPress: onHold,
          child: const Center(child: Text('Podcast episode')),
        ),
      ),
      'adaptive-folder' => MediaLibraryItemInteractionWrapper(
        index: 0,
        dragDelay: const Duration(milliseconds: 160),
        isSelected: false,
        selectedCount: 0,
        onDragStarted: onHold ?? () {},
        onReorder: (_, _) {},
        onTap: onTap,
        child: folderCard,
      ),
      _ => MiniPlaybackCard(isVisible: true, onTap: onTap),
    };
  }

  for (final kind in [
    'media-grid',
    'folder-grid',
    'media-list',
    'folder-list',
    'podcast-episode',
    'adaptive-folder',
    'mini',
  ]) {
    testWidgets(
      '$kind: one pulse per accepted tap; the switch silences it',
      (tester) async {
        if (kind == 'mini') {
          playback.publishRestoredSessionPreview(
            VideoItem(
              id: 'mini',
              path: 'mini.mp4',
              title: 'Mini haptics',
              durationMs: 120000,
              lastUpdated: 0,
            ),
            Duration.zero,
          );
        }
        var opens = 0;
        await tester.pumpWidget(
          host(
            SizedBox(
              key: const ValueKey('test-card'),
              width: kind == 'mini' ? 430 : 280,
              height: kind.contains('list') || kind == 'podcast-episode'
                  ? 90
                  : 320,
              child: card(kind, () => opens++),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(feedback, isEmpty);
        final target = kind == 'mini'
            ? find.text('Mini haptics')
            : find.byKey(const ValueKey('test-card'));
        await tester.tap(target);
        await tester.pump();
        expect(opens, 1);
        final mobile =
            Theme.of(tester.element(target)).platform != TargetPlatform.windows;
        expect(feedback, mobile ? [_light] : isEmpty);
        await settings.saveEnableHapticFeedback(false);
        feedback.clear();
        await tester.tap(target);
        await tester.pump();
        expect(opens, 2);
        expect(feedback, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'a nested card button owns its feedback; scrolling and holding do not activate cards',
    (tester) async {
      var opens = 0;
      var buttons = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 280,
            height: 280,
            child: ListView(
              children: [
                SizedBox(
                  height: 180,
                  child: MediaLibraryGridCard(
                    radius: 8,
                    isSelected: false,
                    onTap: () => opens++,
                    child: Center(
                      child: IconButton(
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () {
                          buttons++;
                          unawaited(AppHaptics.selectionClick(settings));
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 600),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      expect(buttons, 1);
      expect(opens, 0);
      expect(feedback, [_selection]);
      feedback.clear();
      await tester.drag(
        find.byType(MediaLibraryGridCard),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(feedback, isEmpty);

      var holds = 0;
      for (final kind in [
        'folder-grid',
        'podcast-episode',
        'adaptive-folder',
      ]) {
        await tester.pumpWidget(
          host(
            SizedBox(
              key: const ValueKey('hold-card'),
              width: 280,
              height: 320,
              child: card(kind, () => opens++, onHold: () => holds++),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('hold-card'))),
        );
        await tester.pump(const Duration(milliseconds: 800));
        await gesture.up();
        await tester.pump();
      }
      expect(holds, 3);
      expect(opens, 0);
      expect(feedback, isEmpty);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mini slider feedback does not also activate the playback card',
    (tester) async {
      playback.publishRestoredSessionPreview(
        VideoItem(
          id: 'mini-progress',
          path: 'mini.mp4',
          title: 'Mini progress',
          durationMs: 120000,
          lastUpdated: 0,
        ),
        Duration.zero,
      );
      var opens = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 430,
            child: MiniPlaybackCard(isVisible: true, onTap: () => opens++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Slider));
      await tester.pump();
      expect(opens, 0);
      expect(feedback, [_selection]);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  // 社区版已退役云盘浏览 UI；CloudDriveScreen 若仍留在 lib/ 也不维护交互触觉测试。
}
