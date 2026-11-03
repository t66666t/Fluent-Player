import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_format_page.dart';
import 'package:video_player_app/features/portable_transfer/portable_selection_page.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_screen.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/recycle_bin_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/utils/app_toast.dart';

class _Sizes extends ChangeNotifier implements LibraryService {
  final cached = <String, int>{};
  final disk = <String, int>{};
  final calculations = <String>[];

  @override
  int? getCachedItemSize(dynamic item) => cached[item.id];

  @override
  Future<int> calculateItemSize(dynamic item) async {
    calculations.add(item.id as String);
    return cached[item.id as String] = disk[item.id] ?? 4096;
  }

  void invalidate(String id, int bytes) {
    disk[id] = bytes;
    cached.remove(id);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

VideoItem _item(String id) => VideoItem(
  id: id,
  path: '/fixture/$id.mp4',
  title: id,
  durationMs: 1000,
  lastUpdated: 0,
);

Future<GlobalKey<NavigatorState>> _host(WidgetTester tester) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
      home: const Scaffold(body: Text('home')),
    ),
  );
  return key;
}

void main() {
  testWidgets(
    'submitted drop imports keep their first-frame inspection and owned-file cleanup',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final library = LibraryService()..resetLibraryForTesting();
      final previousPaths = PathProviderPlatform.instance;
      late Directory root;
      late File package;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('feature_import_');
        PathProviderPlatform.instance = _Paths(root.path);
        await PortableTransferService.instance.initialize(library: library);
        package = await File(
          '${root.path}/invalid.fluentpack',
        ).writeAsBytes([0, 1, 2]);
      });
      addTearDown(() async {
        await AppToast.dismiss(immediate: true);
        await tester.pumpWidget(const SizedBox());
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = previousPaths;
        if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
            root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('feature_import_')) {
          await root.delete(recursive: true);
        }
      });
      final navigator = AppToast.navigatorKey;
      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: library,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
            home: const Scaffold(body: Text('home')),
          ),
        ),
      );
      final route = AppMaterialPageRoute<void>(
        builder: (_) => PortableTransferScreen(
          initialTab: PortableTransferKind.import,
          pendingImportSources: [
            PortableImportSource.fromPath(
              package.path,
              ownedTemporaryCopy: true,
            ),
          ],
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      var cleaned = false;
      final wait = Stopwatch()..start();
      while (!cleaned && wait.elapsed < const Duration(seconds: 2)) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          cleaned = !await package.exists();
        });
        // Flush isolate/file continuations without advancing animation time.
        await tester.pump();
      }
      expect(route.animation!.status, AnimationStatus.forward);
      expect(
        cleaned,
        isTrue,
        reason: 'explicit import validation must run before entry finishes',
      );
      await AppToast.dismiss(immediate: true);
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an explicit export during entry supersedes the delayed launch UI',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final library = LibraryService()..resetLibraryForTesting();
      final previousPaths = PathProviderPlatform.instance;
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('feature_launch_');
        PathProviderPlatform.instance = _Paths(root.path);
        await PortableTransferService.instance.initialize(library: library);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = previousPaths;
        if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
            root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('feature_launch_')) {
          await root.delete(recursive: true);
        }
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: library,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
            home: const Scaffold(body: Text('home')),
          ),
        ),
      );
      navigator.currentState!.push(
        AppMaterialPageRoute<void>(
          builder: (_) => const PortableTransferScreen(
            pendingExportRootIds: ['old-intent'],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('新建导出 (N)'));
      await tester.pumpAndSettle();
      expect(find.byType(PortableSelectionPage), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(PortableTransferScreen), findsOneWidget);
      expect(find.byType(PortableExportFormatPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recycle sizes stay cached or use the original accounting after entry',
    (tester) async {
      final sizes = _Sizes()..cached['cached'] = 1024;
      addTearDown(sizes.dispose);
      final navigator = await _host(tester);
      final route = AppMaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Column(
            children: [
              SizeDisplay(item: _item('cached'), library: sizes),
              SizeDisplay(item: _item('uncached'), library: sizes),
            ],
          ),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.textContaining(LibraryService.formatSize(1024)),
        findsOneWidget,
      );
      expect(sizes.calculations, isEmpty);
      await tester.pumpAndSettle();
      expect(sizes.calculations, ['uncached']);
      expect(
        find.textContaining(LibraryService.formatSize(4096)),
        findsOneWidget,
      );

      // Online caches and sidecars can change while the bin is open. Their
      // invalidation must still replace the old number with a fresh calculation.
      sizes.invalidate('cached', 8192);
      await tester.pumpAndSettle();
      expect(sizes.calculations, ['uncached', 'cached']);
      expect(
        find.textContaining(LibraryService.formatSize(8192)),
        findsOneWidget,
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('leaving before entry settles abandons unneeded size scans', (
    tester,
  ) async {
    final sizes = _Sizes();
    addTearDown(sizes.dispose);
    final navigator = await _host(tester);
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: SizeDisplay(item: _item('unused'), library: sizes),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(sizes.calculations, isEmpty);
    expect(find.text('home'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
