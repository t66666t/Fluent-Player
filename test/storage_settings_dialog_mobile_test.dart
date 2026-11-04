import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/widgets/storage_settings_dialog.dart';

void main() {
  for (final platform in [StoragePlatform.android, StoragePlatform.ios]) {
    testWidgets(
      '$platform storage is explained without unsupported migration actions',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('storage-mobile-ui-');
        final previous = AppStorageService.instance;
        await tester.runAsync(() async {
          final service = AppStorageService(
            locations: () async => StorageLocations(
              platform: platform,
              support: Directory('${root.path}/support'),
              documents: Directory('${root.path}/documents'),
              defaultData: Directory('${root.path}/data'),
              executable: root,
            ),
          );
          AppStorageService.instance = service;
          await service.initialize();
        });
        addTearDown(() {
          AppStorageService.instance = previous;
          root.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAppStorageSettingsDialog(context),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.textContaining('存储位置由系统管理'), findsOneWidget);
        expect(find.text('整理旧文件'), findsNothing);
        expect(find.text('选择目录'), findsNothing);
        expect(find.text('重启并重新加载'), findsNothing);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }
}
