import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_card.dart';
import 'package:video_player_app/theme/app_tokens.dart';

FolderTransferTask _task(
  String id,
  FolderTransferPhase phase, {
  bool incoming = true,
  String name = '课程 A',
}) => FolderTransferTask(
  id: id,
  direction: incoming
      ? FolderTransferDirection.receive
      : FolderTransferDirection.send,
  peerId: 'peer',
  peerName: incoming ? '书房电脑' : '我的手机',
  sourceCollectionId: 'course',
  folderName: name,
  createdAt: DateTime(2026, 10, 15, 12),
  phase: phase,
  mediaCount: 30,
  estimatedBytes: 1610612736,
  totalBytes: 1610612736,
  completedBytes: 402653184,
  bytesPerSecond: 12582912,
  accepted: phase != FolderTransferPhase.offered,
);

void main() {
  Future<void> mount(
    WidgetTester tester,
    List<FolderTransferTask> tasks, {
    Size size = const Size(390, 844),
    double scale = 1,
    GlobalKey? capture,
    VoidCallback? onAccept,
    VoidCallback? onReject,
    VoidCallback? onCancel,
    VoidCallback? onRetry,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: AppTokens.bgBase,
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'MiSans'),
            colorScheme: const ColorScheme.dark(primary: AppTokens.accent),
          ),
          builder: (_, child) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('设备传输'),
              backgroundColor: AppTokens.bgBase,
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    for (final task in tasks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: AppTokens.bgRaised,
                          borderRadius: BorderRadius.circular(12),
                          child: FolderTransferCard(
                            task: task,
                            onAccept: onAccept ?? () {},
                            onReject: onReject ?? () {},
                            onCancel: onCancel ?? () {},
                            onRetry: onRetry ?? () {},
                            onDismiss: () {},
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'incoming offer needs explicit acceptance and explains automatic linking',
    (tester) async {
      var accepted = 0;
      var rejected = 0;
      await mount(
        tester,
        [_task('offer', FolderTransferPhase.offered)],
        onAccept: () => accepted++,
        onReject: () => rejected++,
      );
      expect(find.text('30 个媒体文件 · 约 1.6 GB'), findsOneWidget);
      expect(find.text('接收后加入媒体库，内容与观看进度持续同步。'), findsOneWidget);
      expect(accepted, 0);
      await tester.tap(find.text('接收'));
      expect(accepted, 1);
      await tester.tap(find.text('拒绝'));
      expect(rejected, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('transfer percentage is exactly the confirmed byte fraction', (
    tester,
  ) async {
    final task = _task('bytes', FolderTransferPhase.transferring);
    await mount(tester, [task]);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('folder-transfer-progress-bytes')),
    );
    expect(progress.value, 0.25);
    expect(find.text('25.0%'), findsOneWidget);
    expect(find.text('403 MB / 1.6 GB'), findsOneWidget);
    expect(find.text('12.6 MB/s · 剩余1 分 36 秒'), findsOneWidget);
    expect(find.textContaining('已接收'), findsNothing);
    task.completedBytes = task.totalBytes - 1;
    await mount(tester, [task]);
    expect(find.text('99.9%'), findsOneWidget);
    expect(find.text('100.0%'), findsNothing);
  });

  testWidgets(
    'finishing stages never reuse the transfer percentage or claim completion early',
    (tester) async {
      for (final phase in [
        FolderTransferPhase.preparing,
        FolderTransferPhase.verifying,
        FolderTransferPhase.importing,
        FolderTransferPhase.linking,
      ]) {
        final task = _task('stage', phase)..completedBytes = 1610612736;
        await mount(tester, [task]);
        expect(find.text('100.0%'), findsNothing);
        expect(find.text('已接收 · 自动同步已开启'), findsNothing);
        expect(find.text(folderTransferPhaseLabel(task)), findsOneWidget);
      }
      await mount(tester, [_task('done', FolderTransferPhase.completed)]);
      expect(find.text('已接收 · 自动同步已开启'), findsOneWidget);
      await mount(tester, [
        _task('sent', FolderTransferPhase.completed, incoming: false),
      ]);
      expect(find.text('已发送 · 自动同步已开启'), findsOneWidget);
    },
  );

  testWidgets(
    'paused and failed tasks offer separate continue and retry actions',
    (tester) async {
      var retries = 0;
      var cancelled = 0;
      await mount(
        tester,
        [
          _task('paused', FolderTransferPhase.paused),
          _task('failed', FolderTransferPhase.failed)..error = '另一台设备暂时离线',
        ],
        onRetry: () => retries++,
        onCancel: () => cancelled++,
      );
      await tester.tap(find.text('继续'));
      await tester.tap(find.text('重试'));
      await tester.tap(find.byTooltip('取消传输'));
      expect(retries, 2);
      expect(cancelled, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '390px enlarged text and long names do not overflow or jump on byte updates',
    (tester) async {
      final task = _task(
        'stable',
        FolderTransferPhase.transferring,
        name: '一个很长很长的课程文件夹名称，需要在手机与电脑间发送全部视频与观看进度',
      );
      await mount(tester, [task], scale: 1.3);
      final firstHeight = tester
          .getSize(find.byType(FolderTransferCard))
          .height;
      expect(tester.takeException(), isNull);
      task.completedBytes = 1500000000;
      task.bytesPerSecond = 1048576;
      await mount(tester, [task], scale: 1.3);
      expect(
        tester.getSize(find.byType(FolderTransferCard)).height,
        firstHeight,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('render responsive device transfer previews', (tester) async {
    if (Platform.environment['PROGRESS_SYNC_PREVIEW'] != '1') return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final size in [const Size(390, 980), const Size(1120, 1000)]) {
      final capture = GlobalKey();
      await mount(
        tester,
        [
          _task('offer', FolderTransferPhase.offered),
          _task('active', FolderTransferPhase.transferring, incoming: false),
          _task('link', FolderTransferPhase.linking),
          _task('done', FolderTransferPhase.completed),
        ],
        size: size,
        scale: size.width == 390 ? 1.3 : 1,
        capture: capture,
      );
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '.artifacts/progress-sync/transfer-${size.width.toInt()}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
