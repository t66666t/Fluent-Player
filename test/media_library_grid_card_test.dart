import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';

void main() {
  testWidgets('网格卡片关闭默认白色水波纹和高亮', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: MediaLibraryGridCard(
            radius: 8,
            isSelected: false,
            onTap: () {},
            child: const SizedBox(width: 48, height: 64),
          ),
        ),
      ),
    );

    final inkWell = tester.widget<InkWell>(find.byType(InkWell));
    expect(inkWell.splashFactory, NoSplash.splashFactory);
    expect(inkWell.highlightColor, Colors.transparent);
    expect(inkWell.splashColor, Colors.transparent);

    final card = tester.widget<Card>(find.byType(Card));
    expect(card.margin, EdgeInsets.zero);
    expect(card.surfaceTintColor, Colors.transparent);
    expect(card.elevation, 0);
  });

  testWidgets('网格卡片右击走独立回调而不是左键点击', (tester) async {
    var taps = 0;
    var secondaryTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          body: MediaLibraryGridCard(
            radius: 8,
            isSelected: false,
            onTap: () => taps++,
            onSecondaryTap: () => secondaryTaps++,
            child: const SizedBox(width: 48, height: 64),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(InkWell)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(secondaryTaps, 1);
  });
}
