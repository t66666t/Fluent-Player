import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'media_cache_service_test.dart' show FakeBackend, source, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeBackend backend;
  late MediaCacheService service;
  late File journal;
  late List<CacheVariant> variants;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('card-index-');
    backend = FakeBackend(root);
    journal = File('${root.path}/media_cache.json');
    variants = [];
    for (final id in ['one', 'two']) {
      final file = await File(
        '${root.path}/$id.mp4',
      ).writeAsBytes([1, 2, 3, 4]);
      variants.add(
        CacheVariant(
          source: source(id),
          quality: const CacheQuality(id: '720', label: '720P'),
          path: file.path,
          bytes: 4,
          createdAt: 1,
        ),
      );
    }
    await journal.writeAsString(
      jsonEncode({
        'version': 1,
        'tasks': [
          CacheTask(
            id: 'queued',
            source: source('three'),
            createdAt: 1,
          ).toJson(),
        ],
        'variants': variants.map((v) => v.toJson()).toList(),
      }),
    );
    service = MediaCacheService(
      backend: backend,
      journal: journal,
      observeNetwork: false,
    );
  });
  tearDown(() async {
    service.dispose();
    await root.delete(recursive: true);
  });

  test(
    'card preparation reads only local state without activating or rewriting tasks',
    () async {
      final before = await journal.readAsString();
      final state = service.cardStateFor(source());
      await service.prepareCardStates([source()]);
      expect(state.value.ready, true);
      expect(state.value.hasCache, true);
      expect(service.ready, false);
      expect(service.tasks, isEmpty);
      expect(backend.calls, 0);
      expect(await journal.readAsString(), before);
      await File(variants.first.path).delete();
      await service.refreshAvailability(mediaKey: source().key);
      expect(state.value.hasCache, false);
      expect(service.ready, false);
      expect(await journal.readAsString(), before);
    },
  );

  test('a completion record cannot hide a missing or truncated file', () async {
    await File(variants.first.path).writeAsBytes([1]);
    final state = service.cardStateFor(source());
    await service.prepareCardStates([source()]);
    expect(state.value.ready, true);
    expect(state.value.hasCache, false);
    expect(await File(variants.last.path).exists(), true);
  });

  test('changes to one media do not notify a different mounted card', () async {
    await service.initialize();
    final one = service.cardStateFor(source());
    final two = service.cardStateFor(source('two'));
    await service.prepareCardStates([source(), source('two')]);
    var oneChanges = 0, twoChanges = 0;
    one.addListener(() => oneChanges++);
    two.addListener(() => twoChanges++);
    await service.deleteVariant(variants.first.id);
    expect(one.value.hasCache, false);
    expect(two.value.hasCache, true);
    expect(oneChanges, greaterThan(0));
    expect(twoChanges, 0);
    await service.shutdown();
  });

  test(
    'malformed records are preserved and do not block card presentation',
    () async {
      await journal.writeAsString('broken');
      final state = service.cardStateFor(source());
      await service.prepareCardStates([source()]);
      expect(state.value.ready, true);
      expect(state.value.hasCache, false);
      expect(await journal.readAsString(), 'broken');
      expect(service.ready, false);
    },
  );

  test('an invalidated registered file stays unavailable after unrelated progress', () async {
    await service.initialize();
    final state = service.cardStateFor(source());
    await service.prepareCardStates([source()]);
    await File(variants.first.path).writeAsBytes([1]);
    await service.prepareCardStates([source()]);
    expect(state.value.hasCache, false);
    service.notifyListeners();
    expect(state.value.hasCache, false);
    await service.shutdown();
  });

  test('read-only discovered material survives notifications and follows explicit deletion', () async {
    final previous = MediaCacheHooks.discover;
    final extra = source('external');
    final file = await File('${root.path}/external.mp4').writeAsBytes([1, 2, 3, 4]);
    MediaCacheHooks.discover = (candidate) async => candidate.key == extra.key
        ? [CacheVariant(source: extra, quality: const CacheQuality(id: '720', label: '720P'),
            path: file.path, bytes: 4, createdAt: 1)] : [];
    try {
      await service.initialize();
      final state = service.cardStateFor(extra);
      await service.prepareCardStates([extra]);
      expect(state.value.hasCache, true);
      service.notifyListeners();
      expect(state.value.hasCache, true);
      await file.delete();
      await service.forgetDeletedFiles([file.path]);
      expect(state.value.hasCache, false);
      await service.shutdown();
    } finally { MediaCacheHooks.discover = previous; }
  });
  test('repeated card checks retain watches and follow changed discovery paths', () async {
    final previous = MediaCacheHooks.discover;
    final extra = source('watched-external');
    final first = await File('${root.path}/first/external.mp4')
        .create(recursive: true);
    final second = await File('${root.path}/second/external.mp4')
        .create(recursive: true);
    await first.writeAsBytes([1, 2, 3, 4]);
    await second.writeAsBytes([1, 2, 3, 4]);
    var current = first;
    MediaCacheHooks.discover = (candidate) async => candidate.key == extra.key
        ? [CacheVariant(
            source: extra,
            quality: const CacheQuality(id: '720', label: '720P'),
            path: current.path,
            bytes: 4,
            createdAt: 1,
          )]
        : [];
    final state = service.cardStateFor(extra);
    final stop = service.observeMediaAvailability(extra.key);
    try {
      for (var i = 0; i < 12; i++) {
        await service.prepareCardStates([extra]);
        expect(state.value.hasCache, true);
      }
      // New discovery can move to a different directory while the card stays
      // mounted. The new native watcher must exist before preparation returns.
      current = second;
      await service.prepareCardStates([extra]);
      await first.delete();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(state.value.hasCache, true);
      await second.delete();
      await until(() => !state.value.hasCache);
      expect(service.ready, false);
      expect(backend.calls, 0);
    } finally {
      stop();
      MediaCacheHooks.discover = previous;
    }
  });

}
