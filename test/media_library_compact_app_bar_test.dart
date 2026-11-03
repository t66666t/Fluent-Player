import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';

void main() {
  testWidgets('手机顶栏使用紧凑标题、按钮宽度和标题间距', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            toolbarHeight: 50,
            leadingWidth: 40,
            titleSpacing: 3,
            leading: MediaLibraryCompactIconButton(
              key: const ValueKey('leading'),
              icon: Icons.arrow_back,
              tooltip: '返回',
              onPressed: () {},
            ),
            title: const MediaLibraryCompactTitle(
              key: ValueKey('title'),
              text: '这是一个比较长的文件夹名称',
            ),
            actions: [
              MediaLibraryCompactIconButton(
                key: const ValueKey('search'),
                icon: Icons.search_rounded,
                tooltip: '搜索',
                onPressed: () {},
              ),
              MediaLibraryCompactIconButton(
                key: const ValueKey('recycle'),
                icon: Icons.delete_outline,
                tooltip: '回收站',
                onPressed: () {},
              ),
              SizedBox(
                key: const ValueKey('more'),
                width: 40,
                height: 48,
                child: MediaLibraryCompactMoreButton(
                  itemBuilder: (_) => [
                    mediaLibraryCompactMenuItem(
                      icon: Icons.tune,
                      label: '调整卡片样式',
                      onSelected: () {},
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
            ],
          ),
        ),
      ),
    );

    final leadingRect = tester.getRect(find.byKey(const ValueKey('leading')));
    final titleRect = tester.getRect(find.byKey(const ValueKey('title')));
    final searchRect = tester.getRect(find.byKey(const ValueKey('search')));
    final recycleRect = tester.getRect(find.byKey(const ValueKey('recycle')));

    expect(leadingRect.width, 40);
    expect(searchRect.width, 40);
    expect(recycleRect.width, 40);
    expect(titleRect.left - leadingRect.right, closeTo(3, 0.01));
    final titleText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('title')),
        matching: find.byType(Text),
      ),
    );
    final titleTransform = tester.widget<Transform>(
      find.descendant(
        of: find.byKey(const ValueKey('title')),
        matching: find.byType(Transform),
      ),
    );
    expect(titleText.style?.fontSize, 16);
    expect(titleText.style?.fontWeight, FontWeight.w500);
    expect(
      titleTransform.transform.getTranslation().y,
      mediaLibraryCompactTitleOpticalOffset,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多菜单保持紧凑并承载低频操作', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              SizedBox(
                width: 40,
                height: 48,
                child: MediaLibraryCompactMoreButton(
                  itemBuilder: (_) => [
                    mediaLibraryCompactMenuItem(
                      icon: Icons.tune,
                      label: '调整卡片样式',
                      onSelected: () {},
                    ),
                    mediaLibraryCompactMenuItem(
                      icon: Icons.settings_outlined,
                      label: '媒体库设置',
                      onSelected: () {},
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('调整卡片样式'), findsOneWidget);
    expect(find.text('媒体库设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
