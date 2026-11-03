import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_quality_outcome.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'baidu_auto_subtitle_test.dart'
    show cloudItem, memoryStore, track, srtBody;
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'support/cloud_drive_fixture.dart';

class CloudPlaybackFake extends Fake implements CloudDrivePlaybackService {
  final gatewayImpl = CloudDriveStreamGateway();
  CloudDrivePlaybackLease? lastLease;
  Completer<void>? resolveGate;
  CloudDriveTransport transport = CloudDriveTransport.hls;
  final qualities = [
    for (final id in ['original', '720', '1080'])
      CloudDriveQualityChoice(
        id: id,
        label: id,
        transcoded: id != 'original',
        complete: true,
      ),
  ];

  @override
  Future<CloudDrivePreparedPlayback> open(
    VideoItem item, {
    String? qualityId,
    bool refresh = false,
    DateTime? operationDeadline,
    Object? cancelToken,
  }) async {
    if (qualityId != null) await resolveGate?.future;
    final source = item.sourceRef!.cloudDrive!;
    final quality = qualities.firstWhere(
      (q) => q.id == (qualityId ?? 'original'),
    );
    final lease = await gatewayImpl.open(
      accountLocalId: 'local',
      descriptor: CloudDrivePlaybackDescriptor(
        upstreamUri: Uri.parse('https://pan.baidu.com/video.m3u8'),
        transport: transport,
        quality: quality,
        fileId: source.fileId,
        revision: source.revision!,
        complete: true,
        seekable: true,
        userAgent: 'test',
        referer: 'https://pan.baidu.com/',
        cookies: const [],
        providerId: source.providerId,
        accountLocalId: 'local',
        remoteAccountId: source.remoteAccountId,
        driveId: source.driveId,
        pathHint: source.pathHint,
        qualities: qualities,
      ),
    );
    lastLease = lease;
    return CloudDrivePreparedPlayback(
      lease: lease,
      qualities: qualities,
      selectedQualityId: quality.id,
      transcoded: quality.transcoded,
      notice: '',
      mediaKind: CloudDriveMediaKind.video,
      playbackSessionId: 'test',
      durationMs: 120000,
    );
  }

  @override
  Future<List<CloudDriveCachedSubtitle>> loadSubtitles(VideoItem item) async =>
      [];
  @override
  String? get subtitleDiscoveryNote => null;
}

/// Models a backend that does not publish a seek position until decoding starts.
class _CloudVideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final playing = <int, bool>{};
  final anchors = <int, DateTime>{};
  final volumes = <int, double>{};
  final pendingSeek = <int, Duration>{};
  final disposed = <int>[];
  final decodeReadyAt = <int, DateTime>{};
  Duration? replacementDecodeDelay;
  var automaticInit = false;
  var failNext = false;
  var nextId = 1;
  void Function(int id)? onPlay;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = nextId++;
    events[id] = StreamController<VideoEvent>();
    positions[id] = Duration.zero;
    anchors[id] = DateTime.now();
    if (id > 1 && replacementDecodeDelay != null) {
      decodeReadyAt[id] = DateTime.now().add(replacementDecodeDelay!);
    }
    if (automaticInit) scheduleMicrotask(() => initializePlayer(id));
    return id;
  }

  void initializePlayer(int id) {
    if (failNext) {
      failNext = false;
      events[id]!.addError(
        PlatformException(
          code: 'candidate_failed',
          message: 'candidate failed',
        ),
      );
    } else {
      events[id]!.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(1280, 720),
        ),
      );
    }
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<Duration> getPosition(int id) async {
    final readyAt = decodeReadyAt[id];
    final anchor = readyAt != null && readyAt.isAfter(anchors[id]!)
        ? readyAt
        : anchors[id]!;
    final elapsed = DateTime.now().difference(anchor);
    return (positions[id] ?? Duration.zero) +
        (playing[id] == true && !elapsed.isNegative ? elapsed : Duration.zero);
  }

  @override
  Future<void> play(int id) async {
    positions[id] = pendingSeek.remove(id) ?? await getPosition(id);
    anchors[id] = DateTime.now();
    playing[id] = true;
    onPlay?.call(id);
  }

  @override
  Future<void> pause(int id) async {
    positions[id] = await getPosition(id);
    anchors[id] = DateTime.now();
    playing[id] = false;
  }

  @override
  Future<void> seekTo(int id, Duration position) async {
    if (playing[id] != true && id > 1) {
      pendingSeek[id] = position;
    } else {
      positions[id] = position;
      anchors[id] = DateTime.now();
    }
  }

  @override
  Future<void> setVolume(int id, double volume) async => volumes[id] = volume;
  @override
  Future<void> setPlaybackSpeed(int id, double speed) async {}
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
    await events.remove(id)?.close();
  }

  @override
  Widget buildView(int id) => const SizedBox.shrink();
}

