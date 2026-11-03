import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/folder_placeholder_style.dart';
import 'package:video_player_app/widgets/folder_placeholder_cover.dart';

void main() {
  Future<void> pumpCover(
    WidgetTester tester, {
    required FolderPlaceholderSettings settings,
    String folderId = 'folder-a',
    String folderName = '日剧',
    String? coverLabel,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 90,
              child: FolderPlaceholderCover(
                folderId: folderId,
                folderName: folderName,
                coverLabel: coverLabel,
                settings: settings,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('色块大字能找到对应文字和角标', (tester) async {
    await pumpCover(
      tester,
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.letterBlock,
        showCoverText: true,
      ),
    );

    expect(find.text('日剧'), findsOneWidget);
    expect(
      find.byKey(FolderPlaceholderCover.glyphKeyFor('folder-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(FolderPlaceholderCover.cornerBadgeKeyFor('folder-a')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
  });

  testWidgets('染色图标能找到文件夹图标和字母徽章', (tester) async {
    await pumpCover(
      tester,
      folderName: 'Movies',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.tintedIcon,
        showCoverText: true,
      ),
    );

    expect(find.text('Mo'), findsOneWidget);
    expect(
      find.byKey(FolderPlaceholderCover.folderIconKeyFor('folder-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(FolderPlaceholderCover.letterBadgeKeyFor('folder-a')),
      findsOneWidget,
    );
    final badge = tester.getSize(
      find.byKey(FolderPlaceholderCover.letterBadgeKeyFor('folder-a')),
    );
    expect(
      badge.width,
      closeTo(90 * FolderPlaceholderLook.letterBadgeDesignedDiameter, 1.5),
    );
    final glyph = tester.widget<Text>(
      find.byKey(FolderPlaceholderCover.glyphKeyFor('folder-a')),
    );
    expect(
      glyph.style!.fontSize,
      closeTo(
        90 *
            FolderPlaceholderLook.letterBadgeDesignedDiameter *
            FolderPlaceholderLook.letterBadgeGlyphFill(2) *
            FolderPlaceholderLook.glyphScriptScale('Mo'),
        0.8,
      ),
    );
  });

  testWidgets('徽章文字大小相对徽章缩放，不带动徽章直径', (tester) async {
    await pumpCover(
      tester,
      folderName: 'Movies',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.tintedIcon,
        showCoverText: true,
        letterBadgeGlyphScale: 2.0,
      ),
    );

    final badge = tester.getSize(
      find.byKey(FolderPlaceholderCover.letterBadgeKeyFor('folder-a')),
    );
    expect(
      badge.width,
      closeTo(90 * FolderPlaceholderLook.letterBadgeDesignedDiameter, 1.5),
    );
    final glyph = tester.widget<Text>(
      find.byKey(FolderPlaceholderCover.glyphKeyFor('folder-a')),
    );
    expect(
      glyph.style!.fontSize,
      closeTo(
        90 *
            FolderPlaceholderLook.letterBadgeDesignedDiameter *
            FolderPlaceholderLook.letterBadgeGlyphFill(2) *
            FolderPlaceholderLook.glyphScriptScale('Mo') *
            2.0,
        0.8,
      ),
    );
  });

  testWidgets('渐变剪影能找到大字和文件夹剪影', (tester) async {
    await pumpCover(
      tester,
      folderName: '2024',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.gradientGhost,
        showCoverText: true,
      ),
    );

    expect(find.text('20'), findsOneWidget);
    expect(
      find.byKey(FolderPlaceholderCover.silhouetteKeyFor('folder-a')),
      findsOneWidget,
    );
    final icon = tester.widget<Icon>(
      find.byKey(FolderPlaceholderCover.silhouetteKeyFor('folder-a')),
    );
    expect(
      icon.size,
      closeTo(90 * FolderPlaceholderSettings.defaults.silhouetteScale, 0.01),
    );
  });

  testWidgets('渐变剪影的文字落在文件夹口袋视觉中心，剪影仍对封面居中', (tester) async {
    await pumpCover(
      tester,
      folderName: '数',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.gradientGhost,
        showCoverText: true,
      ),
    );

    final cover = tester.getRect(
      find.byKey(FolderPlaceholderCover.coverKeyFor('folder-a')),
    );
    final glyphBox = tester.getRect(
      find.byKey(FolderPlaceholderCover.glyphBoxKeyFor('folder-a')),
    );
    final silhouetteBox = tester.getRect(
      find.byKey(FolderPlaceholderCover.silhouetteBoxKeyFor('folder-a')),
    );
    expect(silhouetteBox.center.dx, closeTo(cover.center.dx, 0.5));
    expect(silhouetteBox.center.dy, closeTo(cover.center.dy, 0.5));
    final nudge = FolderPlaceholderLook.gradientGhostGlyphNudge(
      90 * FolderPlaceholderSettings.defaults.silhouetteScale,
    );
    expect(glyphBox.center.dx, closeTo(silhouetteBox.center.dx + nudge.dx, 0.8));
    expect(glyphBox.center.dy, closeTo(silhouetteBox.center.dy + nudge.dy, 0.8));
    expect(glyphBox.center.dy, greaterThan(silhouetteBox.center.dy));
  });

  testWidgets('染色图标的文件夹与封面同重心', (tester) async {
    await pumpCover(
      tester,
      folderName: 'Movies',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        paintStyle: FolderPlaceholderPaintStyle.tintedIcon,
        showCoverText: true,
      ),
    );

    final cover = tester.getRect(
      find.byKey(FolderPlaceholderCover.coverKeyFor('folder-a')),
    );
    final folderBox = tester.getRect(
      find.byKey(FolderPlaceholderCover.folderIconBoxKeyFor('folder-a')),
    );
    expect(folderBox.center.dx, closeTo(cover.center.dx, 0.5));
    expect(folderBox.center.dy, closeTo(cover.center.dy, 0.5));
  });

  testWidgets('关闭封面文字后不再绘制字形', (tester) async {
    await pumpCover(
      tester,
      folderName: '数学',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        showCoverText: false,
      ),
    );

    expect(find.text('数学'), findsNothing);
    expect(
      find.byKey(FolderPlaceholderCover.glyphKeyFor('folder-a')),
      findsNothing,
    );
    expect(
      find.byKey(FolderPlaceholderCover.silhouetteKeyFor('folder-a')),
      findsOneWidget,
    );
  });

  testWidgets('自定义封面文字覆盖自动提取', (tester) async {
    await pumpCover(
      tester,
      folderName: '《三国演义》',
      coverLabel: '演义',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        showCoverText: true,
      ),
    );

    expect(find.text('演义'), findsOneWidget);
    expect(find.text('三国'), findsNothing);
    expect(find.text('《'), findsNothing);
  });

  testWidgets('文字上限为 4 时封面显示四个汉字', (tester) async {
    await pumpCover(
      tester,
      folderName: '《三国演义》',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        maxCoverTextLength: 4,
        showCoverText: true,
      ),
    );

    expect(find.text('三国演义'), findsOneWidget);
    expect(find.text('三国'), findsNothing);
  });

  testWidgets('剪影可以超过封面短边', (tester) async {
    await pumpCover(
      tester,
      folderName: '数',
      settings: FolderPlaceholderSettings.defaults.copyWith(
        showCoverText: false,
        silhouetteScale: FolderPlaceholderSettings.silhouetteScaleMax,
      ),
    );

    final icon = tester.widget<Icon>(
      find.byKey(FolderPlaceholderCover.silhouetteKeyFor('folder-a')),
    );
    expect(
      icon.size,
      closeTo(90 * FolderPlaceholderSettings.silhouetteScaleMax, 0.5),
    );
    final scale = tester.widget<Transform>(
      find.descendant(
        of: find.byKey(FolderPlaceholderCover.coverKeyFor('folder-a')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Transform &&
              widget.transform[0] > 1.5 &&
              widget.transform[5] > 1.5,
        ),
      ),
    );
    expect(scale.transform[0], closeTo(FolderPlaceholderSettings.silhouetteScaleMax, 0.05));
  });
}
