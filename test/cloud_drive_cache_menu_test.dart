import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_actions.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_selection.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';

import 'media_cache_service_test.dart' show FakeBackend;

const _entry = CloudDriveEntry(
  providerId: 'baidu',
  accountLocalId: 'account',
  remoteAccountId: 'remote',
  driveId: '0',
  fileId: 'video',
  parentFileId: 'root',
  name: '摄影课程.mp4',
  kind: CloudDriveEntryKind.video,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MediaCacheService service;
  MediaCacheService? previous;

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_CLOUD_CACHE_MENU')) return;
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (font.existsSync()) {
      await (FontLoader('CacheMenuPreview')..addFont(
            Future.value(ByteData.sublistView(font.readAsBytesSync())),
          ))
          .load();
    }
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  setUp(() async {
    previous = MediaCacheService.instance;
    root = await Directory.systemTemp.createTemp('cloud-cache-menu-');
    final source = cacheSourceForCloudEntry(_entry)!;
    final file = File('${root.path}/complete.mp4')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final variant = CacheVariant(
      source: source,
      quality: const CacheQuality(id: 'original', label: '原画'),
      path: file.path,
      bytes: 4,
      createdAt: 1,
    );
    final journal = File('${root.path}/index.json');
    await journal.writeAsString(
      jsonEncode({
        'version': 1,
        'tasks': [],
        'variants': [variant.toJson()],
      }),
    );
    service = MediaCacheService(
      backend: FakeBackend(root),
      journal: journal,
      observeNetwork: false,
    );
    await service.initialize();
    MediaCacheService.instance = service;
  });

  tearDown(() async {
    MediaCacheService.instance = previous;
    await service.shutdown();
    service.dispose();
    await root.delete(recursive: true);
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(1200, 800),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cloud card uses folder popover at $size / $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'CacheMenuPreview',
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  padding: const EdgeInsets.only(bottom: 34),
                  viewPadding: const EdgeInsets.only(bottom: 34),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Stack(
                  children: [
                    Positioned(
                      bottom: 134,
                      right: 12,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: const CloudEntryCacheMenu(entry: _entry),
                      ),
                    ),
                    const Positioned(
                      bottom: 34,
                      left: 12,
                      right: 12,
                      height: 80,
                      child: ColoredBox(
                        color: Color(0xff333333),
                        child: Center(child: Text('mini playback card')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('cloud-entry-cache-menu')));
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        for (final text in ['缓存其他画质', '删除所有缓存', '管理缓存']) {
          final label = find.text(text);
          expect(label, findsOneWidget);
          final rect = tester.getRect(label);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThan(size.height - 34));
        }
        expect(tester.takeException(), isNull);
        if (size.width == 320 &&
            scale == 1 &&
            const bool.fromEnvironment('CAPTURE_CLOUD_CACHE_MENU')) {
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '.artifacts/media-cache/cloud-card-menu.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(find.text('缓存管理'), findsNothing);
        if (size.width == 320 && scale == 1) {
          await tester.runAsync(
            () => service.deleteAll(cacheSourceForCloudEntry(_entry)!.key),
          );
          await tester.tap(
            find.byKey(const ValueKey('cloud-entry-cache-menu')),
          );
          await tester.pumpAndSettle();
          expect(find.text('缓存'), findsOneWidget);
          expect(find.text('缓存其他画质'), findsNothing);
          expect(find.text('删除所有缓存'), findsNothing);
          await tester.tapAt(const Offset(8, 8));
          await tester.pumpAndSettle();
        }
      });
    }
  }
}
