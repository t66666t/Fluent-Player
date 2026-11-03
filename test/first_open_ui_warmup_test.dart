import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/first_open_ui_warmup.dart';

void main() {
  testWidgets('warmup surface builds Material dialog chrome without focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FirstOpenWarmupSurface())),
    );

    expect(find.byKey(kFirstOpenUiWarmupSurfaceKey), findsOneWidget);
    expect(find.text('搜索媒体库'), findsOneWidget);
    expect(find.text('媒体库设置'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('disabled host never inserts the capture overlay', (
    tester,
  ) async {
    await tester.pumpWidget(
      FirstOpenUiWarmupHost(
        enabled: false,
        startDelay: Duration.zero,
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: const Text('home'),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(kFirstOpenUiWarmupSurfaceKey), findsNothing);
  });

  testWidgets('enabled host captures then removes the overlay', (tester) async {
    await tester.pumpWidget(
      FirstOpenUiWarmupHost(
        enabled: true,
        startDelay: Duration.zero,
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: const Text('home'),
        ),
      ),
    );

    var sawWarmup = false;
    for (var i = 0; i < 10; i++) {
      await tester.pump();
      if (find.byKey(kFirstOpenUiWarmupSurfaceKey).evaluate().isNotEmpty) {
        sawWarmup = true;
        break;
      }
    }
    expect(sawWarmup, isTrue);
    expect(find.text('home'), findsOneWidget);
    expect(tester.getSize(find.byKey(kFirstOpenUiWarmupClipSlotKey)), Size.zero);

    await tester.pump(const Duration(milliseconds: 48));
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(kFirstOpenUiWarmupSurfaceKey), findsNothing);
  });
}