class CloudOfficialSubtitleFake implements CloudDriveSubtitleTrackSource {
  int calls = 0;
  int textCalls = 0;
  List<CloudDriveSubtitleTrack> officialTracks = [track('ai')];
  Completer<void>? textGate;
  @override
  int get generation => 1;
  @override
  Listenable? get loginChanges => null;
  @override
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(
    VideoItem item,
  ) async {
    calls++;
    return CloudDriveOfficialSubtitleDiscovery(
      status: CloudDriveOfficialSubtitleStatus.ready,
      tracks: officialTracks,
    );
  }

  @override
  Future<String> fetchText(
    VideoItem item,
    CloudDriveSubtitleTrack track,
  ) async {
    textCalls++;
    await textGate?.future;
    return srtBody;
  }
}

class _EmbeddedProbe extends EmbeddedSubtitleService {
  var calls = 0;
  @override
  Future<List<EmbeddedSubtitleTrack>> getEmbeddedSubtitles(
    String videoPath,
  ) async {
    calls++;
    throw StateError('a cloud URI reached the local probe');
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previousPlatform;
  late _CloudVideoPlatform platform;
  late MediaPlaybackService service;
  late LibraryService library;
  late PlaylistManager playlist;
  late CloudPlaybackFake cloud;
  late CloudOfficialSubtitleFake source;
  late _EmbeddedProbe embedded;
  late CloudDriveSubtitleTracks tracks;
  late Directory root;
  late VideoItem item;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    previousPlatform = VideoPlayerPlatform.instance;
    platform = _CloudVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    root = await Directory.systemTemp.createTemp('cloud_workflow');
    item = cloudItem()..usesManagedAssociatedSubtitles = false;
    source = CloudOfficialSubtitleFake();
    embedded = _EmbeddedProbe();
    tracks = CloudDriveSubtitleTracks(
      source: source,
      store: memoryStore({item.id: item}, root),
    );
    CloudDriveSubtitleTracks.overrideForTesting = tracks;
    cloud = CloudPlaybackFake();
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    playlist = PlaylistManager()..initialize(libraryService: library);
    service = MediaPlaybackService.forTesting();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker()..initialize(libraryService: library),
      libraryService: library,
      embeddedSubtitleService: embedded,
    );
    service.attachCloudDrivePlayback(cloud);
  });
  tearDown(() async {
    await service.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cloud.gatewayImpl.close();
    CloudDriveSubtitleTracks.overrideForTesting = null;
    tracks.dispose();
    library.resetLibraryForTesting();
    VideoPlayerPlatform.instance = previousPlatform;
    await root.delete(recursive: true);
  });

  Future<void> start() async {
    platform.automaticInit = true;
    await service.play(item);
    await _until(() => service.subtitles.isNotEmpty);
    await service.seekTo(const Duration(seconds: 24));
  }

  for (final type in [MediaType.video, MediaType.audio]) {
    test(
      '${type.name} playback and duration discovery never import a card',
      () async {
        item.type = type;
        await start();
        expect(service.controller!.value.isInitialized, isTrue);
        expect(service.controller!.value.isPlaying, isTrue);
        expect(item.durationMs, 120000);
        expect(service.subtitles.single.text, '自动字幕');
        expect(service.position.inSeconds, inInclusiveRange(23, 26));
        await service.persistCurrentProgress();
        await service.stop();
        expect(library.storageVideos, isEmpty);
        expect(library.getContents(null), isEmpty);
        expect(library.activityProjection.playbackHistoryMediaIds(), isEmpty);
      },
    );
  }

  test('failed cloud playback never imports a card', () async {
    platform.automaticInit = true;
    platform.failNext = true;
    await service.play(item, allowCloudDriveFallback: false);
    expect(service.state, PlaybackState.error);
    expect(library.storageVideos, isEmpty);
    expect(library.getContents(null), isEmpty);
  });

  test(
    'switching unimported episodes preserves session progress without import',
    () async {
      final next = await library.upsertCloudDriveCard(
        source: cloudDriveEntrySource(cloudEntry('next')),
        title: '下一集',
        persist: false,
      );
      tracks.dispose();
      tracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item, next.id: next}, root),
      );
      CloudDriveSubtitleTracks.overrideForTesting = tracks;
      playlist.setPlaylist([item, next], currentItemId: item.id);
      await start();
      await service.playNext();
      expect(service.currentItem, same(next));
      expect(service.controller!.value.isPlaying, isTrue);
      await service.playPrevious();
      expect(service.currentItem, same(item));
      expect(service.position.inSeconds, inInclusiveRange(23, 26));
      expect(library.storageVideos, isEmpty);
    },
  );

  test(
    'an imported cloud card retains its placement and playback state',
    () async {
      final folder = await library.createCollection('我的课程', null);
      item.title = '自定义课程名';
      item.lastPositionMs = 17000;
      final saved = await library.upsertCloudDriveCard(
        source: item.sourceRef!,
        title: item.title,
        libraryItemId: item.id,
        playbackItem: item,
        openedFromFolderId: folder.id,
        explicitPlacement: true,
      );
      final playlist = PlaylistManager()..initialize(libraryService: library);
      playlist.setPlaylist([saved], currentItemId: saved.id);
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker()..initialize(libraryService: library),
        libraryService: library,
        embeddedSubtitleService: embedded,
      );
      platform.automaticInit = true;
      await service.play(saved);
      expect(service.position.inSeconds, inInclusiveRange(16, 19));
      await service.seekTo(const Duration(seconds: 42));
      await service.persistCurrentProgress();
      expect(library.getVideo(saved.id), same(saved));
      expect(library.storageVideos.single, same(saved));
      expect(saved.title, '自定义课程名');
      expect(saved.parentId, folder.id);
      expect(saved.durationMs, 120000);
      expect(saved.lastPositionMs, inInclusiveRange(41000, 44000));
      expect(library.getContents(folder.id).single, same(saved));
    },
  );

  test(
    'the first new-media notification never includes the old transcript',
    () async {
      service.debugSeedCurrentItem(
        VideoItem(
          id: 'previous',
          path: 'previous.mp4',
          title: 'Previous',
          durationMs: 2000,
          lastUpdated: 0,
        ),
      );
      service.setSubtitleState(
        paths: ['previous.srt', 'previous-secondary.srt'],
        primary: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
            text: 'Previous transcript',
          ),
        ],
        secondary: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 2),
            text: 'Previous translation',
          ),
        ],
      );
      final gate = Completer<void>();
      service.beforeLibraryPlayback = (_) => gate.future;
      final leaked = <String>[];
      void observe() {
        if (service.currentItem?.id == item.id &&
            (service.subtitlePaths.isNotEmpty ||
                service.subtitles.isNotEmpty ||
                service.secondarySubtitles.isNotEmpty ||
                service.currentSubtitle != null)) {
          leaked.add('new media published with old subtitles');
        }
      }

      service.addListener(observe);
      final opening = service.play(item);
      try {
        expect(service.currentItem?.id, item.id);
        expect(service.subtitles, isEmpty);
        expect(service.secondarySubtitles, isEmpty);
        expect(service.subtitlePaths, isEmpty);
        expect(leaked, isEmpty);
      } finally {
        service.removeListener(observe);
        await service.cancelPendingPlay();
        gate.complete();
        await opening;
        service.beforeLibraryPlayback = null;
      }
    },
  );

  for (final provider in ['baidu', 'quark']) {
    for (final ai in [false, true]) {
      test(
        '$provider first playback applies slow ${ai ? 'AI' : 'ordinary'} subtitles after video is ready',
        () async {
          source.officialTracks = [track('official', ai: ai)];
          item = cloudItem(providerId: provider);
          tracks.dispose();
          tracks = CloudDriveSubtitleTracks(
            source: source,
            store: memoryStore({item.id: item}, root),
          );
          CloudDriveSubtitleTracks.overrideForTesting = tracks;
          source.textGate = Completer<void>();
          platform.automaticInit = true;
          await service.play(item);
          await _until(() => source.textCalls > 0);
          expect(service.controller!.value.isInitialized, isTrue);
          expect(service.subtitles, isEmpty);
          source.textGate!.complete();
          await _until(() => service.subtitles.isNotEmpty);
          expect(service.subtitles.single.text, '自动字幕');
          expect(service.secondarySubtitles, isEmpty);
          expect(service.subtitlePaths, hasLength(1));
          expect(source.calls, 1);
          expect(source.textCalls, 1);
          expect(item.managedSubtitleAssets.single.machineGenerated, ai);

          // Re-entering playback shares the saved official track, without a panel.
          final savedPath = service.subtitlePaths.single;
          await service.play(item);
          expect(service.subtitlePaths, [savedPath]);
          expect(source.calls, 1);
          expect(source.textCalls, 1);
        },
      );
    }
  }

  test(
    'first playback loads AI subtitles while native initialization is pending',
    () async {
      final opening = service.play(item);
      await _until(() => platform.events.isNotEmpty);
      await _until(() => service.subtitles.isNotEmpty);
      expect(service.controller?.value.isInitialized == true, isFalse);
      expect(embedded.calls, 0);
      expect(source.calls, 1);
      platform.initializePlayer(1);
      await opening;
      expect(service.subtitlePaths, hasLength(1));
    },
  );

  test(
    'HLS quality can switch both ways when paused seek feedback needs decoding',
    () async {
      await start();
      final subtitlePath = service.subtitlePaths.single;
      final first = await service.switchCloudDriveQualityOutcome('720');
      expect(
        first.result,
        CloudDriveQualitySwitchResult.committed,
        reason: first.toDiagnosticLine(),
      );
      expect(service.selectedCloudDriveQualityId, '720');
      expect(service.position.inSeconds, inInclusiveRange(23, 26));
      final second = await service.switchCloudDriveQualityOutcome('1080');
      expect(
        second.result,
        CloudDriveQualitySwitchResult.committed,
        reason: second.toDiagnosticLine(),
      );
      expect(service.selectedCloudDriveQualityId, '1080');
      expect(service.subtitlePaths, [subtitlePath]);
      expect(service.cloudDriveQualitySwitching, isFalse);
    },
  );

  test(
    'a seek during muted pre-roll commits at the new user position',
    () async {
      await start();
      Future<void>? seek;
      platform.onPlay = (id) {
        if (id == 2 && seek == null) {
          seek = service.seekTo(const Duration(seconds: 50));
        }
      };
      final outcome = await service.switchCloudDriveQualityOutcome('720');
      await seek;
      expect(
        outcome.result,
        CloudDriveQualitySwitchResult.committed,
        reason: outcome.toDiagnosticLine(),
      );
      expect(service.position.inSeconds, inInclusiveRange(49, 52));
    },
  );

  test('returning to an original holds the old clock while decoding', () async {
    await start();
    cloud.transport = CloudDriveTransport.progressive;
    var held = false;
    platform.onPlay = (id) {
      if (id == 2) {
        held = platform.playing[1] == false;
      }
    };
    final result = await service.switchCloudDriveQualityOutcome('720');
    expect(
      result.result,
      CloudDriveQualitySwitchResult.committed,
      reason: result.toDiagnosticLine(),
    );
    expect(held, isTrue);
    expect(service.controller!.value.isPlaying, isTrue);
    expect(service.position.inSeconds, inInclusiveRange(23, 26));
  });

  test('a failed original handoff resumes the held source', () async {
    await start();
    cloud.transport = CloudDriveTransport.progressive;
    final previous = service.controller;
    platform.onPlay = (id) {
      if (id == 2) throw StateError('decode failed');
    };
    final result = await service.switchCloudDriveQualityOutcome('720');
    expect(result.result, CloudDriveQualitySwitchResult.failed);
    expect(service.controller, same(previous));
    expect(previous!.value.isPlaying, isTrue);
    expect(service.cloudDriveQualitySwitching, isFalse);
  });

  test('a slow original can warm within the shared cloud deadline', () async {
    await start();
    cloud.transport = CloudDriveTransport.progressive;
    platform.replacementDecodeDelay = const Duration(milliseconds: 8400);
    final result = await service.switchCloudDriveQualityOutcome('720');
    expect(
      result.result,
      CloudDriveQualitySwitchResult.committed,
      reason: result.toDiagnosticLine(),
    );
    expect(service.controller!.value.isPlaying, isTrue);
    expect(service.position.inSeconds, inInclusiveRange(23, 26));
  });

  test('timeout diagnostics retain the failed operation detail', () async {
    await start();
    cloud.transport = CloudDriveTransport.progressive;
    platform.onPlay = (id) {
      if (id == 2) throw TimeoutException('candidate decoder stalled');
    };
    final result = await service.switchCloudDriveQualityOutcome('720');
    expect(result.result, CloudDriveQualitySwitchResult.failed);
    expect(result.toDiagnosticLine(), contains('candidate decoder stalled'));
  });

  for (final transport in [
    CloudDriveTransport.progressive,
    CloudDriveTransport.hls,
  ]) {
    test(
      'decoded ${transport.name} progress can outlive a stale buffering flag',
      () async {
        await start();
        cloud.transport = transport;
        platform.onPlay = (id) {
          if (id == 2) {
            platform.events[id]!.add(
              VideoEvent(eventType: VideoEventType.bufferingStart),
            );
          }
        };
        final result = await service.switchCloudDriveQualityOutcome('720');
        expect(
          result.result,
          CloudDriveQualitySwitchResult.committed,
          reason: result.toDiagnosticLine(),
        );
        expect(service.controller!.value.isPlaying, isTrue);
        expect(service.position.inSeconds, inInclusiveRange(23, 26));
      },
    );
  }

  test(
    'a superseded quality cannot replace the latest choice or its outcome',
    () async {
      await start();
      cloud.resolveGate = Completer<void>();
      final older = service.switchCloudDriveQualityOutcome('720');
      final latest = service.switchCloudDriveQualityOutcome('1080');
      cloud.resolveGate!.complete();
      final results = await Future.wait([older, latest]);
      expect(results[0].result, CloudDriveQualitySwitchResult.superseded);
      expect(results[1].result, CloudDriveQualitySwitchResult.committed);
      expect(service.selectedCloudDriveQualityId, '1080');
      expect(service.cloudDriveQualityOutcome?.requestedQualityId, '1080');
      expect(service.cloudDriveQualitySwitching, isFalse);
    },
  );

  test(
    'pause during source preparation stays paused after the quality commits',
    () async {
      await start();
      cloud.resolveGate = Completer<void>();
      final switching = service.switchCloudDriveQualityOutcome('720');
      await service.pause();
      cloud.resolveGate!.complete();
      expect((await switching).result, CloudDriveQualitySwitchResult.committed);
      expect(service.controller!.value.isPlaying, isFalse);
      expect(service.state, PlaybackState.paused);
    },
  );

  test(
    'candidate failure leaves the old controller and subtitles usable',
    () async {
      await start();
      final oldController = service.controller;
      final subtitlePath = service.subtitlePaths.single;
      platform.failNext = true;
      final outcome = await service.switchCloudDriveQualityOutcome('720');
      expect(outcome.result, CloudDriveQualitySwitchResult.failed);
      expect(service.controller, same(oldController));
      expect(service.controller!.value.isPlaying, isTrue);
      expect(service.subtitlePaths, [subtitlePath]);
      expect(service.selectedCloudDriveQualityId, 'original');
      expect(service.cloudDriveQualitySwitching, isFalse);
    },
  );
}
