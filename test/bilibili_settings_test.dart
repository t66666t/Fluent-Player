import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_account_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_settings_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_cache_limit_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/settings_service.dart';

const _mib = 1024 * 1024;

BilibiliWatchHistoryEntry _entry(String bvid) => BilibiliWatchHistoryEntry(
  bvid: bvid,
  title: 'Title $bvid',
  ownerName: 'UP',
  page: 1,
  watchedAt: DateTime(2026, 10, 8, 12),
);

Future<void> _writeCard(
  Directory root,
  String name,
  int bytes,
  DateTime modified,
) async {
  final dir = Directory('${root.path}/$name');
  await dir.create(recursive: true);
  final file = File('${dir.path}/video.track');
  await file.writeAsBytes(List<int>.filled(bytes, 1));
  await file.setLastModified(modified);
}

/// Cache manager whose disk side is replaced, for widget tests.
class _FakeCache extends BilibiliCacheManager {
  _FakeCache({required bool Function() playing})
    : super(
        limiter: BilibiliCacheLimiter(
          cacheRoot: () async => Directory.systemTemp,
          removeEntry: (_, _) async {},
        ),
        limitBytes: () => SettingsService().bilibiliCacheLimitBytes,
        isPlaying: playing,
        protectedEntries: () => const <String>{},
        clearEverything: () async {},
      );

  int clears = 0;
  int trims = 0;
  int usedBytes = 300 * _mib;

  @override
  Future<BilibiliCacheUsage> usage() async =>
      BilibiliCacheUsage(bytes: usedBytes, fileCount: 3);

  @override
  Future<BilibiliCacheTrimResult> trimNow() async {
    trims++;
    return BilibiliCacheTrimResult(
      bytesBefore: usedBytes,
      bytesAfter: usedBytes,
    );
  }

