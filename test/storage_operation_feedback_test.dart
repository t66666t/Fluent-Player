import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/storage_management_screen.dart';
import 'package:video_player_app/services/storage_audit_service.dart';

void main() {
  testWidgets('scan errors remain readable with optional diagnostic details', (
    tester,
  ) async {
    final service = StorageAuditService(
      buildInput: () async => throw const FileSystemException(
        'private scan exception',
        '/data/cache',
        OSError('permission denied', 13),
      ),
      deletionBlockedReason: () => null,
    );
    await tester.pumpWidget(
      MaterialApp(home: StorageManagementScreen(service: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('扫描未完成'), findsOneWidget);
    expect(find.text('无法访问文件，请检查文件权限后重试。'), findsOneWidget);
    expect(find.textContaining('private scan exception'), findsNothing);
    expect(find.text('重试扫描'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('扫描未完成'), findsOneWidget);
    await tester.tap(find.text('诊断详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private scan exception'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
