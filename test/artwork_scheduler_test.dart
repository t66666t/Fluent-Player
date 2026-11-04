import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

ArtworkFetchResponse _pngResponse(Uri uri) => ArtworkFetchResponse(
  status: 200,
  headers: const {'cache-control': 'max-age=3600', 'content-type': 'image/png'},
  bytes: base64Decode(_png),
  finalUri: uri,
);

void main() {
  test('visible work starts before an older prefetch when a slot frees', () async {
    final gates = <String, Completer<ArtworkFetchResponse>>{};
    final root = await Directory.systemTemp.createTemp('artwork-priority-');
    final repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) {
        final gate = Completer<ArtworkFetchResponse>();
        gates[request.uri.path] = gate;
        return gate.future;
      },
    );
    addTearDown(() async {
      for (final gate in gates.values) {
        if (!gate.isCompleted) {
          gate.complete(_pngResponse(Uri.parse('https://example.test/done')));
        }
      }
      repository.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    ArtworkRef ref(String host, String name) => ArtworkRef(
      ownerKind: 'episode',
      ownerId: name,
      primary: ArtworkRequest(
        url: 'https://$host/$name.png',
        adapter: ArtworkAdapter.podcast,
      ),
    );

    final blockers = [
      for (var index = 0; index < 4; index++)
        repository.load(
          ref('blocked$index.example', 'prefetch-$index'),
          priority: ArtworkPriority.prefetch,
        ),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.activeArtworkFetches, 4);

    final older = repository.load(
      ref('blocked.example', 'older-prefetch'),
      priority: ArtworkPriority.prefetch,
    );
    final visible = repository.load(
      ref('visible.example', 'current'),
      priority: ArtworkPriority.visible,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gates.containsKey('/current.png'), isFalse);

    gates['/prefetch-0.png']!.complete(
      _pngResponse(Uri.parse('https://blocked.example/prefetch-0.png')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(gates.containsKey('/current.png'), isTrue);
    expect(gates.containsKey('/older-prefetch.png'), isFalse);
    expect(repository.activeArtworkFetches, lessThanOrEqualTo(4));

    final pending = Future.wait([...blockers, older, visible]);
    for (var round = 0; round < 8; round++) {
      for (final gate in List<Completer<ArtworkFetchResponse>>.of(gates.values)) {
        if (!gate.isCompleted) {
          gate.complete(_pngResponse(Uri.parse('https://example.test/done')));
        }
      }
      try {
        await pending.timeout(const Duration(milliseconds: 100));
        break;
      } on TimeoutException {
        // A newly started request registers its gate after the previous round.
      }
    }
    await pending.timeout(const Duration(seconds: 2));
  });

  test('a busy host does not hold global slots needed by another host', () async {
    var release = false;
    final root = await Directory.systemTemp.createTemp('artwork-host-');
    final repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) async {
        while (!release) {
          if (request.cancelled()) throw const ArtworkReject('cancelled');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return _pngResponse(request.uri);
      },
    );
    addTearDown(() async {
      release = true;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      repository.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    ArtworkRef ref(String host, String name) => ArtworkRef(
      ownerKind: 'episode',
      ownerId: name,
      primary: ArtworkRequest(
        url: 'https://$host/$name.png',
        adapter: ArtworkAdapter.podcast,
      ),
    );
    final waiting = <Future<ArtworkSnapshot>>[
      for (var index = 0; index < 4; index++)
        repository.load(ref('slow.example', 'a$index')),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.artworkFetchesForHost('slow.example'), 2);
    expect(repository.activeArtworkFetches, 2);
    final other = repository.load(ref('fast.example', 'b0'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.artworkFetchesForHost('fast.example'), 1);
    expect(repository.activeArtworkFetches, 3);
    expect(repository.artworkFetchesForHost('slow.example'), lessThanOrEqualTo(2));
    release = true;
    await Future.wait([...waiting, other]);
  });

  test('cancelling one watcher keeps a shared download and does not cool down', () async {
    final calls = <String>[];
    final root = await Directory.systemTemp.createTemp('artwork-cancel-');
    final repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) async {
        calls.add(request.uri.path);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (request.cancelled()) throw const ArtworkReject('cancelled');
        return _pngResponse(request.uri);
      },
    );
    addTearDown(() async {
      repository.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final ref = ArtworkRef(
      ownerKind: 'episode',
      ownerId: 'shared',
      primary: const ArtworkRequest(
        url: 'https://cdn.example/shared.png',
        adapter: ArtworkAdapter.podcast,
      ),
    );
    final first = repository.watch(ref).listen((_) {});
    final secondEvents = <ArtworkSnapshot>[];
    final second = repository.watch(ref).listen(secondEvents.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await first.cancel();
    for (var attempt = 0; attempt < 40 && !secondEvents.any((event) => event.hasImage); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(secondEvents.any((event) => event.hasImage), isTrue);
    expect(calls, ['/shared.png']);
    await second.cancel();

    final cancelled = ArtworkRef(
      ownerKind: 'episode',
      ownerId: 'once',
      primary: const ArtworkRequest(
        url: 'https://cdn.example/once.png',
        adapter: ArtworkAdapter.podcast,
      ),
    );
    final hanging = repository.watch(cancelled).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await hanging.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final again = await repository.load(cancelled);
    expect(again.hasImage, isTrue);
    expect(calls.where((path) => path == '/once.png').length, 2);
  });

  test('a cached channel image is shown before a slow episode image', () async {
    final gates = <String, Completer<ArtworkFetchResponse>>{};
    final root = await Directory.systemTemp.createTemp('artwork-fallback-');
    final repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) {
        if (request.uri.path == '/episode.png') {
          final gate = Completer<ArtworkFetchResponse>();
          gates[request.uri.path] = gate;
          return gate.future;
        }
        return Future<ArtworkFetchResponse>.value(_pngResponse(request.uri));
      },
    );
    addTearDown(() async {
      final gate = gates['/episode.png'];
      if (gate != null && !gate.isCompleted) {
        gate.complete(_pngResponse(Uri.parse('https://cdn.example/episode.png')));
      }
      repository.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final channel = ArtworkRef(
      ownerKind: 'channel',
      ownerId: 'channel',
      primary: const ArtworkRequest(
        url: 'https://cdn.example/channel.png',
        adapter: ArtworkAdapter.podcast,
      ),
    );
    final warmed = await repository.load(channel);
    expect(warmed.hasImage, isTrue);
    final episode = ArtworkRef(
      ownerKind: 'episode',
      ownerId: 'episode',
      primary: const ArtworkRequest(
        url: 'https://cdn.example/episode.png',
        adapter: ArtworkAdapter.podcast,
      ),
      fallbacks: const [
        ArtworkRequest(
          url: 'https://cdn.example/channel.png',
          adapter: ArtworkAdapter.podcast,
        ),
      ],
    );
    final events = <ArtworkSnapshot>[];
    final subscription = repository.watch(episode).listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(events, isNotEmpty);
    expect(events.first.hasImage, isTrue);
    expect(events.first.requestKey, channel.primary!.requestKey);
    gates['/episode.png']!.complete(
      _pngResponse(Uri.parse('https://cdn.example/episode.png')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(events.last.requestKey, episode.primary!.requestKey);
    expect(events.last.hasImage, isTrue);
    await subscription.cancel();
  });
}