  @override
  Future<BilibiliCacheClearOutcome> clearAll() async {
    if (isPlaying()) return BilibiliCacheClearOutcome.refusedWhilePlaying;
    clears++;
    usedBytes = 0;
    notifyListeners();
    return BilibiliCacheClearOutcome.cleared;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
  });

  group('settings', () {
    test('cache limit defaults and persists', () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.bilibiliCacheLimitBytes, 1024 * _mib);
      await settings.updateSetting<int>('bilibiliCacheLimitBytes', 256 * _mib);
      settings.resetForTest();
      await settings.init();
      expect(settings.bilibiliCacheLimitBytes, 256 * _mib);
    });

    for (final legacyReadOnly in [false, true]) {
      test(
        'retired account preference is discarded ($legacyReadOnly)',
        () async {
          SharedPreferences.setMockInitialValues({
            'bilibiliAccountReadOnly': legacyReadOnly,
            'bilibiliCacheLimitBytes': 256 * _mib,
            'bilibiliRecordSearchHistory': false,
          });
          final settings = SettingsService();
          await settings.init();
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.containsKey('bilibiliAccountReadOnly'), isFalse);
          expect(
            settings.exportSettingsSnapshot().values.whereType<Map>().any(
              (group) => group.containsKey('bilibiliAccountReadOnly'),
            ),
            isFalse,
          );
          expect(settings.bilibiliCacheLimitBytes, 256 * _mib);
          expect(settings.bilibiliRecordSearchHistory, isFalse);
          await expectLater(
            settings.updateSetting<bool>('bilibiliAccountReadOnly', false),
            throwsArgumentError,
          );
          expect(prefs.containsKey('bilibiliAccountReadOnly'), isFalse);
        },
      );
    }

    test('cache limit snaps to an offered size', () {
      expect(
        SettingsService.normalizeBilibiliCacheLimit(300 * _mib),
        256 * _mib,
      );
      expect(SettingsService.normalizeBilibiliCacheLimit(1), 128 * _mib);
      expect(
        SettingsService.normalizeBilibiliCacheLimit(9999 * _mib),
        2048 * _mib,
      );
    });
  });

  group('cache limiter', () {
    late Directory root;
    late List<String> removed;
    late BilibiliCacheLimiter limiter;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bili_cache_limit_');
      removed = <String>[];
      limiter = BilibiliCacheLimiter(
        cacheRoot: () async => root,
        removeEntry: (name, dir) async {
          removed.add(name);
          await dir.delete(recursive: true);
        },
      );
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'removes least recently written cards first until under the cap',
      () async {
        await _writeCard(root, 'old', 300, DateTime(2026, 1, 1));
        await _writeCard(root, 'middle', 300, DateTime(2026, 5, 1));
        await _writeCard(root, 'new', 300, DateTime(2026, 9, 1));

        expect((await limiter.usage()).bytes, 900);
        final result = await limiter.trim(500);
        expect(removed, ['old', 'middle']);
        expect(result.bytesBefore, 900);
        expect(result.bytesAfter, 300);
        expect(await Directory('${root.path}/new').exists(), isTrue);
      },
    );

    test('under the cap nothing is removed', () async {
      await _writeCard(root, 'a', 100, DateTime(2026, 1, 1));
      final result = await limiter.trim(500);
      expect(removed, isEmpty);
      expect(result.bytesAfter, 100);
    });

    test('protected cards and loose files are kept', () async {
      await _writeCard(root, 'playing', 400, DateTime(2026, 1, 1));
      await _writeCard(root, 'other', 400, DateTime(2026, 2, 1));
      await File(
        '${root.path}/loose.bin',
      ).writeAsBytes(List<int>.filled(50, 1));

      final result = await limiter.trim(
        100,
        protectedEntries: const {'playing'},
      );
      expect(removed, ['other']);
      expect(result.bytesAfter, 450);
      expect(await File('${root.path}/loose.bin').exists(), isTrue);
    });

    test('a missing cache root is empty', () async {
      await root.delete(recursive: true);
      expect((await limiter.usage()).bytes, 0);
      expect((await limiter.trim(0)).removedEntries, isEmpty);
    });
  });

  group('cache manager', () {
    test('clear all is refused while playing', () async {
      var playing = true;
      var cleared = 0;
      final manager = BilibiliCacheManager(
        limiter: BilibiliCacheLimiter(
          cacheRoot: () async => Directory.systemTemp,
          removeEntry: (_, _) async {},
        ),
        limitBytes: () => 0,
        isPlaying: () => playing,
        protectedEntries: () => const <String>{},
        clearEverything: () async => cleared++,
      );
      addTearDown(manager.dispose);

      expect(
        await manager.clearAll(),
        BilibiliCacheClearOutcome.refusedWhilePlaying,
      );
      expect(cleared, 0);

      playing = false;
      expect(await manager.clearAll(), BilibiliCacheClearOutcome.cleared);
      expect(cleared, 1);
    });

    test('trim passes the protected cards and current cap', () async {
      final root = await Directory.systemTemp.createTemp('bili_cache_mgr_');
      addTearDown(() => root.delete(recursive: true));
      await _writeCard(root, 'playing', 300, DateTime(2026, 1, 1));
      await _writeCard(root, 'idle', 300, DateTime(2026, 2, 1));
      final removed = <String>[];
      final manager = BilibiliCacheManager(
        limiter: BilibiliCacheLimiter(
          cacheRoot: () async => root,
          removeEntry: (name, dir) async {
            removed.add(name);
            await dir.delete(recursive: true);
          },
        ),
        limitBytes: () => 400,
        isPlaying: () => true,
        protectedEntries: () => const {'playing'},
        clearEverything: () async {},
      );
      addTearDown(manager.dispose);

      final result = await manager.trimNow();
      expect(removed, ['idle']);
      expect(result.bytesAfter, 300);
    });
  });

  testWidgets('settings page saves switches, clears history and cache', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsService();
    await settings.init();
    final history = BilibiliHistoryService.instance;
    await history.addSearch('关键词');
    await history.recordWatch(_entry('BV1GJ411x7h7'));
    var playing = true;
    final cache = _FakeCache(playing: () => playing);
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(home: BilibiliSettingsScreen(cacheManager: cache)),
    );
    await tester.pumpAndSettle();

    expect(find.text('账号只读模式'), findsNothing);
    expect(
      find.byKey(const ValueKey('bilibili-setting-read-only')),
      findsNothing,
    );
    expect(find.text('账号'), findsNothing);
    expect(find.text('播放'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-search-history')),
    );
    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-watch-history')),
    );
    await tester.pumpAndSettle();
    expect(settings.bilibiliRecordSearchHistory, isFalse);
    expect(settings.bilibiliRecordWatchHistory, isFalse);

    // Clearing asks first; cancel keeps the records.
    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-clear-search')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(history.searchHistory, ['关键词']);
    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-clear-search')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(history.searchHistory, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-clear-watch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(history.watchHistory, isEmpty);

    // Cache: usage, cap choice, clear refused while playing.
    expect(find.text('当前占用 300 MB / 上限 1 GB'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('bilibili-cache-limit-${256 * _mib}')),
    );
    await tester.pumpAndSettle();
    expect(settings.bilibiliCacheLimitBytes, 256 * _mib);
    expect(cache.trims, 1);
    expect(find.text('当前占用 300 MB / 上限 256 MB'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-clear-cache')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cache.clears, 0);

    playing = false;
    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-clear-cache')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清理'));
    await tester.pumpAndSettle();
    expect(cache.clears, 1);
    expect(find.text('当前占用 0 B / 上限 256 MB'), findsOneWidget);
  });

  testWidgets('home page follows the settings right away', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsService();
    await settings.init();
    await BilibiliHistoryService.instance.addSearch('旧词');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BilibiliHomePage(isActive: true))),
    );
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);

    // The avatar opens the account page, which links to the settings page.
    await tester.tap(find.byKey(const ValueKey('bilibili-account-button')));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliAccountScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bilibili-account-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliSettingsScreen), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('bilibili-setting-search-history')),
    );
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsNothing);
    expect(BilibiliHistoryService.instance.searchHistory, ['旧词']);

    await settings.updateSetting<bool>('bilibiliRecordSearchHistory', true);
    await tester.pump();
    expect(find.text('搜索历史'), findsOneWidget);
    await BilibiliHistoryService.instance.clearSearch();
    await tester.pump();
    expect(find.text('搜索历史'), findsNothing);
  });
}
