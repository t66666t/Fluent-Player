import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/douyin_download/douyin_download_screen.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/playback_page_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every platform uses the live composited page transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        home: const Scaffold(body: Text('home')),
      ),
    );
    final builders = Theme.of(
      tester.element(find.text('home')),
    ).pageTransitionsTheme.builders;
    for (final platform in TargetPlatform.values) {
      expect(
        builders[platform],
        isA<AppPageTransitionsBuilder>(),
        reason: platform.name,
      );
      expect(
        builders[platform]!.transitionDuration,
        const Duration(milliseconds: 260),
      );
      expect(
        builders[platform]!.reverseTransitionDuration,
        const Duration(milliseconds: 200),
      );
    }
  });

  testWidgets('a plain material push uses the shared transition and settles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.iOS,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(
                        body: Text('next-page', key: Key('next-page')),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    final next = find.byKey(const Key('next-page'), skipOffstage: false);
    final route = ModalRoute.of(tester.element(next))!;
    expect(route.transitionDuration, const Duration(milliseconds: 260));
    expect(route.animation!.status, AnimationStatus.forward);

    await tester.pump(const Duration(milliseconds: 400));
    expect(route.animation!.status, AnimationStatus.completed);
    expect(find.text('next-page'), findsOneWidget);
  });

  test('playback uses its own live transition and immediate video clock', () {
    final route = PlaybackNavigationService.buildPlaybackPageRoute<void>(
      builder: (_) => const SizedBox(),
    );
    expect(route.allowSnapshotting, isFalse);
    expect(route, isA<PlaybackPageRoute<void>>());
    expect(route.transitionDuration, const Duration(milliseconds: 260));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 200));
    expect(route.delayPushOneFrame, isFalse);

    final folder = AppMaterialPageRoute<void>(builder: (_) => const SizedBox());
    expect(folder.allowSnapshotting, isTrue);
    expect(folder.delayPushOneFrame, isFalse);
  });

  test('douyin page keeps the live browser during its transition', () {
    final route = DouyinDownloadRoute();
    expect(route.allowSnapshotting, isFalse);
    expect(route.settings.name, '/douyin_download');
  });
}
