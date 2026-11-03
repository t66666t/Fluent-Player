import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_playback_service.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

// The provider is a local fixture. The service, gateway, HTTP Range reads,
// libmpv decoding and media-session command handlers are the production paths.
class _Cloud extends Fake implements CloudDrivePlaybackService {
  _Cloud(this.gateway);
  @override
  final CloudDriveStreamGateway gateway;
  CloudDriveTransport transport = CloudDriveTransport.hls;
  @override
  Future<CloudDrivePreparedPlayback> open(
    VideoItem item, {
    String? qualityId,
    bool refresh = false,
    DateTime? operationDeadline,
    Object? cancelToken,
  }) async {
    final source = item.sourceRef!.cloudDrive!;
    final hls = transport == CloudDriveTransport.hls;
    final quality = CloudDriveQualityChoice(
      id: hls ? '720' : 'original',
      label: 'fixture',
      transcoded: hls,
      complete: true,
    );
    final lease = await gateway.open(
      accountLocalId: 'fixture',
      descriptor: CloudDrivePlaybackDescriptor(
        upstreamUri: Uri.parse(
          'https://pan.baidu.com/${hls ? 'index.m3u8' : 'muxed.mp4'}',
        ),
        transport: transport,
        quality: quality,
        fileId: source.fileId,
        revision: source.revision!,
        complete: true,
        seekable: true,
        userAgent: 'fixture',
        referer: 'https://pan.baidu.com/',
        cookies: [],
        providerId: source.providerId,
        accountLocalId: 'fixture',
        remoteAccountId: source.remoteAccountId,
        driveId: source.driveId,
        pathHint: source.pathHint,
        qualities: [quality],
      ),
    );
    return CloudDrivePreparedPlayback(
      lease: lease,
      qualities: [quality],
      selectedQualityId: quality.id,
      transcoded: hls,
      notice: '',
      mediaKind: CloudDriveMediaKind.video,
      playbackSessionId: item.id,
      durationMs: 21000,
    );
  }

  @override
  Future<List<CloudDriveCachedSubtitle>> loadSubtitles(VideoItem item) async =>
      [];
  @override
  String? get subtitleDiscoveryNote => null;
}

class _Upstream implements CloudDriveUpstreamClient {
  _Upstream(this.origin);
  final Uri origin;
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  @override
  Future<CloudDriveUpstreamResponse> open(
    CloudDriveUpstreamRequest request,
  ) async {
    final http = await client.openUrl(
      request.method,
      origin.resolve(request.uri.path),
    );
    request.headers.forEach(http.headers.set);
    final response = await http.close();
    return CloudDriveUpstreamResponse(
      statusCode: response.statusCode,
      headers: {
        for (final name in [
          HttpHeaders.contentTypeHeader,
          HttpHeaders.contentLengthHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.acceptRangesHeader,
        ])
          if (response.headers.value(name) != null)
            name: response.headers.value(name)!,
      },
      body: response,
      effectiveUri: request.uri,
      close: () async {},
    );
  }
}

class _Bili extends BilibiliApiService {
  _Bili(this.origin);
  final Uri origin;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async =>
      BilibiliStreamInfo(
        durationMs: 21000,
        qualityMap: {80: '1080P'},
        videoStreams: [
          StreamItem(
            id: 80,
            baseUrl: origin.resolve('video.mp4').toString(),
            bandwidth: 200000,
            codecs: 'avc1.640028',
            codecid: 7,
            mimeType: 'video/mp4',
            width: 320,
            height: 180,
            initializationRange: '0-999',
            indexRange: '1000-1999',
          ),
        ],
        audioStreams: [
          StreamItem(
            id: 30280,
            baseUrl: origin.resolve('audio.m4a').toString(),
            bandwidth: 128000,
            codecs: 'mp4a.40.2',
            codecid: 0,
            mimeType: 'audio/mp4',
            initializationRange: '0-999',
            indexRange: '1000-1999',
          ),
        ],
      );
}

