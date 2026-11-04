import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/settings_service.dart';

// Real LibraryService data, durable ledger and deletion; this facade delays only
// the first successful registration acknowledgement, without changing its value.
class _DelayedRegistration implements LibraryService {
  _DelayedRegistration(this.real);
  final LibraryService real;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool first = true;

  @override
  Future<void> addTransientVideos(Iterable<VideoItem> items) async {
    await real.addTransientVideos(items);
    if (first) {
      first = false;
      entered.complete();
      await release.future;
    }
  }

  @override
  Directory? get dataRootDirOrNull => real.dataRootDirOrNull;
  @override
  List<VideoItem> get bilibiliStreamItems => real.bilibiliStreamItems;
  @override
  List<VideoItem> get transientVideos => real.transientVideos;
  @override
  VideoItem? getVideo(String id) => real.getVideo(id);
  @override
  VideoCollection? getCollection(String id) => real.getCollection(id);
  @override
  Future<bool> discardTransientVideo(String id) =>
      real.discardTransientVideo(id);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected dependency ${invocation.memberName}');
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

BilibiliVideoInfo _info({int parts = 1}) => BilibiliVideoInfo(
  title: 'controlled watch',
  desc: '',
  pic: '',
  bvid: 'BV1xx411c7mD',
  aid: '123',
  ownerName: 'fixture',
  ownerMid: '1',
  pubDate: 0,
  pages: [
    for (var i = 1; i <= parts; i++)
      BilibiliPage(
        cid: 100 + i,
        page: i,
        part: 'part $i',
        duration: 60,
        bvid: 'BV1xx411c7mD',
        aid: '123',
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LibraryService real;
  late _DelayedRegistration delayed;
  late BilibiliDownloadService service;
  late PathProviderPlatform original;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('actual-watch-cancel-');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    BilibiliHistoryService.instance.resetForTest();
    real = LibraryService()..resetLibraryForTesting();
    await real.init();
    delayed = _DelayedRegistration(real);
    service = BilibiliDownloadService();
  });
  tearDown(() async {
    if (!delayed.release.isCompleted) delayed.release.complete();
    await service.shutdown();
    real.resetLibraryForTesting();
    BilibiliHistoryService.instance.resetForTest();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = original;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> events() => pumpEventQueue(times: 10);
  ({
    BilibiliWatchLaunch<BilibiliWatchPlan> launch,
    Future<BilibiliWatchPlan> ready,
    Future<void> oldDone,
    Future<void> Function() drain,
  })
  scenario({Completer<BilibiliVideoInfo>? retryInfo, int parts = 1}) {
    final ready = Completer<BilibiliWatchPlan>(), oldDone = Completer<void>();
    var loads = 0, infos = 0;
    final discards = <Future<void>>[];
    final loader = BilibiliWatchLoader(
      service: service,
      library: delayed,
      bvid: 'BV1xx411c7mD',
      fetchInfo: (_) async {
        if (++infos == 2 && retryInfo != null) return retryInfo.future;
        return _info(parts: parts);
      },
    );
    final launch = BilibiliWatchLaunch<BilibiliWatchPlan>(
      load: (attempt) async {
        final number = ++loads;
        try {
          return await loader(attempt);
        } finally {
          if (number == 1) oldDone.complete();
        }
      },
      timelineFor: () => BilibiliOpenTimeline('BV1xx411c7mD'),
      onReady: (plan, _) {
        if (!ready.isCompleted) ready.complete(plan);
      },
      discard: (plan, kept) {
        final work = discardAbandonedWatch(
          plan,
          library: delayed,
          keep: kept?.itemIds ?? const <String>{},
        );
        discards.add(work);
        return work;
      },
    );
    addTearDown(launch.dispose);
    Future<void> drain() async {
      // Launch dispatches cleanup after its load future resolves. Await the
      // actual disk-cleanup futures rather than treating event ticks as IO ack.
      await events();
      while (discards.isNotEmpty) {
        final pending = List<Future<void>>.of(discards);
        discards.clear();
        await Future.wait(pending);
        await events();
      }
    }

    return (
      launch: launch,
      ready: ready.future,
      oldDone: oldDone.future,
      drain: drain,
    );
  }

  test(
    'sole cancelled loader hands its registered card to the janitor',
    () async {
      final s = scenario();
      s.launch.start();
      await delayed.entered.future;
      s.launch.cancel();
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      expect(real.transientVideos, isEmpty);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );

  test(
    'retry ready before old registration ack keeps card and real subtitle',
    () async {
      final s = scenario();
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      final retry = await s.ready;
      expect(retry.createdItemIds, isEmpty);
      expect(real.getVideo(retry.item.id), same(retry.item));
      final subtitle = File('${root.path}/owned-retry.srt');
      await subtitle.writeAsString('successful retry subtitle');
      retry.item.subtitlePath = subtitle.path;
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      expect(real.getVideo(retry.item.id), same(retry.item));
      expect(await subtitle.readAsString(), 'successful retry subtitle');
      expect(
        BilibiliHistoryService.instance.watchHistory,
        isEmpty,
        reason: 'a launch alone must not record an opened page',
      );
    },
  );

  test(
    'old cancellation finishing before retry ready keeps created ids for retry',
    () async {
      final retryInfo = Completer<BilibiliVideoInfo>();
      final s = scenario(retryInfo: retryInfo);
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      expect(
        real.transientVideos,
        hasLength(1),
        reason: 'the old plan is held while retry still prepares',
      );
      retryInfo.complete(_info());
      final retry = await s.ready;
      await s.drain();
      expect(real.getVideo(retry.item.id), same(retry.item));
    },
  );

  test(
    'both attempts cancelled release the creator card after pending retry exits',
    () async {
      final retryInfo = Completer<BilibiliVideoInfo>();
      final s = scenario(retryInfo: retryInfo);
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      delayed.release.complete();
      await s.oldDone;
      await events();
      s.launch.cancel();
      retryInfo.complete(_info());
      await s.drain();
      expect(real.transientVideos, isEmpty);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );

  test(
    'ready retry abandoned before old ack still releases original creator ownership',
    () async {
      final s = scenario();
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      await s.ready;
      s.launch.discardReady();
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      expect(real.transientVideos, isEmpty);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );

  test(
    'retry owns all reused multipart entries after the old creator cancels',
    () async {
      final s = scenario(parts: 3);
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      final retry = await s.ready;
      expect(retry.queue, hasLength(3));
      final subtitle = File('${root.path}/multipart-retry.srt');
      await subtitle.writeAsString('multipart retry subtitle');
      retry.item.subtitlePath = subtitle.path;
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      for (final item in retry.queue!) {
        expect(real.getVideo(item.id), same(item));
      }
      expect(await subtitle.readAsString(), 'multipart retry subtitle');
    },
  );

  test(
    'abandoned multipart retry releases old and new creator entries',
    () async {
      final s = scenario(parts: 3);
      s.launch.start();
      await delayed.entered.future;
      s.launch.retry();
      final retry = await s.ready;
      expect(retry.queue, hasLength(3));
      expect(retry.createdItemIds, hasLength(2));
      s.launch.discardReady();
      delayed.release.complete();
      await s.oldDone;
      await s.drain();
      expect(real.transientVideos, isEmpty);
    },
  );

  test(
    'direct preparation keeps the original throwing cancellation contract',
    () async {
      var cancelled = false;
      final pending = prepareBilibiliWatch(
        service: service,
        library: delayed,
        bvid: 'BV1xx411c7mD',
        loadInfo: (_) async => _info(),
        deferPlayerData: true,
        isCancelled: () => cancelled,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<BilibiliWatchCancelledException>()),
      );
      await delayed.entered.future;
      cancelled = true;
      delayed.release.complete();
      await assertion;
      expect(real.transientVideos, isEmpty);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );

  test(
    'cancellation before metadata completes creates no card or history',
    () async {
      var cancelled = false;
      final entered = Completer<void>(),
          metadata = Completer<BilibiliVideoInfo>();
      final pending = prepareBilibiliWatch(
        service: service,
        library: delayed,
        bvid: 'BV1xx411c7mD',
        loadInfo: (_) {
          entered.complete();
          return metadata.future;
        },
        deferPlayerData: true,
        isCancelled: () => cancelled,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<BilibiliWatchCancelledException>()),
      );
      await entered.future;
      cancelled = true;
      metadata.complete(_info());
      await assertion;
      expect(delayed.entered.isCompleted, isFalse);
      expect(real.transientVideos, isEmpty);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    },
  );
  test(
    'late owner cancellation never records history or reports it written',
    () async {
      var cancelled = false, wroteHistory = false;
      final pending = prepareBilibiliWatch(
        service: service,
        library: delayed,
        bvid: 'BV1xx411c7mD',
        loadInfo: (_) async => _info(),
        deferPlayerData: true,
        isCancelled: () => cancelled,
        returnPlanOnLateCancellation: true,
        onStep: (step) {
          if (step == 'card ready') cancelled = true;
          if (step == 'history written') wroteHistory = true;
        },
      );
      await delayed.entered.future;
      delayed.release.complete();
      final abandoned = await pending;
      expect(abandoned.createdItemIds, contains(abandoned.item.id));
      expect(real.getVideo(abandoned.item.id), same(abandoned.item));
      expect(abandoned.historyEntry, isNull);
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
      expect(wroteHistory, isFalse);
      await discardAbandonedWatch(abandoned, library: real);
      expect(real.transientVideos, isEmpty);
    },
  );
}
