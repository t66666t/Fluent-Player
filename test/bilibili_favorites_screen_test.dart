import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_favorites_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/bilibili_loading.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';

import 'support/bilibili_favorites_support.dart';

final _preview = Platform.environment['BILIBILI_FAVORITES_PREVIEW'] == '1';

class _Env {
  final account = FavoriteTestAccountApi();
  final adapter = FavoriteTestAdapter();
  final watched = <String>[];
  final imported = <(String, bool)>[];
  final boundary = GlobalKey();
  final batches = <BilibiliFavoritesImportRequest>[];
  int picks = 0;
  BilibiliFavoritesBatchImporter? importer;
  ImportPlacementRequest? picked = ImportPlacementRequest.explicit(
    ImportCardFeature.bilibiliPage,
    'chosen-folder',
  );
}

Future<_Env> _pump(
  WidgetTester tester, {
  void Function(_Env)? configure,
  Size size = const Size(900, 900),
  double scale = 1,
  bool settle = true,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  final env = _Env();
  configure?.call(env);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    RepaintBoundary(
      key: env.boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          platform: platform,
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: _preview ? 'FavoritePreview' : null,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: BilibiliFavoritesScreen(
          accountApi: env.account,
          api: favoriteTestApi(
            env.adapter,
            cookies: env.account.readLoginCookies,
          ),
          onWatch: (context, {required bvid, page, startAt, preview}) async {
            env.watched.add(bvid);
          },
          onImport: (context, {required bvid, page, required pickPlace}) async {
            env.imported.add((bvid, pickPlace));
          },
          onPickImportLocation: (_, _) async {
            env.picks++;
            return env.picked;
          },
          onBatchImport:
              (context, request, {required isCancelled, onProgress}) async {
                env.batches.add(request);
                if (env.importer case final custom?) {
                  return custom(
                    context,
                    request,
                    isCancelled: isCancelled,
                    onProgress: onProgress,
                  );
                }
                final keys =
                    request.selectedVideos?.map((video) => video.key).toSet() ??
                    {'2:91'};
                return BilibiliFavoritesImportResult(
                  imported: keys,
                  parts: keys.length,
                );
              },
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var n = 0; n < 8; n++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return env;
}

Future<void> _openFolder(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.byKey(const ValueKey('bilibili-favorite-folder-41')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var n = 0; n < 8; n++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _savePreview(WidgetTester tester, _Env env, String name) async {
  if (!_preview) return;
  final boundary =
      env.boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('.artifacts/bilibili-favorites');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
    await SettingsService().init();
    if (_preview) {
      await (FontLoader('FavoritePreview')..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  'assets/fonts/NotoSansCJKsc-Regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets(
    'folder and video lists reuse the normal covers, layout and actions',
    (tester) async {
      final env = await _pump(tester);
      expect(find.byType(BilibiliAdaptiveList), findsOneWidget);
      expect(find.byType(BilibiliVideoListTile), findsOneWidget);
      expect(
        tester.widget<BilibiliCoverImage>(find.byType(BilibiliCoverImage)).url,
        endsWith('@320w_200h_1c.webp'),
      );
      await _openFolder(tester);
      expect(find.text('收藏夹 · 学习收藏夹'), findsOneWidget);
      expect(find.text('收藏的视频'), findsOneWidget);
      expect(find.text('不可播放'), findsOneWidget);
      expect(find.text('02:05'), findsNWidgets(2));
      await tester.tap(find.text('收藏的视频'));
      await tester.pumpAndSettle();
      expect(env.watched, [favoriteTestBvid]);
      await tester.tap(find.text('已失效视频'));
      expect(env.watched, [favoriteTestBvid]);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-$favoriteTestBvid')),
      );
      await tester.pumpAndSettle();
      expect(env.imported, [(favoriteTestBvid, false)]);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$favoriteTestBvid')),
      );
      await tester.pumpAndSettle();
      expect(env.imported.last, (favoriteTestBvid, true));
      expect(env.adapter.requests.every((r) => r.method == 'GET'), isTrue);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );

  testWidgets(
    'refresh changes folder metadata and contents without triggering import or playback',
    (tester) async {
      final env = await _pump(tester);
      await _openFolder(tester);
      env.adapter.routes[favoriteVideosPath] = (_) => favoriteJson(
        favoriteVideosAnswer(
          folder: favoriteFolderJson(title: '新收藏夹名', count: 1),
          videos: [favoriteVideoJson(title: '新收藏视频')],
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorites-refresh')),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏夹 · 新收藏夹名'), findsOneWidget);
      expect(find.text('新收藏视频'), findsOneWidget);
      expect(find.text('已失效视频'), findsNothing);
      expect(env.imported, isEmpty);
      expect(env.watched, isEmpty);
      expect(
        env.adapter.to(favoriteVideosPath).map((r) => r.queryParameters['pn']),
        [1, 1],
      );
    },
  );

  testWidgets(
    'pull to refresh uses the same replacement request as the toolbar',
    (tester) async {
      final env = await _pump(tester);
      env.adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(
        favoriteFoldersAnswer(folders: [favoriteFolderJson(title: '下拉更新后')]),
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.text('下拉更新后'), findsOneWidget);
      expect(env.adapter.to(favoriteFoldersPath), hasLength(2));
    },
  );

  testWidgets('a failed refresh keeps rows and retry reloads page one', (
    tester,
  ) async {
    final env = await _pump(tester);
    env.adapter.routes[favoriteFoldersPath] = (_) =>
        favoriteJson({'code': -500});
    await tester.tap(find.byKey(const ValueKey('bilibili-favorites-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('学习收藏夹'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bilibili-uploader-retry')),
      findsOneWidget,
    );
    env.adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(
      favoriteFoldersAnswer(folders: [favoriteFolderJson(title: '重试成功')]),
    );
    await tester.tap(find.byKey(const ValueKey('bilibili-uploader-retry')));
    await tester.pumpAndSettle();
    expect(find.text('重试成功'), findsOneWidget);
    expect(
      env.adapter.to(favoriteFoldersPath).map((r) => r.queryParameters['pn']),
      [1, 1, 1],
    );
  });

  testWidgets(
    'paginates and deduplicates videos, then stops at the server end',
    (tester) async {
      final env = await _pump(
        tester,
        configure: (env) {
          env.adapter.routes[favoriteVideosPath] = (r) {
            final page = r.queryParameters['pn'] as int;
            return favoriteJson(
              favoriteVideosAnswer(
                folder: favoriteFolderJson(count: 21),
                videos: page == 1
                    ? [
                        for (var n = 1; n <= 20; n++)
                          favoriteVideoJson(id: n, title: '视频$n'),
                      ]
                    : [
                        favoriteVideoJson(id: 20, title: '视频20'),
                        favoriteVideoJson(id: 21, title: '最后一个视频'),
                      ],
                more: page == 1,
              ),
            );
          };
        },
        size: const Size(600, 600),
      );
      await _openFolder(tester);
      await tester.scrollUntilVisible(
        find.text('最后一个视频'),
        500,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      await tester.pumpAndSettle();
      expect(find.text('最后一个视频'), findsOneWidget);
      expect(find.text('视频20'), findsOneWidget);
      expect(
        env.adapter.to(favoriteVideosPath).map((r) => r.queryParameters['pn']),
        [1, 2],
      );
    },
  );

  testWidgets(
    'account switching drops an old folder response still in flight',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final env = await _pump(
        tester,
        settle: false,
        configure: (env) {
          env.adapter.routes[favoriteFoldersPath] = (r) =>
              r.queryParameters['up_mid'] == 7
              ? pending.future
              : favoriteJson(
                  favoriteFoldersAnswer(
                    folders: [favoriteFolderJson(mid: 8, title: '新账号收藏夹')],
                  ),
                );
        },
      );
      expect(find.byType(BilibiliListSkeleton), findsWidgets);
      env.account.switchTo(8);
      await tester.pumpAndSettle();
      expect(find.text('新账号收藏夹'), findsOneWidget);
      pending.complete(
        favoriteJson(
          favoriteFoldersAnswer(folders: [favoriteFolderJson(title: '旧账号收藏夹')]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧账号收藏夹'), findsNothing);
      expect(find.text('新账号收藏夹'), findsOneWidget);
    },
  );

  testWidgets(
    'switching accounts inside a folder drops its delayed video response',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final env = await _pump(tester);
      env.adapter.routes[favoriteVideosPath] = (_) => pending.future;
      await _openFolder(tester, settle: false);
      env.adapter.routes[favoriteFoldersPath] = (r) => favoriteJson(
        favoriteFoldersAnswer(
          folders: [
            favoriteFolderJson(
              mid: r.queryParameters['up_mid'] as int,
              title: '当前账号收藏夹',
            ),
          ],
        ),
      );
      env.account.switchTo(8);
      await tester.pumpAndSettle();
      pending.complete(favoriteJson(favoriteVideosAnswer()));
      await tester.pumpAndSettle();
      expect(find.text('当前账号收藏夹'), findsOneWidget);
      expect(find.text('收藏的视频'), findsNothing);
      expect(find.text('收藏夹 · 学习收藏夹'), findsNothing);
    },
  );

  testWidgets(
    'logout immediately hides account data and ignores an earlier nav response',
    (tester) async {
      final env = await _pump(tester);
      final pending = Completer<BilibiliLoginState>();
      env.account.pendingLogin = pending;
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorites-refresh')),
      );
      await tester.pump();
      env.account.pendingLogin = null;
      env.account.switchTo(null);
      await tester.pumpAndSettle();
      pending.complete(
        const BilibiliLoginState(
          BilibiliLoginStatus.loggedIn,
          account: BilibiliAccountInfo(mid: 7, name: '旧账号', avatarUrl: ''),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('学习收藏夹'), findsNothing);
      expect(find.text('登录后查看自己的 B 站收藏夹'), findsOneWidget);
      expect(env.adapter.to(favoriteFoldersPath), hasLength(1));
    },
  );

  testWidgets(
    'expired sessions provide the existing login entry without showing old rows',
    (tester) async {
      final env = await _pump(tester);
      env.adapter.routes[favoriteFoldersPath] = (_) =>
          favoriteJson({'code': -101});
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorites-refresh')),
      );
      await tester.pumpAndSettle();
      expect(find.text('B 站登录已失效，请重新登录'), findsOneWidget);
      expect(find.text('学习收藏夹'), findsNothing);
      expect(find.text('登录 B 站'), findsOneWidget);
    },
  );

  testWidgets(
    'the Bilibili toolbar opens favorites without requesting data while logged out',
    (tester) async {
      final adapter = FavoriteTestAdapter();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BilibiliHomePage(
              isActive: true,
              api: favoriteTestApi(adapter),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bilibili-favorites-button')));
      await tester.pumpAndSettle();
      expect(find.byType(BilibiliFavoritesScreen), findsOneWidget);
      expect(find.text('登录后查看自己的 B 站收藏夹'), findsOneWidget);
      expect(adapter.requests, isEmpty);
    },
  );

  testWidgets('the account page links to the same favorites screen', (
    tester,
  ) async {
    final account = FavoriteTestAccountApi()..switchTo(null);
    await tester.pumpWidget(
      MaterialApp(home: BilibiliAccountScreen(api: account)),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('bilibili-account-favorites'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliFavoritesScreen), findsOneWidget);
  });

  testWidgets(
    'whole-folder actions are available in the folder row and contents header',
    (tester) async {
      final env = await _pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorite-import-41')),
      );
      await tester.pumpAndSettle();
      expect(env.batches.single.wholeFolder, isTrue);
      expect(env.picks, 0);
      await _openFolder(tester);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorite-import-pick-41')),
      );
      await tester.pumpAndSettle();
      expect(env.batches.last.wholeFolder, isTrue);
      expect(env.batches.last.placement.folderId, 'chosen-folder');
      expect(env.picks, 1);
      expect(env.watched, isEmpty);
    },
  );

  testWidgets(
    'long press selects, taps toggle, and back first exits selection',
    (tester) async {
      final env = await _pump(tester);
      await _openFolder(tester);
      await tester.longPress(find.text('收藏的视频'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
      expect(
        find.byKey(const ValueKey('selection-add-to-playlist')),
        findsNothing,
      );
      await tester.tap(find.text('已失效视频'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('收藏的视频'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(env.watched, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('收藏夹 · 学习收藏夹'), findsOneWidget);
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      expect(
        find.byKey(const ValueKey('bilibili-favorites-select')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'all selection includes unloaded videos and picks a destination once',
    (tester) async {
      final env = await _pump(
        tester,
        size: const Size(390, 600),
        configure: (env) {
          env.adapter.routes[favoriteVideosPath] = (r) {
            final page = r.queryParameters['pn'] as int;
            return favoriteJson(
              favoriteVideosAnswer(
                folder: favoriteFolderJson(count: 21),
                videos: page == 1
                    ? [
                        for (var n = 1; n <= 20; n++)
                          favoriteVideoJson(id: n, title: '选择视频$n'),
                      ]
                    : [favoriteVideoJson(id: 21, title: '尚未加载的视频')],
                more: page == 1,
              ),
            );
          };
        },
      );
      await _openFolder(tester);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final before = scroll.pixels;
      expect(find.text('尚未加载的视频'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bilibili-favorites-select')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorites-select-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 21 项'), findsOneWidget);
      expect(scroll.pixels, closeTo(before, .1));
      await tester.tap(find.text('选择导入位置'));
      await tester.pumpAndSettle();
      expect(env.picks, 1);
      expect(env.batches.single.wholeFolder, isFalse);
      expect(env.batches.single.selectedVideos, hasLength(21));
      expect(env.batches.single.selectedVideos!.last.id, 21);
      expect(env.batches.single.placement.folderId, 'chosen-folder');
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
    },
  );

  testWidgets('only failed items remain selected for retry', (tester) async {
    final env = await _pump(
      tester,
      configure: (env) {
        env.adapter.routes[favoriteVideosPath] = (_) => favoriteJson(
          favoriteVideosAnswer(
            videos: [
              favoriteVideoJson(),
              favoriteVideoJson(id: 92, title: '第二个视频'),
            ],
          ),
        );
        env.importer = (_, request, {required isCancelled, onProgress}) async =>
            const BilibiliFavoritesImportResult(
              imported: {'2:91'},
              failed: {'2:92': '失败'},
              parts: 2,
            );
      },
    );
    await _openFolder(tester);
    await tester.tap(find.byKey(const ValueKey('bilibili-favorites-select')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bilibili-favorites-select-all')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入默认位置'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    env.importer = (_, request, {required isCancelled, onProgress}) async =>
        const BilibiliFavoritesImportResult(imported: {'2:92'}, parts: 1);
    await tester.tap(find.text('导入默认位置'));
    await tester.pumpAndSettle();
    expect(env.batches.last.selectedVideos!.map((v) => v.key), ['2:92']);
    expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
  });

  testWidgets(
    'selection suppresses pull refresh and cancels when accounts change',
    (tester) async {
      final env = await _pump(tester);
      await _openFolder(tester);
      await tester.longPress(find.text('收藏的视频'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(env.adapter.to(favoriteVideosPath), hasLength(1));
      final pending = Completer<BilibiliFavoritesImportResult>();
      late bool Function() cancelled;
      env.importer = (_, request, {required isCancelled, onProgress}) {
        cancelled = isCancelled;
        return pending.future;
      };
      await tester.tap(find.text('导入默认位置'));
      await tester.pump();
      env.adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(
        favoriteFoldersAnswer(
          folders: [favoriteFolderJson(mid: 8, title: '新用户收藏')],
        ),
      );
      env.account.switchTo(8);
      await tester.pumpAndSettle();
      expect(cancelled(), isTrue);
      pending.complete(
        const BilibiliFavoritesImportResult(imported: {'2:91'}, parts: 1),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      expect(find.textContaining('已导入 1 个视频'), findsNothing);
      expect(find.text('新用户收藏'), findsOneWidget);
    },
  );

  testWidgets(
    'cancelling the location picker starts no import and keeps selection',
    (tester) async {
      final env = await _pump(tester, configure: (env) => env.picked = null);
      await _openFolder(tester);
      await tester.longPress(find.text('收藏的视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择导入位置'));
      await tester.pumpAndSettle();
      expect(env.picks, 1);
      expect(env.batches, isEmpty);
      expect(find.text('已选 1 项'), findsOneWidget);
    },
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      'a short favorites list settles within bounds after a fling on $platform',
      (tester) async {
        final env = await _pump(tester, platform: platform);
        await tester.fling(
          find.byType(Scrollable).first,
          const Offset(0, -500),
          1800,
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(position.pixels, closeTo(0, .5));
        expect(position.isScrollingNotifier.value, isFalse);
        await tester.pump(const Duration(seconds: 2));
        expect(position.pixels, closeTo(0, .5));
        expect(env.adapter.to(favoriteFoldersPath), hasLength(1));
      },
    );
    testWidgets(
      'video flings decelerate without triggering refresh on $platform',
      (tester) async {
        final env = await _pump(
          tester,
          platform: platform,
          configure: (env) {
            env.adapter.routes[favoriteVideosPath] = (r) {
              final page = r.queryParameters['pn'] as int;
              return favoriteJson(
                favoriteVideosAnswer(
                  folder: favoriteFolderJson(count: 40),
                  videos: [
                    for (var i = 0; i < 20; i++)
                      favoriteVideoJson(
                        id: (page - 1) * 20 + i + 1,
                        title: '滚动视频$page-$i',
                      ),
                  ],
                  more: page == 1,
                ),
              );
            };
          },
        );
        await _openFolder(tester);
        await tester.fling(
          find.byType(Scrollable).first,
          const Offset(0, -500),
          2200,
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        expect(
          position.pixels,
          inInclusiveRange(
            position.minScrollExtent - .5,
            position.maxScrollExtent + .5,
          ),
        );
        expect(position.isScrollingNotifier.value, isFalse);
        final stopped = position.pixels;
        await tester.pump(const Duration(seconds: 2));
        expect(position.pixels, closeTo(stopped, .1));
        expect(
          env.adapter
              .to(favoriteVideosPath)
              .where((r) => r.queryParameters['pn'] == 1),
          hasLength(1),
        );
        expect(env.adapter.to(favoriteVideosPath).length, lessThanOrEqualTo(2));
      },
    );
  }

  for (final profile in [
    (name: 'phone', size: const Size(360, 780), scale: 1.0),
    (name: 'large-text', size: const Size(320, 740), scale: 1.5),
    (name: 'landscape', size: const Size(740, 360), scale: 1.0),
    (name: 'desktop', size: const Size(1440, 900), scale: 1.0),
  ]) {
    testWidgets(
      'folders and videos fit ${profile.name} using shared list geometry',
      (tester) async {
        final env = await _pump(
          tester,
          size: profile.size,
          scale: profile.scale,
        );
        expect(tester.takeException(), isNull);
        await _savePreview(tester, env, 'folders-${profile.name}');
        await _openFolder(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(BilibiliAdaptiveList), findsOneWidget);
        final tile = find.byKey(const ValueKey('bilibili-favorite-video-2:91'));
        final cover = find.descendant(
          of: tile,
          matching: find.byKey(const ValueKey('bilibili-tile-cover')),
        );
        final info = find.descendant(
          of: tile,
          matching: find.byKey(const ValueKey('bilibili-tile-info')),
        );
        expect(
          tester.getRect(cover).top,
          closeTo(tester.getRect(info).top, .01),
        );
        expect(
          tester.getRect(cover).bottom,
          closeTo(tester.getRect(info).bottom, .01),
        );
        await _savePreview(tester, env, 'videos-${profile.name}');
        await tester.longPress(find.text('收藏的视频'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
        expect(
          find.byKey(const ValueKey('selection-add-to-playlist')),
          findsNothing,
        );
        await _savePreview(tester, env, 'selection-${profile.name}');
      },
    );
  }
}