VideoItem _item(String source, String id, Uri origin, int cid) {
  final cloud = source.startsWith('cloud')
      ? CloudDriveSourceRef(
          providerId: 'baidu',
          remoteAccountId: 'fixture',
          driveId: '0',
          fileId: id,
          revision: 'fixture',
          pathHint: '/$id.mp4',
        )
      : null;
  final podcast = source.startsWith('podcast');
  final path =
      cloud?.logicalUri ??
      (podcast ? 'podcast:$id' : 'bilibili://stream/BV1xx411c7mD?cid=$cid');
  return VideoItem(
    id: id,
    path: path,
    title: source,
    durationMs: 21000,
    lastUpdated: 0,
    lastPositionMs: 4537,
    type: source == 'podcast-audio' ? MediaType.audio : MediaType.video,
    sourceRef: MediaSourceRef(
      value: cloud?.logicalUri ?? (podcast ? path : 'BV1xx411c7mD'),
      kind: cloud != null
          ? MediaSourceKind.cloudDrive
          : podcast
          ? MediaSourceKind.podcastEpisode
          : MediaSourceKind.bilibiliStream,
      bvid: cloud == null && !podcast ? 'BV1xx411c7mD' : null,
      cid: cloud == null && !podcast ? cid : null,
      cloudDrive: cloud,
      podcast: podcast
          ? PodcastEpisodeRef(
              channelId: 'fixture',
              episodeId: id,
              feedUrl: 'https://podcast.invalid/rss',
              mediaUrl: origin
                  .resolve(
                    source == 'podcast-audio' ? 'audio.m4a' : 'muxed.mp4',
                  )
                  .toString(),
            )
          : null,
    ),
  );
}

