import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_qr_login_controller.dart';

class _QrApi extends BilibiliApiService {
  final generations = <Completer<Map<String, String>>>[];
  bool failPoll = false;

  @override
  Future<Map<String, String>> generateQrCode() {
    final result = Completer<Map<String, String>>();
    generations.add(result);
    return result.future;
  }

  @override
  Future<Map<String, dynamic>> pollQrCode(String qrcodeKey) async {
    if (failPoll) throw StateError('offline');
    return {'success': false, 'code': 86101};
  }
}

void main() {
  test('a late QR generation cannot replace a refreshed QR', () async {
    final api = _QrApi();
    final controller = BilibiliQrLoginController(api: api, onLoggedIn: (_) {});
    addTearDown(controller.dispose);
    final first = controller.start();
    final second = controller.start();
    api.generations[1].complete({'url': 'new', 'qrcode_key': 'new-key'});
    await second;
    api.generations[0].complete({'url': 'old', 'qrcode_key': 'old-key'});
    await first;
    expect(controller.qrUrl, 'new');
  });

  testWidgets('poll exceptions show retry status without an unhandled error', (
    tester,
  ) async {
    final api = _QrApi()..failPoll = true;
    final controller = BilibiliQrLoginController(api: api, onLoggedIn: (_) {});
    final start = controller.start();
    api.generations.single.complete({'url': 'qr', 'qrcode_key': 'key'});
    await start;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.status, '网络异常，正在重试');
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
