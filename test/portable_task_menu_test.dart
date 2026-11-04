import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_screen.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late Directory directory;
  late PathProviderPlatform previousPaths;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    library.resetLibraryForTesting();
    directory = await Directory.systemTemp.createTemp('portable-menu-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final stateDirectory = await Directory(
      '${directory.path}/portable_transfer',
    ).create();
    await File('${stateDirectory.path}/tasks_v1.json').writeAsString(
      jsonEncode({
        'tasks': [
          PortableTransferTask(
            id: 'completed-import',
            kind: PortableTransferKind.import,
            title: '已导入的课程',
            subtitle: '导入完成',
            createdAt: DateTime(2026),
            status: PortableTransferStatus.completed,
          ).toJson(),
        ],
      }),
    );
    await PortableTransferService.instance.initialize();
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    library.resetLibraryForTesting();
    settings.resetForTest();
    await directory.delete(recursive: true);
  });

  for (final size in [
    const Size(390, 844),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'task overflow stays at its button and selects actions at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<SettingsService>.value(value: settings),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              home: const PortableTransferScreen(
                initialTab: PortableTransferKind.import,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byTooltip('更多操作');
        final trigger = tester.getRect(
          find.ancestor(of: button, matching: find.byType(IconButton)),
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find.byKey(const ValueKey('capsule-choice-menu')),
        );
        expect(menu.top, closeTo(trigger.bottom + 6, .01));
        expect(menu.right, closeTo(trigger.right, .01));
        expect(menu.overlaps(trigger), isFalse);
        await tester.tap(find.text('进入批量管理'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('capsule-choice-menu')), findsNothing);
        expect(find.text('已选择 1 项'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