Future<void> _pump(WidgetTester tester, Future<void> action) async {
  var done = false;
  Object? error;
  action.then(
    (_) => done = true,
    onError: (Object e, StackTrace _) {
      error = e;
      done = true;
    },
  );
  final watch = Stopwatch()..start();
  while (!done && watch.elapsed < const Duration(seconds: 32)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'Native startup must finish within its budget');
  if (error != null) throw error!;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'all online sources resume through page and background media commands',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('online-native-');
      final service = MediaPlaybackService.forTesting();
      final playlist = PlaylistManager();
      final settings = SettingsService();
      final wasAudioOnly = settings.bilibiliBackgroundAudioOnly;
      final wasAutoPlay = settings.autoPlayNextVideo;
      final wasHeadset = settings.enableHeadsetMediaControls;
      final oldResolver = PodcastPlaybackHooks.resolve;
      final report = <Map<String, Object?>>[];
      HttpServer? server;
      BilibiliStreamingService? streaming;
      CloudDriveStreamGateway? gateway;
      _Upstream? upstream;
      try {
        final fixtures = <List<String>>[
          [
            '-f',
            'lavfi',
            '-i',
            'testsrc2=size=320x180:rate=30:duration=21',
            '-c:v',
            'libx264',
            '-g',
            '90',
            '-pix_fmt',
            'yuv420p',
            '-an',
            '-movflags',
            '+faststart',
            '${root.path}/video.mp4',
          ],
          [
            '-f',
            'lavfi',
            '-i',
            'anullsrc=r=48000:cl=stereo',
            '-t',
            '21',
            '-c:a',
            'aac',
            '-vn',
            '${root.path}/audio.m4a',
          ],
          [
            '-i',
            '${root.path}/video.mp4',
            '-i',
            '${root.path}/audio.m4a',
            '-c',
            'copy',
            '-movflags',
            '+faststart',
            '${root.path}/muxed.mp4',
          ],
          [
            '-i',
            '${root.path}/muxed.mp4',
            '-c',
            'copy',
            '-hls_time',
            '3',
            '-hls_list_size',
            '0',
            '-hls_segment_filename',
            '${root.path}/part%03d.ts',
            '${root.path}/index.m3u8',
          ],
        ];
        for (final args in fixtures) {
          final result = await Process.run('ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            '-y',
            ...args,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          try {
            final name = request.uri.pathSegments.last;
            if (!RegExp(
              r'^(video\.mp4|audio\.m4a|muxed\.mp4|index\.m3u8|part\d+\.ts)$',
            ).hasMatch(name)) {
              request.response.statusCode = 404;
            } else {
              final bytes = await File('${root.path}/$name').readAsBytes();
              final range = RegExp(
                r'bytes=(\d+)-(\d*)',
              ).firstMatch(request.headers.value('range') ?? '');
              final start = range == null ? 0 : int.parse(range[1]!);
              final end = range == null || range[2]!.isEmpty
                  ? bytes.length - 1
                  : int.parse(range[2]!).clamp(start, bytes.length - 1);
              request.response.headers.set('accept-ranges', 'bytes');
              request.response.headers.set(
                'content-type',
                name.endsWith('m3u8')
                    ? 'application/vnd.apple.mpegurl'
                    : name.endsWith('.ts')
                    ? 'video/mp2t'
                    : name.endsWith('m4a')
                    ? 'audio/mp4'
                    : 'video/mp4',
              );
              request.response.statusCode = range == null ? 200 : 206;
              if (range != null) {
                request.response.headers.set(
                  'content-range',
                  'bytes $start-$end/${bytes.length}',
                );
              }
              request.response.contentLength = end - start + 1;
              if (request.method != 'HEAD') {
                request.response.add(bytes.sublist(start, end + 1));
              }
            }
            await request.response.close();
          } catch (_) {
            try {
              await request.response.close();
            } catch (_) {}
          }
        });
        final origin = Uri.parse('http://127.0.0.1:${server.port}/');
        streaming = BilibiliStreamingService(
          _Bili(origin),
          cacheDirectory: Directory('${root.path}/cache'),
          mediaUriValidator: (uri) =>
              uri.host == origin.host && uri.port == origin.port,
        );
        upstream = _Upstream(origin);
        gateway = CloudDriveStreamGateway(upstream: upstream);
        final cloud = _Cloud(gateway);
        service.attachCloudDrivePlayback(cloud);
        await service.initialize(
          playlistManager: playlist,
          bilibiliStreamingService: streaming,
          progressTracker: ProgressTracker(
            playbackStateStore: PlaybackStateStore(
              directoryProvider: () async => root,
            ),
          ),
        );
        PodcastPlaybackHooks.resolve = (item) async =>
            Uri.parse(item.sourceRef!.podcast!.mediaUrl);
        settings.autoPlayNextVideo = true;
        settings.enableHeadsetMediaControls = true;
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final handler = createSystemMediaHandlerForTesting(
          playbackService: service,
          playlistManager: playlist,
        );
        for (final source in [
          'bilibili',
          'bilibili-audio-only',
          'cloud-hls',
          'cloud-original',
          'podcast-audio',
          'podcast-video',
        ]) {
          settings.bilibiliBackgroundAudioOnly =
              source == 'bilibili-audio-only';
          cloud.transport = source == 'cloud-original'
              ? CloudDriveTransport.progressive
              : CloudDriveTransport.hls;
          for (final entry in [
            'page-next',
            'page-previous',
            'remote-next',
            'remote-previous',
          ]) {
            final items = [
              _item(source, '$source-a', origin, 101),
              _item(source, '$source-b', origin, 102),
            ];
            final backwards = entry.endsWith('previous');
            final first = backwards ? items.last : items.first;
            final target = backwards ? items.first : items.last;
            playlist.setPlaylist(items);
            service.setAppForegroundState(false);
            await _pump(tester, service.play(first, autoPlay: false));
            expect(
              service.state,
              PlaybackState.paused,
              reason: '$source initial prepare',
            );
            var checks = 0;
            final frameRecovery = entry == 'remote-previous';
            final clockRecovery = entry == 'remote-next';
            service.debugOnlineStartupReadiness = frameRecovery
                ? (controller, startup, needsVideo) {
                    expectSync(needsVideo, isFalse);
                    if (++checks == 1) {
                      // Some ordinary demuxers already needed this initial
                      // correction. Recovery must work with it spent either way.
                      startup.claimPositionCorrection();
                      return Completer<void>().future;
                    }
                    return NativeVideoPlayerMediaKit.preparedForPlayback(
                      controller.playerId,
                      startup,
                      videoRequired: () => false,
                    )!;
                  }
                : null;
            service.debugOnlineStartupClock = clockRecovery
                ? (controller, startup) async {
                    if (++checks == 1) {
                      await controller.pause();
                      await controller.seekTo(startup.target);
                      return Completer<void>().future;
                    }
                    final baseline =
                        await NativeVideoPlayerMediaKit.transportPositionFor(
                          controller.playerId,
                        );
                    await NativeVideoPlayerMediaKit.clockStartedFor(
                      controller.playerId,
                      startup,
                      baseline!,
                      shouldWait: () =>
                          startup.isPending && startup.desiredPlaying,
                    );
                  }
                : null;
            final watch = Stopwatch()..start();
            await _pump(tester, switch (entry) {
              'page-next' => service.playNext(),
              'page-previous' => service.playPrevious(),
              'remote-next' => handler.skipToNext(),
              _ => handler.skipToPrevious(),
            });
            final startup = service.onlineStartupForTesting!;
            expect(service.currentItem?.id, target.id);
            expect(
              service.state,
              PlaybackState.playing,
              reason: '$source $entry ${startup.marks}',
            );
            expect(startup.isReady, isTrue);
            final controller = service.controller!;
            final before = await NativeVideoPlayerMediaKit.transportPositionFor(
              controller.playerId,
            );
            expect(before!.inMilliseconds, inInclusiveRange(4400, 7000));
            for (var tick = 0; tick < 10; tick++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final after = await NativeVideoPlayerMediaKit.transportPositionFor(
              controller.playerId,
            );
            expect(
              after! - before,
              greaterThan(const Duration(milliseconds: 60)),
              reason: 'Real clock must advance',
            );
            expect(
              await NativeVideoPlayerMediaKit.transportPausedFor(
                controller.playerId,
              ),
              isFalse,
            );
            if (frameRecovery || clockRecovery) {
              expect(checks, 2);
              expect(
                startup.marks.where(
                  (m) =>
                      m.step ==
                      (frameRecovery
                          ? 'resume frame recovery seek'
                          : 'startup clock recovery seek'),
                ),
                hasLength(1),
              );
            }
            report.add({
              'source': source,
              'entry': entry,
              'readyMs': watch.elapsedMilliseconds,
              'nativeBeforeMs': before.inMilliseconds,
              'nativeAfterMs': after.inMilliseconds,
              'stages': [
                for (final m in startup.marks) {'step': m.step, 'ms': m.ms},
              ],
            });
            service.debugOnlineStartupReadiness = null;
            service.debugOnlineStartupClock = null;
            await _pump(tester, service.stop());
          }
          final pausedItem = _item(source, '$source-paused', origin, 103);
          await _pump(tester, service.play(pausedItem, autoPlay: false));
          final original = service.controller!;
          var clockChecks = 0;
          service.debugOnlineStartupClock = (controller, startup) async {
            if (++clockChecks == 1) {
              await controller.pause();
              await controller.seekTo(startup.target);
              return Completer<void>().future;
            }
            final baseline =
                await NativeVideoPlayerMediaKit.transportPositionFor(
                  controller.playerId,
                );
            await NativeVideoPlayerMediaKit.clockStartedFor(
              controller.playerId,
              startup,
              baseline!,
              shouldWait: () => startup.isPending && startup.desiredPlaying,
            );
          };
          final resuming = Stopwatch()..start();
          await _pump(tester, handler.play());
          expect(service.controller, same(original));
          expect(
            service.state,
            PlaybackState.playing,
            reason: '$source resume ${service.onlineStartup!.marks}',
          );
          expect(clockChecks, 2);
          expect(
            service.onlineStartup!.marks.where(
              (m) => m.step == 'startup clock recovery seek',
            ),
            hasLength(1),
          );
          report.add({
            'source': source,
            'entry': 'remote-play-paused',
            'readyMs': resuming.elapsedMilliseconds,
            'sameController': true,
            'stages': [
              for (final m in service.onlineStartup!.marks)
                {'step': m.step, 'ms': m.ms},
            ],
          });
          service.debugOnlineStartupClock = null;
          await _pump(tester, service.stop());
        }
        final destination = Platform.environment['ONLINE_STARTUP_REPORT'];
        if (destination != null) {
          await File(
            destination,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        }
        debugPrint('ONLINE_STARTUP_NATIVE_RESULT ${jsonEncode(report)}');
      } finally {
        service.debugOnlineStartupReadiness = null;
        service.debugOnlineStartupClock = null;
        service.setAppForegroundState(true);
        await service.stop();
        await streaming?.shutdown();
        await gateway?.close();
        upstream?.client.close(force: true);
        await server?.close(force: true);
        PodcastPlaybackHooks.resolve = oldResolver;
        settings.bilibiliBackgroundAudioOnly = wasAudioOnly;
        settings.autoPlayNextVideo = wasAutoPlay;
        settings.enableHeadsetMediaControls = wasHeadset;
        await tester.pumpWidget(const SizedBox());
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
