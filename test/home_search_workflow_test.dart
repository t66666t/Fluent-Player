import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/home_search_request.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/services/home_search_navigation.dart';
import 'package:video_player_app/services/home_search_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_search_prompt.dart';
import 'support/cloud_drive_fixture.dart';

class _SearchClient extends PodcastClient {
  final queries = <String>[];
  @override
  Future<List<PodcastSearchResult>> search(
    String query, {
    String region = 'CN',
    String provider = 'apple',
  }) async {
    queries.add(query);
    return [
      const PodcastSearchResult(
        title: 'Online result',
        author: 'Author',
        feedUrl: 'https://example.test/feed',
      ),
    ];
  }
}

Future<void> _mountHome(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData.dark().copyWith(
      pageTransitionsTheme: appPageTransitionsTheme,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          child: const Text('home search'),
          onPressed: () async {
            final request = await showHomeSearchPrompt(context);
            if (context.mounted && request != null) {
              await openHomeSearchResults(context, request);
            }
          },
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
  });

  test(
    'all scope names persist and unknown or malformed values fall back',
    () async {
      final prefs = await SharedPreferences.getInstance();
      for (final scope in HomeSearchScope.values) {
        await HomeSearchPreferences(prefs).select(scope);
        expect(
          HomeSearchPreferences(await SharedPreferences.getInstance()).scope,
          scope,
        );
      }
      await prefs.setString(HomeSearchPreferences.scopeKey, 'retired-scope');
      expect(HomeSearchPreferences(prefs).scope, HomeSearchScope.library);
      await prefs.setInt(HomeSearchPreferences.scopeKey, 2);
      expect(HomeSearchPreferences(prefs).scope, HomeSearchScope.library);
    },
  );

  test('every scope passes its query to the correct page', () {
    for (final scope in HomeSearchScope.values) {
      final page = homeSearchDestination(
        HomeSearchRequest(scope: scope, query: 'lesson'),
      );
      switch (scope) {
        case HomeSearchScope.library:
          expect((page as CollectionScreen).searchQuery, 'lesson');
        case HomeSearchScope.podcasts:
          expect((page as PodcastLibrarySearchPage).initialQuery, 'lesson');
        case HomeSearchScope.podcastSearch:
          expect((page as PodcastDiscoverPage).initialQuery, 'lesson');
        case HomeSearchScope.bilibili:
          expect((page as BilibiliHomePage).initialKeyword, 'lesson');
          expect(page.showAppBar, isTrue);
        default:
          expect((page as CloudDriveScreen).initialProviderId, scope.name);
          expect(page.initialQuery, 'lesson');
      }
    }
  });

  testWidgets('scope is remembered even when the dialog is cancelled', (
    tester,
  ) async {
    await _mountHome(tester);
    await tester.tap(find.text('home search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择搜索范围：媒体库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('哔哩哔哩搜索页'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('home search'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('选择搜索范围：哔哩哔哩搜索页'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  group('podcast destinations', () {
    late Directory directory;
    late PodcastStore store;
    late PodcastController controller;
    late _SearchClient client;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('home-search-');
      store = PodcastStore(sqlite3.openInMemory());
      client = _SearchClient();
      controller = PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: client.http,
        ),
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
    });
    tearDown(() async {
      PodcastRuntime.debugOverride = null;
      await controller.close();
      store.close();
      directory.deleteSync(recursive: true);
    });

    testWidgets(
      'home submits once after the entrance and returns with Escape or Back',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        await HomeSearchPreferences(
          prefs,
        ).select(HomeSearchScope.podcastSearch);
        await _mountHome(tester);
        for (final escape in [true, false]) {
          await tester.tap(find.text('home search'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '  learning  ');
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('media-search-submit')));
          await tester.pump();
          expect(client.queries.length, escape ? 0 : 1);
          await tester.pumpAndSettle();
          expect(find.byType(PodcastDiscoverPage), findsOneWidget);
          expect(client.queries.last, 'learning');
          expect(store.searchHistory, ['learning']);
          if (escape) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pumpAndSettle();
          expect(find.text('搜索喜欢的播客'), findsOneWidget);
          expect(find.byType(PodcastDiscoverPage), findsOneWidget);
          if (escape) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pumpAndSettle();
          expect(find.text('home search'), findsOneWidget);
          expect(find.byType(PodcastDiscoverPage), findsNothing);
        }
        expect(client.queries, ['learning', 'learning']);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'subscribed search uses aliases, excludes hidden and inactive episodes',
      (tester) async {
        store.mergeFeed(
          PodcastFeed(
            PodcastChannel(
              id: 'c',
              feedUrl: 'https://example.test/c',
              title: '频道 A',
              author: '作者甲',
            ),
            [
              const PodcastEpisode(
                id: 'visible',
                channelId: 'c',
                title: '原始标题',
                media: [PodcastMedia(url: 'https://example.test/audio.mp3')],
              ),
              const PodcastEpisode(
                id: 'hidden',
                channelId: 'c',
                title: '天文学隐藏',
                media: [PodcastMedia(url: 'https://example.test/audio.mp3')],
              ),
            ],
          ),
          initial: true,
        );
        store.setPresentation('visible', localTitle: '天文学别名');
        store.setPresentation('hidden', hidden: true);
        store.mergeFeed(
          PodcastFeed(
            PodcastChannel(
              id: 'old',
              feedUrl: 'https://example.test/old',
              title: '旧频道',
              active: false,
            ),
            [
              const PodcastEpisode(
                id: 'inactive',
                channelId: 'old',
                title: '天文学旧节目',
                media: [PodcastMedia(url: 'https://example.test/audio.mp3')],
              ),
            ],
          ),
          initial: true,
        );
        final prefs = await SharedPreferences.getInstance();
        await HomeSearchPreferences(prefs).select(HomeSearchScope.podcasts);
        await _mountHome(tester);
        await tester.tap(find.text('home search'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '天文学');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('visible')), findsOneWidget);
        expect(find.byKey(const ValueKey('hidden')), findsNothing);
        expect(find.byKey(const ValueKey('inactive')), findsNothing);
        expect(client.queries, isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('podcast-library-search-input')),
          '作者甲',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, '频道 A'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(PodcastLibrarySearchPage), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  testWidgets(
    'home scope overrides the last cloud tab and skips a signed-out account',
    (tester) async {
      await SettingsService().init();
      final baidu = FixtureCloudProvider('baidu', {});
      final quark = FixtureCloudProvider('quark', {
        '0': [cloudEntry('match', name: 'lesson.mp4', provider: 'quark')],
      });
      final runtime = await cloudRuntime([baidu, quark]);
      CloudDriveRuntime.instance = runtime;
      addTearDown(runtime.shutdown);
      final oldAccount = runtime.accounts.accounts.firstWhere(
        (a) => a.providerId == 'quark',
      );
      await runtime.accounts.signOut(oldAccount.localId);
      await runtime.accounts.commitVerified(
        providerId: 'quark',
        remoteAccountId: 'other-account',
        displayName: '另一个账号',
        credential: const CloudDriveCredential(
          cookies: [
            CloudDriveCookie(
              name: 'session',
              value: 'other',
              domain: '.example.invalid',
            ),
          ],
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cloudDrive.lastProvider', 'baidu');
      await prefs.setString('cloudDrive.quark.account', oldAccount.localId);
      await HomeSearchPreferences(prefs).select(HomeSearchScope.quark);
      await _mountHome(tester);
      await tester.tap(find.text('home search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lesson');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('lesson.mp4'), findsOneWidget);
      expect(baidu.calls, isEmpty);
      expect(quark.calls.single.account, 'other-account');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an unavailable saved cloud scope stays selected and blocks local fallback',
    (tester) async {
      final runtime = await cloudRuntime([FixtureCloudProvider('quark', {})]);
      CloudDriveRuntime.instance = runtime;
      addTearDown(runtime.shutdown);
      final prefs = await SharedPreferences.getInstance();
      await HomeSearchPreferences(prefs).select(HomeSearchScope.quark);
      await runtime.accounts.signOut(runtime.accounts.accounts.single.localId);
      await _mountHome(tester);
      await tester.tap(find.text('home search'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('选择搜索范围：夸克网盘'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '保留关键词');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(CollectionScreen), findsNothing);
      expect(find.text('夸克网盘尚未登录'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留关键词',
      );
      expect(HomeSearchPreferences(prefs).scope, HomeSearchScope.quark);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final id in ['baidu', 'quark', 'uc', 'aliyun']) {
    testWidgets(
      '$id home search filters the correct root and returns in one step',
      (tester) async {
        await SettingsService().init();
        final provider = FixtureCloudProvider(id, {
          cloudDriveRootId(id): [
            cloudEntry('match', name: 'lesson.mp4', provider: id),
            cloudEntry('other', name: 'other.mp4', provider: id),
          ],
        });
        final runtime = await cloudRuntime([provider]);
        CloudDriveRuntime.instance = runtime;
        addTearDown(runtime.shutdown);
        final prefs = await SharedPreferences.getInstance();
        await HomeSearchPreferences(
          prefs,
        ).select(HomeSearchScope.values.byName(id));
        await _mountHome(tester);
        for (final escape in [true, false]) {
          await tester.tap(find.text('home search'));
          await tester.pumpAndSettle();
          expect(
            find.byTooltip('选择搜索范围：${cloudDriveProviderNames[id]}'),
            findsOneWidget,
          );
          await tester.enterText(find.byType(TextField), 'lesson');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(find.byType(CloudDriveScreen), findsOneWidget);
          expect(
            provider.calls.every((call) => call.parent == cloudDriveRootId(id)),
            isTrue,
          );
          expect(find.text('lesson.mp4'), findsOneWidget);
          expect(find.text('other.mp4'), findsNothing);
          if (escape) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pumpAndSettle();
          expect(find.byType(CloudDriveScreen), findsNothing);
          expect(find.text('home search'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
