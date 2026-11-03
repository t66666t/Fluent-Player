import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/portable_transfer/portable_selection_page.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  testWidgets('export picker can expand a folder and select a nested card', (
    tester,
  ) async {
    final library = LibraryService();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    addTearDown(library.resetPersistenceForTesting);

    final course = await library.createCollection('选择器课程-可见性', null);
    await library.createCollection('选择器第一课-可见性', course.id);
    final nested = await library.createCollection('选择器深层文件夹-可见性', course.id);
    await library.createCollection('选择器更深层-可见性', nested.id);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PortableSelectionPage(library: library),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('选择器课程-可见性'), findsOneWidget);
    expect(find.text('选择器第一课-可见性'), findsNothing);
    expect(find.text('选择器更深层-可见性'), findsNothing);

    await tester.tap(find.text('选择器课程-可见性'));
    await tester.pumpAndSettle();
    expect(find.text('选择器第一课-可见性'), findsOneWidget);
    expect(find.text('选择器深层文件夹-可见性'), findsOneWidget);
    expect(find.text('选择器更深层-可见性'), findsNothing);

    await tester.tap(find.text('选择器深层文件夹-可见性'));
    await tester.pumpAndSettle();
    expect(find.text('选择器更深层-可见性'), findsOneWidget);

    final nestedRow = find.ancestor(
      of: find.text('选择器更深层-可见性'),
      matching: find.byType(InkWell),
    );
    await tester.tap(
      find.descendant(of: nestedRow, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsWidgets);
  });
}
