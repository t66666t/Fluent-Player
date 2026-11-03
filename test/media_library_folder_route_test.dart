import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('进入文件夹使用轻量层级转场，返回后回到上一页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    buildMediaLibraryFolderRoute<void>(
                      builder: (_) => const Scaffold(
                        body: Text('folder-page', key: Key('folder-page')),
                      ),
                    ),
                  );
                },
                child: const Text('open-folder'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open-folder'));
    await tester.pump();

    final folder = find.byKey(const Key('folder-page'), skipOffstage: false);
    final route = ModalRoute.of(tester.element(folder))!;
    expect(route, isA<MediaLibraryFolderRoute<void>>());
    expect(route.transitionDuration, const Duration(milliseconds: 260));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 200));
    // Other, full-page routes may still use a snapshot of this folder. The
    // folder-to-folder transition itself keeps both levels live and still.
    expect((route as PageRoute).allowSnapshotting, isTrue);
    expect(route.animation!.status, AnimationStatus.forward);
    expect(route.animation!.value, 0);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(route.animation!.value, greaterThan(0.2));
    expect(route.animation!.value, lessThan(0.9));

    await tester.pump(const Duration(milliseconds: 400));
    expect(route.animation!.status, AnimationStatus.completed);
    expect(route.animation!.value, 1);

    Navigator.of(tester.element(folder)).pop();
    await tester.pump();
    expect(route.animation!.status, isNot(AnimationStatus.dismissed));
    expect(route.animation!.value, 1);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(route.animation!.value, lessThan(0.85));
    expect(route.animation!.value, greaterThan(0.05));

    await tester.pump(const Duration(milliseconds: 400));
    expect(folder, findsNothing);
    expect(find.text('open-folder'), findsOneWidget);
  });

  testWidgets('恢复上次文件夹时第一帧就在该页，不播放进入动画', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    buildMediaLibraryFolderRoute<void>(
                      folderId: 'nested',
                      restored: true,
                      builder: (_) => const Scaffold(
                        body: Text('restored-folder', key: Key('restored')),
                      ),
                    ),
                  );
                },
                child: const Text('home'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('home'));
    await tester.pump();

    final restored = find.byKey(const Key('restored'));
    final route = ModalRoute.of(tester.element(restored))!;
    expect(route.animation!.status, AnimationStatus.completed);
    expect(route.animation!.value, 1);
    expect(find.text('restored-folder'), findsOneWidget);
    expect(find.text('home'), findsNothing);
  });

  testWidgets('面包屑跳到上层文件夹时直接落到目标，不先露出首页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );

    void open(String id) {
      final nav = Navigator.of(
        tester.element(find.text(id == 'A' ? 'home' : _previous(id))),
      );
      nav.push(
        buildMediaLibraryFolderRoute<void>(
          folderId: id,
          builder: (_) => Scaffold(body: Text(id)),
        ),
      );
    }

    open('A');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    open('B');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    open('C');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('C'), findsOneWidget);

    final found = popMediaLibraryToFolder(
      Navigator.of(tester.element(find.text('C'))),
      folderId: 'A',
    );
    expect(found, isTrue);
    await tester.pump();

    expect(find.text('A'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(find.text('B'), findsNothing);
    expect(find.text('C'), findsNothing);
  });

  testWidgets('面包屑回到媒体库时直接落在首页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );

    Navigator.of(tester.element(find.text('home'))).push(
      buildMediaLibraryFolderRoute<void>(
        folderId: 'A',
        builder: (_) => const Scaffold(body: Text('A')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.text('A'))).push(
      buildMediaLibraryFolderRoute<void>(
        folderId: 'B',
        builder: (_) => const Scaffold(body: Text('B')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    popMediaLibraryToFolder(Navigator.of(tester.element(find.text('B'))));
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);
  });
}

String _previous(String id) {
  switch (id) {
    case 'B':
      return 'A';
    case 'C':
      return 'B';
    default:
      return 'home';
  }
}
