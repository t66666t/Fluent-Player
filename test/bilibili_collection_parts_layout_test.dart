import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/bilibili_collection_import_button.dart';
import 'package:video_player_app/widgets/bilibili_parts_picker.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';

const _collection = BilibiliUploaderCollection(
  id: 9,
  isSeason: true,
  title: '从零开始的摄影课：相机基础与构图、光线、后期全流程',
  videoCount: 32,
);

class _Uploader extends BilibiliUploaderService {
  @override
  Future<BilibiliUploaderResult<BilibiliUploaderProfile>> fetchProfile(
    int mid, {
    void Function(BilibiliUploaderProfile profile)? onProfile,
  }) async => BilibiliUploaderResult.success(
    BilibiliUploaderProfile(mid: mid, name: '光影记录者'),
  );
  @override
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchVideos(
    int mid, {
    int page = 1,
    BilibiliUploaderVideoOrder order = BilibiliUploaderVideoOrder.latest,
    String keyword = '',
  }) async => BilibiliUploaderResult.success(
    BilibiliUploaderPage(items: const [], page: page),
  );
  @override
  Future<
    BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderCollection>>
  >
  fetchCollections(int mid, {int page = 1}) async =>
      BilibiliUploaderResult.success(
        BilibiliUploaderPage(items: const [_collection], page: page, total: 1),
      );
  @override
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchCollectionVideos(
    int mid,
    BilibiliUploaderCollection collection, {
    int page = 1,
    bool limitToBrowsePages = true,
  }) async => BilibiliUploaderResult.success(
    BilibiliUploaderPage(items: const [], page: page),
  );
}

void main() {
  final preview =
      Platform.environment['BILIBILI_COLLECTION_PARTS_PREVIEW'] == '1';
  setUpAll(() async {
    await (FontLoader('BilibiliLayout')..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/NotoSansCJKsc-Regular.otf').readAsBytesSync(),
            ),
          ),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
  });

  BilibiliVideoDetail detail({bool season = true}) {
    final json =
        jsonDecode(
              File(
                'test/fixtures/bilibili_multipart_reference.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>;
    if (season) {
      data['ugc_season'] = {
        'id': 9,
        'title': _collection.title,
        'sections': [
          {
            'episodes': [
              {'bvid': data['bvid'], 'title': data['title']},
              {'bvid': 'BV1xx411c7mD', 'title': '第二课：从曝光三要素开始理解相机'},
            ],
          },
        ],
      };
    }
    return BilibiliVideoDetail.tryParse(data)!;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!preview) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('.artifacts/bilibili-collections-parts/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Future<GlobalKey> pump(
    WidgetTester tester,
    Widget home,
    Size size,
    double scale,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: AppTokens.bgBase,
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'BilibiliLayout',
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  for (final width in [280.0, 320.0, 390.0, 600.0, 800.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('detail heading/action stays aligned at $width / $scale', (
        tester,
      ) async {
        final video = detail();
        final pending = Completer<int>();
        final key = await pump(
          tester,
          Scaffold(
            body: BilibiliPlayerPanel(
              bvid: video.bvid,
              cache: BilibiliVideoDetailCache(fetch: (_) async => video),
              offlineDetails: BilibiliOfflineDetails(),
              onImportCollection: (_, _, {placement}) => pending.future,
            ),
          ),
          Size(width, 1100),
          scale,
        );
        final action = find.byType(BilibiliCollectionImportButton);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(action);
        final heading = tester.getRect(
          find.text('合集 · ${_collection.title}（2）'),
        );
        expect(rect.left, greaterThanOrEqualTo(heading.right));
        expect(rect.right, lessThanOrEqualTo(width));
        final main = tester.getRect(
          find.byKey(
            ValueKey(
              'bilibili-collection-import-${tester.widget<BilibiliCollectionImportButton>(action).source.key}',
            ),
          ),
        );
        final pick = tester.getRect(
          find.descendant(of: action, matching: find.byTooltip('选择导入位置')),
        );
        expect(pick.left, greaterThan(main.right));
        expect(pick.right, lessThan(rect.right));
        expect(pick.center.dy, main.center.dy);
        await capture(
          tester,
          key,
          'details-${width.toInt()}-scale${scale.toInt()}',
        );
        await tester.tap(
          find.byKey(
            ValueKey(
              'bilibili-collection-import-${tester.widget<BilibiliCollectionImportButton>(action).source.key}',
            ),
          ),
        );
        await tester.pump();
        expect(tester.getRect(action), rect);
        pending.complete(4);
        await tester.pumpAndSettle();
        expect(tester.getRect(action), rect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });

      if (width >= 320) {
        testWidgets(
          'UP collection import keeps tile geometry at $width / $scale',
          (tester) async {
            var calls = 0;
            final pending = Completer<int>();
            final key = await pump(
              tester,
              BilibiliUploaderScreen(
                mid: 7,
                service: _Uploader(),
                onImportCollection: (_, source, {placement}) {
                  expect(source.collection.id, 9);
                  calls++;
                  return pending.future;
                },
              ),
              Size(width, 900),
              scale,
            );
            await tester.tap(find.widgetWithText(Tab, '合集'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final action = find.byType(BilibiliCollectionImportButton);
            final tile = find.byKey(
              const ValueKey('bilibili-uploader-collection-s9'),
            );
            final rect = tester.getRect(tile);
            final actionRect = tester.getRect(action);
            expect(actionRect.right, lessThanOrEqualTo(rect.right));
            expect(actionRect.bottom, lessThanOrEqualTo(rect.bottom));
            if (scale == 1) expect(rect.height, lessThanOrEqualTo(96));
            await capture(
              tester,
              key,
              'uploader-${width.toInt()}-scale${scale.toInt()}',
            );
            await tester.tap(
              find.byKey(
                ValueKey(
                  'bilibili-collection-import-${tester.widget<BilibiliCollectionImportButton>(action).source.key}',
                ),
              ),
            );
            await tester.pump();
            expect(calls, 1);
            expect(
              find.byType(BilibiliUploaderCollectionScreen),
              findsNothing,
              reason:
                  'import must not also trigger the surrounding tile navigation',
            );
            expect(tester.getRect(tile), rect);
            pending.complete(4);
            await tester.pumpAndSettle();
            expect(tester.getRect(tile), rect);
            await tester.tap(find.text(_collection.title));
            await tester.pumpAndSettle();
            expect(
              find.byType(BilibiliUploaderCollectionScreen),
              findsOneWidget,
            );
            expect(
              find.byType(BilibiliCollectionImportButton),
              findsOneWidget,
              reason:
                  'collection content page has a whole-collection action too',
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }

      testWidgets(
        'reference part picker handles long title at $width / $scale',
        (tester) async {
          final video = detail(season: false);
          final key = await pump(
            tester,
            Scaffold(body: BilibiliPartsPicker(detail: video, currentPage: 2)),
            Size(width, 640),
            scale,
          );
          expect(find.text(video.parts.last.title), findsOneWidget);
          expect(find.byKey(const ValueKey('bilibili-part-2')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(
            tester,
            key,
            'parts-${width.toInt()}-scale${scale.toInt()}',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
