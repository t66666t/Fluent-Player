import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/import_location_settings_screen.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preview = Platform.environment['IMPORT_LOCATION_PREVIEW'] == '1';
  setUpAll(() async {
    if (preview) {
      await (FontLoader(
            'ImportLocationPreview',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final (width, height, scale) in <(double, double, double)>[
    (320, 740, 1),
    (390, 844, 1),
    (800, 1000, 1),
    (1280, 900, 1),
    (320, 740, 1.6),
  ]) {
    testWidgets('settings layout ${width.toInt()}px text $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const boundaryKey = ValueKey('import-layout-boundary');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: preview ? 'ImportLocationPreview' : null,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ImportLocationSettingsScreen(settings: settings),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (width >= 1050) {
        expect(
          find.byKey(const ValueKey('import-preview-result')),
          findsOneWidget,
        );
      }
      if (preview && scale == 1) {
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/import-location/settings-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final group = find.byKey(
        const PageStorageKey('import-location-group-bilibili'),
      );
      await tester.ensureVisible(group);
      await tester.tap(group);
      await tester.pumpAndSettle();
      final onlineRule = find.byKey(
        const ValueKey('import-rule-bilibiliOnline-inherit'),
      );
      await tester.ensureVisible(onlineRule);
      await tester.pumpAndSettle();
      expect(onlineRule, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.resetForTest();
    });
  }
}
