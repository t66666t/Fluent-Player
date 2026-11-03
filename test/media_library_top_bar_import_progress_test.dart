import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/media_library_top_bar_import_progress.dart';

void main() {
  testWidgets('顶栏导入进度覆盖在 AppBar 底边且不改变布局', (tester) async {
    final library = LibraryService();

    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('我的媒体库'),
              bottom: const MediaLibraryTopBarImportProgress(),
            ),
            body: const ColoredBox(
              key: ValueKey('library-body'),
              color: Colors.black,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    final appBarSize = tester.getSize(find.byType(AppBar));
    final bodyTop = tester.getTopLeft(
      find.byKey(const ValueKey('library-body')),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);

    library.importProgress.value = 0.42;
    await tester.pump();

    expect(
      find.byKey(const ValueKey('media-library-top-bar-import-progress')),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(AppBar)), appBarSize);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('library-body'))),
      bodyTop,
    );

    library.importProgress.value = 0.0;
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(AppBar)), appBarSize);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('library-body'))),
      bodyTop,
    );

    library.importProgress.value = 1.0;
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
