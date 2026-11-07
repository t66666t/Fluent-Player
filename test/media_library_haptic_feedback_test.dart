import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_anchor_menu.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';
import 'package:video_player_app/widgets/media_library_settings_controls.dart';
import 'package:video_player_app/widgets/playback_mode_button.dart';
import 'package:video_player_app/widgets/responsive_icon_button.dart';

const _light = 'HapticFeedbackType.lightImpact';
const _selection = 'HapticFeedbackType.selectionClick';

final _android = TargetPlatformVariant.only(TargetPlatform.android);
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final feedback = <Object?>[];
  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
    feedback.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget host(Widget child) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: Center(child: child)),
  );

  group('媒体库顶栏', () {
    testWidgets('紧凑图标按钮每次点击只震一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          MediaLibraryCompactIconButton(
            key: const ValueKey('search'),
            icon: Icons.search_rounded,
            tooltip: '搜索',
            onPressed: () => taps++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('search')));
      await tester.pump();

      expect(taps, 1);
      expect(feedback, <Object?>[_light]);
    }, variant: _android);

    testWidgets('更多按钮打开与选择各震一次且不重复', (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        host(
          MediaLibraryCompactMoreButton(
            itemBuilder: (_) => [
              mediaLibraryCompactMenuItem(
                icon: Icons.settings,
                label: '媒体库设置',
                onSelected: () => selected.add('settings'),
              ),
              mediaLibraryCompactMenuItem(
                icon: Icons.delete_outline,
                label: '回收站',
                onSelected: () => selected.add('recycle'),
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(feedback, <Object?>[_light], reason: '打开菜单只震一次');

      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      expect(selected, <String>['recycle']);
      expect(feedback, <Object?>[_light, _selection], reason: '选择菜单项只震一次');
    }, variant: _android);

    testWidgets('宽屏图标按钮每次点击只震一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          ResponsiveIconButton(
            key: const ValueKey('wide-search'),
            icon: Icons.search_rounded,
            tooltip: '搜索',
            onPressed: () => taps++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('wide-search')));
      await tester.pump();

      expect(taps, 1);
      expect(feedback, <Object?>[_light]);
    }, variant: _android);
  });

  group('媒体库设置控件', () {
    testWidgets('设置行点击震一次', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          MediaLibrarySettingsRow(
            title: const Text('媒体库设置'),
            onTap: () => taps++,
          ),
        ),
      );

      await tester.tap(find.text('媒体库设置'));
      await tester.pump();

      expect(taps, 1);
      expect(feedback, <Object?>[_selection]);
    }, variant: _android);

    testWidgets('开关行：点开关与点整行各震一次，不叠加', (tester) async {
      final changes = <bool>[];
      var value = false;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => MediaLibrarySettingsSwitchTile(
              value: value,
              title: const Text('显示迷你播放卡片'),
              onChanged: (next) {
                changes.add(next);
                setState(() => value = next);
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(changes, <bool>[true]);
      expect(feedback, <Object?>[_selection], reason: '开关本体只震一次');

      await tester.tap(find.text('显示迷你播放卡片'));
      await tester.pump();
      expect(changes, <bool>[true, false]);
      expect(feedback, <Object?>[_selection, _selection], reason: '行点击只震一次');
    }, variant: _android);

    testWidgets('禁用的开关行保持不可交互且不震动', (tester) async {
      await tester.pumpWidget(
        host(
          const MediaLibrarySettingsSwitchTile(
            value: false,
            title: Text('避免重复弹出剪贴板提示'),
            onChanged: null,
          ),
        ),
      );

      await tester.tap(find.byType(Switch), warnIfMissed: false);
      await tester.tap(find.text('避免重复弹出剪贴板提示'), warnIfMissed: false);
      await tester.pump();

      expect(feedback, isEmpty);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.onChanged, isNull);
    }, variant: _android);

    testWidgets('下拉选项变化震一次', (tester) async {
      final changes = <int?>[];
      await tester.pumpWidget(
        host(
          MediaLibrarySettingsDropdown<int>(
            value: 0,
            items: const [
              DropdownMenuItem(value: 0, child: Text('文件夹')),
              DropdownMenuItem(value: 1, child: Text('继续观看')),
            ],
            onChanged: changes.add,
          ),
        ),
      );

      final dropdown = tester.widget<DropdownButton<int>>(
        find.byType(DropdownButton<int>),
      );
      dropdown.onChanged!(1);
      await tester.pump();

      expect(changes, <int?>[1]);
      expect(feedback, <Object?>[_selection]);
    }, variant: _android);
  });

  testWidgets('锚点菜单选择震一次并返回结果', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await MediaLibraryAnchorMenu.show(
                  context: context,
                  anchor: const Rect.fromLTWH(0, 0, 40, 40),
                  items: const [
                    MediaLibraryAnchorMenuEntry(
                      value: 'size',
                      label: '卡片大小',
                      icon: Icons.photo_size_select_large,
                    ),
                  ],
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(feedback, isEmpty, reason: '打开菜单不是菜单项选择');

    await tester.tap(find.text('卡片大小'));
    await tester.pumpAndSettle();

    expect(chosen, 'size');
    expect(feedback, <Object?>[_selection]);
  }, variant: _android);

  testWidgets('播放模式按钮切换模式且只震一次', (tester) async {
    final queue = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
    )..setPlaylist([
      VideoItem(
        id: '0',
        path: '/0.mp4',
        title: '0',
        durationMs: 60000,
        lastUpdated: 0,
      ),
    ]);
    addTearDown(queue.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<PlaylistManager>.value(
        value: queue,
        child: host(const PlaybackModeButton()),
      ),
    );

    final before = queue.playbackMode;
    await tester.tap(find.byType(PlaybackModeButton));
    await tester.pump();

    expect(queue.playbackMode, isNot(before));
    expect(feedback, <Object?>[_selection]);
  }, variant: _android);

  group('总开关与平台门禁', () {
    testWidgets('关闭震动开关后顶栏与设置行全部静默', (tester) async {
      await settings.saveEnableHapticFeedback(false);

      var taps = 0;
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MediaLibraryCompactIconButton(
                key: const ValueKey('search'),
                icon: Icons.search_rounded,
                tooltip: '搜索',
                onPressed: () => taps++,
              ),
              MediaLibrarySettingsRow(
                title: const Text('媒体库设置'),
                onTap: () => taps++,
              ),
              MediaLibrarySettingsSwitchTile(
                value: false,
                title: const Text('显示迷你播放卡片'),
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('search')));
      await tester.tap(find.text('媒体库设置'));
      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(taps, 2);
      expect(feedback, isEmpty);
    }, variant: _android);

    testWidgets('桌面平台不震动', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          MediaLibraryCompactIconButton(
            key: const ValueKey('search'),
            icon: Icons.search_rounded,
            tooltip: '搜索',
            onPressed: () => taps++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('search')));
      await tester.pump();

      expect(taps, 1);
      expect(feedback, isEmpty);
    }, variant: _windows);
  });
}
