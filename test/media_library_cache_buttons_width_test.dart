import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

/// B站缓存区「明细/收起」「清除/清除中」按钮切换状态时宽度不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<Completer<void>> pumpSection(WidgetTester tester) async {
    final clearing = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaLibraryBilibiliCacheSection(
              library: LibraryService(),
              inspectCache: () async =>
                  const BilibiliStreamCacheReport(bytes: 2048, fileCount: 2),
              clearCache: () => clearing.future,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return clearing;
  }

  const detail = ValueKey('bilibili-cache-detail-button');
  const clearAll = ValueKey('bilibili-cache-clear-all-button');

  testWidgets('明细 ↔ 收起：宽度不变', (tester) async {
    await pumpSection(tester);
    final size = tester.getSize(find.byKey(detail));
    await tester.tap(find.byKey(detail));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);
    expect(tester.getSize(find.byKey(detail)), size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清除 → 清除中：宽度不变', (tester) async {
    final clearing = await pumpSection(tester);
    final size = tester.getSize(find.byKey(clearAll));
    await tester.tap(find.byKey(clearAll));
    await tester.pump();
    final confirm = find.widgetWithText(FilledButton, '清除');
    if (confirm.evaluate().isNotEmpty) {
      await tester.tap(confirm.last);
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(tester.getSize(find.byKey(clearAll)), size);
    clearing.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byKey(clearAll)), size);
  });
}