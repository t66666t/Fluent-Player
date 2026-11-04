import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_entry_reveal.dart';

void main() {
  testWidgets('folders enter in row order and revisits stay visible', (
    tester,
  ) async {
    final revealed = <int>{};
    Widget page({int directory = 0, bool motion = true, bool active = true}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: !motion),
            child: TickerMode(
              enabled: active,
              child: Column(
                children: [
                  for (var i = 0; i < 3; i++)
                    CloudDriveEntryReveal(
                      key: ValueKey('$directory/$i'),
                      index: i,
                      columns: 1,
                      revealed: revealed.contains(i),
                      onRevealed: () => revealed.add(i),
                      child: Text('文件夹$i'),
                    ),
                ],
              ),
            ),
          ),
        );
    double opacity(int index) => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byKey(ValueKey('0/$index')),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;
    await tester.pumpWidget(page());
    expect(opacity(0), 0);
    expect(opacity(2), 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(0), greaterThan(0));
    expect(opacity(2), 0);
    await tester.pumpAndSettle();
    expect(revealed, {0, 1, 2});
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    expect(opacity(2), 1);
    await tester.pumpWidget(page(directory: 1, motion: false));
    expect(
      tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byKey(const ValueKey('1/2')),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value,
      1,
    );
  });

  testWidgets('hidden pages wait until visible to start their entrance', (
    tester,
  ) async {
    var complete = false;
    Widget page(bool active) => MaterialApp(
      home: TickerMode(
        enabled: active,
        child: CloudDriveEntryReveal(
          index: 0,
          columns: 1,
          revealed: false,
          onRevealed: () => complete = true,
          child: const Text('文件夹'),
        ),
      ),
    );
    await tester.pumpWidget(page(false));
    await tester.pump(const Duration(seconds: 1));
    expect(complete, false);
    await tester.pumpWidget(page(true));
    expect(
      tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byType(CloudDriveEntryReveal),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value,
      0,
    );
    await tester.pumpAndSettle();
    expect(complete, true);
  });
}
