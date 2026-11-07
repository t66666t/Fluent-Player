import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/keyboard_shortcut_hints.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

Future<void> _openMenu(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  EdgeInsets safeArea = const EdgeInsets.only(top: 24, bottom: 24),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => KeyboardShortcutHints(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: safeArea,
            viewPadding: safeArea,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => VideoActionButtons.showImportMenu(context, null),
            child: const Text('打开导入'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开导入'));
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(360, 640), Size(390, 844)]) {
    testWidgets(
      'local import and paired subtitle options remain reachable at $size',
      (tester) async {
        await _openMenu(tester, size: size);

        final scrollable = tester.state<ScrollableState>(
          find.byType(Scrollable),
        );
        expect(scrollable.position.maxScrollExtent, greaterThanOrEqualTo(0));
        expect(find.text('抖音下载'), findsNothing);
        expect(find.text('从网页发现音视频'), findsNothing);
        expect(find.text('网盘在线播放'), findsNothing);
        expect(find.textContaining('导入 Bilibili 链接'), findsNothing);

        final options = [
          '从相册导入',
          '从文件管理导入',
          '从文件管理导入压缩包',
          if (Theme.of(tester.element(find.byType(ListView))).platform !=
              TargetPlatform.iOS)
            '从文件管理导入文件夹',
          '从 FluentPack 文件导入',
          '批量导入',
        ];
        for (final label in options) {
          final tile = find.widgetWithText(ListTile, label);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tile.hitTestable(), findsOneWidget, reason: label);
          final rect = tester.getRect(tile);
          expect(rect.top, greaterThanOrEqualTo(24));
          expect(rect.bottom, lessThanOrEqualTo(size.height - 24));
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  for (final (size, textScale, safeArea) in const [
    (Size(320, 568), 1.0, EdgeInsets.only(top: 24, bottom: 24)),
    (Size(640, 360), 1.0, EdgeInsets.fromLTRB(44, 0, 44, 24)),
    (Size(390, 844), 1.8, EdgeInsets.only(top: 24, bottom: 24)),
  ]) {
    testWidgets(
      'constrained mobile menu stays reachable at $size and scale $textScale',
      (tester) async {
        await _openMenu(
          tester,
          size: size,
          textScale: textScale,
          safeArea: safeArea,
        );

        final viewport = tester.getRect(find.byType(ListView));
        expect(viewport.top, greaterThanOrEqualTo(safeArea.top));
        expect(
          viewport.bottom,
          lessThanOrEqualTo(size.height - safeArea.bottom),
        );
        expect(viewport.left, greaterThanOrEqualTo(safeArea.left));
        expect(viewport.right, lessThanOrEqualTo(size.width - safeArea.right));
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position
              .maxScrollExtent,
          greaterThanOrEqualTo(0),
        );
        for (final icon in [
          Icons.archive_outlined,
          Icons.create_new_folder_outlined,
          Icons.south_west_rounded,
          Icons.playlist_add,
        ]) {
          final tile = find.widgetWithIcon(ListTile, icon);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tile.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
