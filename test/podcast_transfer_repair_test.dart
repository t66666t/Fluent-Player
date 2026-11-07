import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_transfer.dart';

void main() {
  test('window planner skips cached chunks and caps each request at 4 MiB', () {
    final windows = planPodcastWindows(
      total: 9 * podcastWindowChunkBytes + 10,
      present: {1, 2},
    );
    expect(windows.first.start, 0);
    expect(windows.first.endInclusive, podcastWindowChunkBytes - 1);
    expect(windows[1].start, 3 * podcastWindowChunkBytes);
    expect(windows[1].length, PodcastTransferPolicy.windowBytes);
  });

  test('slow source is noticed once and is not retried forever', () {
    final first = evaluatePodcastSlow(
      elapsedMs: 30000,
      recentUsefulBytes: 1000,
      recentElapsedMs: 60000,
      recoveries: 0,
      lastRecoveryMs: 0,
      nowMs: 60000,
      playbackBackpressure: false,
      hasMissingBytes: true,
    );
    expect(first.notice, isTrue);
    expect(first.recover, isTrue);
    final later = evaluatePodcastSlow(
      elapsedMs: 30000,
      recentUsefulBytes: 1000,
      recentElapsedMs: 60000,
      recoveries: 2,
      lastRecoveryMs: 60000,
      nowMs: 70000,
      playbackBackpressure: false,
      hasMissingBytes: true,
    );
    expect(later.recover, isFalse);
  });

  late Directory dir;
  late PodcastStore store;
  late PodcastMediaStore mediaStore;
  late PodcastController controller;
  late HttpServer server;
  late Completer<void> entered, release;
  final ports = <int>{};
  final starts = <int>[];
  var stall = true;
  var total = podcastChunkBytes + 100;
  setUp(() async {
    HttpOverrides.global = null;
    dir = await Directory.systemTemp.createTemp('podcast-repair-');
    store = PodcastStore(sqlite3.openInMemory());
    entered = Completer<void>();
    release = Completer<void>();
    ports.clear();
    starts.clear();
    stall = true;
    total = podcastChunkBytes + 100;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        ports.add(request.connectionInfo!.remotePort);
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = int.parse(range?[1] ?? '0');
        final end = min(total - 1, int.tryParse(range?[2] ?? '') ?? total - 1);
        starts.add(start);
        request.response.statusCode = 206;
        request.response.contentLength = end - start + 1;
        request.response.headers
          ..set('content-range', 'bytes $start-$end/$total')
          ..set('etag', '"stable"')
          ..set('content-type', 'audio/mpeg');
        request.response.add(Uint8List(min(1024, end - start + 1)));
        await request.response.flush();
        if (stall && request.uri.path == '/a.mp3' && start == 0) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        final rest = end - start + 1 - min(1024, end - start + 1);
        if (rest > 0) request.response.add(Uint8List(rest.toInt()));
        await request.response.close();
      } catch (_) {}
    });
    final client = PodcastClient(
      http: PodcastHttp(clientFactory: HttpClient.new),
    );
    mediaStore = PodcastMediaStore(root: dir, store: store, http: client.http);
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: mediaStore,
    )..connectivity = [ConnectivityResult.wifi];
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await controller.close();
    await server.close(force: true);
    store.close();
    await dir.delete(recursive: true);
  });

  PodcastEpisode episode(String id) {
    final value = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: id,
      channelId: 'c',
      title: id,
      media: [
        PodcastMedia(
          url: 'http://127.0.0.1:${server.port}/$id.mp3',
          mimeType: 'audio/mpeg',
          length: total,
        ),
      ],
    );
    store.write('episode', id, value.toJson(), channel: 'c');
    return value;
  }

  test('a free download slot is used while an earlier task is still blocked', () async {
    final a = episode('a');
    final b = episode('b');
    controller.enqueue(a);
    await entered.future.timeout(const Duration(seconds: 3));
    controller.enqueue(b);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(starts.where((start) => start == 0), hasLength(2));
    expect(
      controller.downloads.firstWhere((task) => task.episodeId == 'b').status,
      isNot(PodcastDownloadStatus.queued),
    );
  });

  test('the last AI consumer pauses and an earlier one does not', () async {
    stall = true;
    final a = episode('a');
    final firstCancel = Completer<void>();
    final secondCancel = Completer<void>();
    final first = controller.prepareLocalMedia(
      a,
      a.media.first,
      cancelSignal: firstCancel.future,
    );
    final firstDone = expectLater(first, throwsA(isA<HttpException>()));
    await entered.future.timeout(const Duration(seconds: 3));
    final second = controller.prepareLocalMedia(
      a,
      a.media.first,
      cancelSignal: secondCancel.future,
    );
    final secondDone = expectLater(second, throwsA(isA<HttpException>()));
    firstCancel.complete();
    await firstDone.timeout(const Duration(seconds: 2));
    expect(
      controller.downloads.single.status,
      PodcastDownloadStatus.downloading,
    );
    secondCancel.complete();
    await secondDone.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(controller.downloads.single.status, PodcastDownloadStatus.paused);
  });

  test('an 8 MiB download reuses connections and requests 4 MiB windows', () async {
    stall = false;
    total = 8 * podcastChunkBytes + 100;
    final a = episode('a');
    await controller.prepareLocalMedia(a, a.media.first);
    expect(starts.length, lessThan(8));
    expect(starts, contains(0));
    expect(starts, contains(4 * podcastChunkBytes));
    expect(ports.length, lessThan(starts.length));
    expect(ports.length, lessThanOrEqualTo(4));
    expect(mediaStore.isComplete(a.id, a.media.first.url), isTrue);
  });
}
