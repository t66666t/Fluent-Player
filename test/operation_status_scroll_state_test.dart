import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/operation_status.dart';

void main() {
  test(
    'diagnostic JSON removes credential values while preserving fields, files, and error codes',
    () {
      const raw =
          r'{"api_key":"first-secret","apiKey":"second-secret","access_token":"access-secret","refresh_token":"refresh-secret","client_secret":"client-secret","password":"password-secret","Authorization":"Bearer auth-secret","Cookie":"session=cookie-secret","status":401,"file":"D:\\media\\api_key-notes.srt"}';
      final redacted = safeOperationDiagnostic(raw);
      final json = jsonDecode(redacted) as Map<String, dynamic>;
      for (final key in [
        'api_key',
        'apiKey',
        'access_token',
        'refresh_token',
        'client_secret',
        'password',
        'Authorization',
        'Cookie',
      ]) {
        expect(json[key], '[已隐藏]');
      }
      expect(json['status'], 401);
      expect(json['file'], r'D:\media\api_key-notes.srt');
      expect(safeOperationDiagnostic(redacted), redacted);
    },
  );

  test(
    'diagnostic key-value fields support quoted values without masking filenames',
    () {
      const raw =
          "api_key=bare-secret apiKey: \"quoted secret\"\n"
          "access_token='single secret'; refresh_token=refresh-secret\n"
          "client_secret: client-secret password=p-word status=403\n"
          r'file=D:\media\password-guide.srt model=api_key-preview';
      final redacted = safeOperationDiagnostic(raw);
      for (final value in [
        'bare-secret',
        'quoted secret',
        'single secret',
        'refresh-secret',
        'client-secret',
        'p-word',
      ]) {
        expect(redacted, isNot(contains(value)));
      }
      expect(redacted, contains('status=403'));
      expect(redacted, contains(r'file=D:\media\password-guide.srt'));
      expect(redacted, contains('model=api_key-preview'));
      expect(safeOperationDiagnostic(redacted), redacted);
    },
  );

  test(
    'URL credentials and query secrets are hidden while the host and response code remain',
    () {
      const raw =
          '{"url":"https://alice:p%40ss@api.example.test:8443/v1?access_token=url-token&api_key=url-key&limit=20","status":401}';
      final redacted = safeOperationDiagnostic(raw);
      final json = jsonDecode(redacted) as Map<String, dynamic>;
      final url = json['url'] as String;
      expect(url, contains('https://[已隐藏]@api.example.test:8443/v1'));
      expect(url, contains('limit=20'));
      for (final value in ['alice', 'p%40ss', 'url-token', 'url-key']) {
        expect(url, isNot(contains(value)));
      }
      expect(json['status'], 401);
      expect(safeOperationDiagnostic(redacted), redacted);
    },
  );

  testWidgets(
    'diagnostic expansion never reads a surrounding saved scroll offset as a bool',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final bucket = PageStorageBucket();
      var showDetails = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ListView(
                    key: const PageStorageKey('operation-list'),
                    controller: controller,
                    children: [
                      const SizedBox(height: 500),
                      OperationStatus(
                        title: '无法读取字幕区域',
                        kind: OperationStatusKind.error,
                        message: '请检查媒体文件后重试。',
                        details: showDetails
                            ? 'Frame capture failed for the selected time.'
                            : null,
                      ),
                      const SizedBox(height: 800),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      final savedOffset = controller.offset;
      expect(savedOffset, greaterThan(0));
      update(() => showDetails = true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.offset, savedOffset);
      await tester.ensureVisible(find.text('诊断详情'));
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(
        find.text('Frame capture failed for the selected time.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // Reopening must not restore the tile's bool as a text scroll offset.
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('诊断详情'));
      await tester.pumpAndSettle();
      expect(
        find.text('Frame capture failed for the selected time.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
