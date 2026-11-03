import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';

class _LoginApi extends BilibiliApiService {
  @override
  Future<bool> hasCookie() async => false;

  @override
  Future<Map<String, String>> generateQrCode() async => {
    'url': 'https://example.com/login',
    'qrcode_key': 'test-key',
  };

  @override
  Future<Map<String, dynamic>> pollQrCode(String qrcodeKey) async => {
    'success': false,
    'code': 86101,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(WidgetTester tester, Size size) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider(
            create: (_) => BilibiliDownloadService(apiService: _LoginApi()),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      ),
    );
  }

  for (final size in const [Size(640, 320), Size(320, 640)]) {
    testWidgets('Cookie login dialog fits ${size.width}x${size.height}', (
      tester,
    ) async {
      await pumpHost(tester, size);
      final context = tester.element(find.byType(Scaffold));
      unawaited(showBilibiliLoginDialog(context));
      await tester.pumpAndSettle();

      expect(find.text('Bilibili 登录'), findsOneWidget);
      expect(find.text('登录/Cookie'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });

    testWidgets('QR login dialog fits ${size.width}x${size.height}', (
      tester,
    ) async {
      await pumpHost(tester, size);
      final context = tester.element(find.byType(Scaffold));
      showBilibiliQrCodeDialog(context);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('login selector waits until its QR flow closes', (tester) async {
    await pumpHost(tester, const Size(640, 600));
    final context = tester.element(find.byType(Scaffold));
    var finished = false;
    unawaited(showBilibiliLoginDialog(context).then((_) => finished = true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫码登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(finished, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
  });
}
