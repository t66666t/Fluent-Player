import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

void main() {
  testWidgets('task subtitle delete confirmation appears on the next frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showSubtitleDeletionConfirmationDialog(
                  context,
                  fileName: 'source.translated.zh-CN.srt',
                  isSidecar: false,
                  isExternal: false,
                );
              },
              child: const Text('删除任务字幕'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('删除任务字幕'));
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('删除字幕'), findsOneWidget);
    expect(find.text('确定要删除 source.translated.zh-CN.srt 吗？'), findsOneWidget);
    expect(find.textContaining('同时会删除'), findsNothing);
  });
}
