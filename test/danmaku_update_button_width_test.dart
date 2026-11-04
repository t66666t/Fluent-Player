import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_settings_dialog.dart';

/// 不联网：更新弹幕一直挂起，直到测试手动结束。
class _PendingDanmakuService extends BilibiliDownloadService {
  _PendingDanmakuService() : super(apiService: BilibiliApiService());

  final calls = <Completer<void>>[];

  @override
  Future<void> updateDanmakuForVideo(VideoItem item, LibraryService library) {
    final completer = Completer<void>();
    calls.add(completer);
    return completer.future;
  }
}

final _item = VideoItem(
  id: 'video-id',
  path: 'video.mp4',
  title: 'video',
  durationMs: 1000,
  lastUpdated: 1,
  isBilibiliExported: true,
  sourceRef: const MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliBv,
    bvid: 'BV1xx411c7mD',
    cid: 123,
  ),
);

Finder _button() => find.ancestor(
  of: find.byWidgetPredicate(
    (w) => w is Text && (w.data == '立即更新' || w.data == '更新中'),
  ),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_PendingDanmakuService> open(
    WidgetTester tester, {
    required Size size,
    double scale = 1.0,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final service = _PendingDanmakuService();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<BilibiliDownloadService>.value(value: service),
          ChangeNotifierProvider<LibraryService>.value(value: LibraryService()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDanmakuSettingsDialog(context, videoItem: _item),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return service;
  }

  for (final (size, scale) in [
    (const Size(1280, 800), 1.0),
    (const Size(390, 760), 1.0),
    (const Size(360, 700), 1.5),
    (const Size(360, 700), 2.0),
  ]) {
    testWidgets('立即更新 → 更新中 → 失败：宽度和左右位置不变（$size × $scale）', (tester) async {
      final service = await open(tester, size: size, scale: scale);
      await tester.ensureVisible(find.text('立即更新'));
      await tester.pumpAndSettle();
      // 只比水平方向：更新时按钮下方会多出一行状态提示，对话框整体
      // 会在竖直方向重新居中，这不属于按钮宽度问题。
      (double, double) horizontal() {
        final r = tester.getRect(_button());
        return (r.left, r.width);
      }

      final idle = horizontal();
      final title = tester.getTopLeft(find.text('更新弹幕')).dx;

      await tester.tap(find.text('立即更新'));
      await tester.pump();
      expect(find.text('更新中'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(horizontal(), idle);
      expect(tester.getTopLeft(find.text('更新弹幕')).dx, title);

      // 进行中不能重复触发。
      await tester.tap(find.text('更新中'), warnIfMissed: false);
      await tester.pump();
      expect(service.calls, hasLength(1));

      service.calls.single.completeError(StateError('fake'));
      await tester.pump();
      expect(find.text('立即更新'), findsOneWidget);
      expect(horizontal(), idle);
      expect(tester.takeException(), isNull);
    });
  }
}
