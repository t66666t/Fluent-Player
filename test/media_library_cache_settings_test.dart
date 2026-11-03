import 'package:video_player_app/widgets/operation_status.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('手机按最短边 600dp 使用紧凑缓存操作', () {
    expect(mediaLibraryCacheUsesPhoneLayout(const Size(390, 844)), isTrue);
    expect(mediaLibraryCacheUsesPhoneLayout(const Size(1280, 800)), isFalse);
    expect(
      mediaLibraryCacheActionStyle(compact: true)?.minimumSize?.resolve({}),
      Size.zero,
    );
    expect(mediaLibraryCacheActionStyle(compact: false), isNull);
  });

  testWidgets('紧凑按钮让明细和清除的文字间距更窄', (tester) async {
    Future<({double labelGap, double detailWidth})> metricsFor({
      required bool compact,
    }) async {
      final style = mediaLibraryCacheActionStyle(compact: compact);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('detail'),
                  style: style,
                  onPressed: () {},
                  child: const Text('明细'),
                ),
                TextButton(
                  key: const ValueKey('clear'),
                  style: style,
                  onPressed: () {},
                  child: const Text('清除'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final detailButton = find.byKey(const ValueKey('detail'));
      final clearButton = find.byKey(const ValueKey('clear'));
      final detailLabel = tester.getRect(
        find.descendant(of: detailButton, matching: find.text('明细')),
      );
      final clearLabel = tester.getRect(
        find.descendant(of: clearButton, matching: find.text('清除')),
      );
      return (
        labelGap: clearLabel.left - detailLabel.right,
        detailWidth: tester.getSize(detailButton).width,
      );
    }

    final phone = await metricsFor(compact: true);
    final desktop = await metricsFor(compact: false);
    expect(phone.labelGap, lessThan(desktop.labelGap));
    expect(phone.detailWidth, lessThan(desktop.detailWidth));
    expect(phone.detailWidth, lessThan(64));
  });

  testWidgets('点击清除后立即在选项内显示进行中，不发全局通知', (tester) async {
    final clear = Completer<void>();
    var cleared = false;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: MaterialApp(
          home: Scaffold(
            body: MediaLibraryBilibiliCacheSection(
              inspectCache: () async => cleared
                  ? const BilibiliStreamCacheReport()
                  : const BilibiliStreamCacheReport(bytes: 1024, fileCount: 1),
              clearCache: () async {
                await clear.future;
                cleared = true;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The inactive label remains in a size-preserving Visibility widget.
    // Assert what is actually shown, rather than counting hidden placeholders.
    final clearingLabel = find.text('清除中').hitTestable();
    expect(clearingLabel, findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('bilibili-cache-clear-all-button')),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);

    expect(clearingLabel, findsOneWidget);
    expect(find.text('正在清除...'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('已清除'), findsNothing);

    clear.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('0 个文件'), findsOneWidget);
    expect(find.byType(OperationStatus), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(clearingLabel, findsNothing);
    expect(find.text('正在清除...'), findsNothing);
  });
  testWidgets('清理失败留在原处并恢复重试按钮', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibraryBilibiliCacheSection(
            inspectCache: () async =>
                const BilibiliStreamCacheReport(bytes: 1024, fileCount: 1),
            clearCache: () async {
              attempts++;
              throw StateError('injected failure');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bilibili-cache-clear-all-button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(attempts, 1);
    expect(find.textContaining('清理未完成'), findsOneWidget);
    expect(find.text('重新清理'), findsOneWidget);
    expect(find.textContaining('1 个文件'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('重新清理'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存统计失败不会伪装成空缓存', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaLibraryBilibiliCacheSection(
            inspectCache: () async => throw StateError('injected stat failure'),
            clearCache: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法统计在线缓存'), findsOneWidget);
    expect(find.text('重新统计'), findsOneWidget);
    expect(find.textContaining('0 个文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
