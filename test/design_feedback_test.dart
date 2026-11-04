import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';
import 'package:video_player_app/widgets/categorized_settings_page.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/operation_status.dart';
import 'package:video_player_app/widgets/system_media_notification_setting.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    ExperimentalLayout.instance.value = false;
  });

  Future<void> settingsHost(
    WidgetTester tester, {
    double scale = 1,
    Key? capture,
  }) async {
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: 'Noto Sans SC',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showMediaLibrarySettingsBottomSheet(context, settings),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 568),
    const Size(768, 1024),
    const Size(844, 390),
    const Size(1440, 900),
  ]) {
    testWidgets('flat settings remain reachable at $size with large text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await settingsHost(tester, scale: 2);
      expect(find.byType(CategorizedSettingsPage), findsOneWidget);
      expect(ExperimentalLayout.instance.value, isFalse);
      expect(find.byType(TextField), findsNothing);
      final history = find.byKey(const ValueKey('clearPlaybackHistory'));
      await tester.ensureVisible(history);
      await tester.pumpAndSettle();
      expect(history.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'operation failure has readable persistent details without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: const SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: OperationStatus(
                    title: '部分文件未能清理',
                    message: '失败的条目已保留，请检查文件权限后重试。',
                    kind: OperationStatusKind.error,
                    details:
                        'Authorization: Bearer secret-token\nhttps://example.test/?token=secret-token',
                    actions: [
                      TextButton(onPressed: null, child: Text('重试失败项')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('secret-token'), findsNothing);
      expect(find.text('部分文件未能清理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary notification rejection does not disable media; channel block does',
    (tester) async {
      final settings = SettingsService();
      await settings.init();
      SystemMediaNotificationGate.debugTargetPlatform = TargetPlatform.android;
      var blocked = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemMediaNotificationGate.channel,
        (call) async => {
          'channelBlocked': blocked,
          'ordinaryNotificationsAllowed': false,
        },
      );
      addTearDown(() {
        SystemMediaNotificationGate.debugTargetPlatform = null;
        messenger.setMockMethodCallHandler(
          SystemMediaNotificationGate.channel,
          null,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SystemMediaNotificationSetting(settings: settings),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('showSystemMediaNotification')),
            )
            .onChanged,
        isNotNull,
      );
      blocked = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('showSystemMediaNotification')),
            )
            .onChanged,
        isNull,
      );
      expect(find.text('媒体播放通知已被系统关闭'), findsOneWidget);
      expect(settings.showSystemMediaNotification, isTrue);
      blocked = false;
      await tester.tap(find.text('重新检查'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('showSystemMediaNotification')),
            )
            .onChanged,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'render settings and operation feedback previews',
    (tester) async {
      await tester.runAsync(() async {
        await (FontLoader('Noto Sans SC')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      for (final sample in <String, Size>{
        'settings-phone': const Size(390, 844),
        'settings-tablet-portrait': const Size(768, 1024),
        'settings-tablet-landscape': const Size(1280, 800),
        'settings-landscape': const Size(844, 390),
        'settings-desktop': const Size(1440, 900),
      }.entries) {
        tester.view.physicalSize = sample.value;
        tester.view.devicePixelRatio = 1;
        final capture = GlobalKey();
        await settingsHost(tester, capture: capture);
        if (sample.key == 'settings-desktop') {
          final restore = find.byKey(
            const ValueKey('mediaLibraryRestoreLastPage'),
          );
          await tester.ensureVisible(restore);
          await tester.tap(restore);
        }
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final pixels = await boundary.toImage();
          final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
            'build/design-feedback-previews/${sample.key}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
          pixels.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.reset();
    },
    skip: !const bool.fromEnvironment('DESIGN_FEEDBACK_PREVIEWS'),
  );
}
