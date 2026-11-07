import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const files = MethodChannel('com.example.video_player_app/file_manager');
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  final permissionCalls = <MethodCall>[];
  final fileCalls = <MethodCall>[];
  final photoCalls = <MethodCall>[];

  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => VideoActionButtons.showImportMenu(context, null),
              child: const Text('导入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    SettingsService().resetForTest();
    permissionCalls.clear();
    fileCalls.clear();
    photoCalls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async {
      permissionCalls.add(call);
      if (call.method == 'requestPermissions') {
        return <int, int>{
          for (final permission in call.arguments as List<dynamic>)
            permission as int: 0,
        };
      }
      return 0;
    });
    messenger.setMockMethodCallHandler(files, (call) async {
      fileCalls.add(call);
      return call.method == 'pickFiles' ? <String>[] : null;
    });
    messenger.setMockMethodCallHandler(photos, (call) async {
      photoCalls.add(call);
      if (call.method == 'requestPermissionExtend' ||
          call.method == 'getPermissionState') {
        return PermissionState.denied.index;
      }
      return null;
    });
  });

  tearDown(() async {
    await AppToast.dismiss(immediate: true);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [permissions, files, photos]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final entry in <IconData, String>{
    Icons.folder_open: 'pickFiles',
    Icons.archive_outlined: 'pickArchive',
  }.entries) {
    testWidgets(
      '${entry.value} opens SAF when all broad storage permissions are denied',
      (tester) async {
        await openMenu(tester);
        await tester.scrollUntilVisible(
          find.widgetWithIcon(ListTile, entry.key),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithIcon(ListTile, entry.key).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithIcon(ListTile, entry.key));
        await tester.pumpAndSettle();
        await AppToast.dismiss(immediate: true);
        await tester.pump();
        expect(fileCalls.map((call) => call.method), [entry.value]);
        if (entry.value == 'pickFiles') {
          expect(
            (fileCalls.single.arguments as Map)['filterMediaExtensions'],
            isTrue,
          );
        }
        expect(permissionCalls, isEmpty);
        expect(photoCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'disabled suffix filter opens Android picker for all document types',
    (tester) async {
      SettingsService().localImportFilterMediaExtensions = false;
      await openMenu(tester);
      await tester.scrollUntilVisible(
        find.widgetWithIcon(ListTile, Icons.folder_open),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.widgetWithIcon(ListTile, Icons.folder_open));
      await tester.pumpAndSettle();
      expect(fileCalls.single.method, 'pickFiles');
      expect((fileCalls.single.arguments as Map)['mimeTypes'], ['*/*']);
      expect(
        (fileCalls.single.arguments as Map)['filterMediaExtensions'],
        isFalse,
      );
      expect(permissionCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'gallery requests videos and audio without requiring photos',
    (tester) async {
      await openMenu(tester);
      await tester.tap(find.widgetWithIcon(ListTile, Icons.photo_library));
      await tester.pumpAndSettle();
      await AppToast.dismiss(immediate: true);
      await tester.pump();
      final requests = photoCalls.where(
        (call) => call.method == 'requestPermissionExtend',
      );
      expect(requests, isNotEmpty);
      final options = requests.first.arguments as Map<dynamic, dynamic>;
      final android = options['androidPermission'] as Map<dynamic, dynamic>;
      expect(android['type'], (RequestType.video | RequestType.audio).value);
      expect(android['mediaLocation'], isFalse);
      expect(permissionCalls, isEmpty);
      expect(fileCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
