import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_parts_import_dialog.dart';

void main() {
  final info = BilibiliVideoInfo(
    title: '多分P视频标题' * 12,
    desc: '',
    pic: '',
    bvid: 'BVtest',
    aid: '1',
    ownerName: '',
    ownerMid: '',
    pubDate: 0,
    pages: [
      for (var i = 1; i <= 60; i++)
        BilibiliPage(cid: i, page: i, part: '课程 $i', duration: 125),
    ],
  );
  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('selector fits $size and returns every part beyond 50', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      List<int>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showBilibiliPartsImportDialog(
                    context,
                    info: info,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('导入所选 60 P'));
      await tester.pumpAndSettle();
      expect(result, List.generate(60, (i) => i + 1));
    });
  }
  testWidgets(
    'search preserves selection, empty selection disables import, cancel returns null',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: BilibiliPartsImportDialog(info: info)),
      );
      await tester.tap(find.text('取消全选'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '课程 60');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('import-part-60')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '不存在');
      await tester.pump();
      expect(find.text('已选 1 / 60 P'), findsOneWidget);
      expect(find.text('没有匹配的分P'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('phone keyboard leaves actions accessible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 340);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: BilibiliPartsImportDialog(info: info)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getBottomRight(find.byType(FilledButton)).dy, lessThan(504));
  });
}
