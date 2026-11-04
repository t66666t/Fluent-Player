import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_startup_poster.dart';

class _StartupApi extends BilibiliApiService {
  _StartupApi(this.origin);
  final Uri origin;
  int calls = 0;
  bool removed = false;
  int deniedCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    calls++;
    if (removed) {
      deniedCalls++;
      throw StateError('视频已下架');
    }
    return BilibiliStreamInfo(
      durationMs: 21000,
      qualityMap: const {80: '1080P'},
      videoStreams: [
        StreamItem(
          id: 80,
          baseUrl: origin.resolve('/video').toString(),
          backupUrls: [origin.resolve('/backup').toString()],
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
          baseUrl: origin.resolve('/audio').toString(),
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
}

Future<List<int>> _pixel(RenderRepaintBoundary boundary) async {
  final frame = await boundary.toImage(pixelRatio: 1);
  try {
    final pixels = (await frame.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final offset = ((frame.height ~/ 4) * frame.width + frame.width ~/ 4) * 4;
    return [
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    ];
  } finally {
    frame.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'native dual-track resume exposes only the target frame, paused or playing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'bilibili_native_startup_',
      );
      final service = MediaPlaybackService();
      final settings = SettingsService();
      final originalAudioOnly = settings.bilibiliBackgroundAudioOnly;
      final owner = Object();
      final longGop = Platform.environment['BILIBILI_STARTUP_LONG_GOP'] == '1';
      final resumePosition = Duration(
        milliseconds:
            int.tryParse(
              Platform.environment['BILIBILI_STARTUP_RESUME_MS'] ?? '',
            ) ??
            4000,
      );
      HttpServer? server;
      BilibiliStreamingService? streaming;
      final report = <Map<String, Object?>>[];
      try {
        final video = File('${root.path}/video.mp4');
        final audio = File('${root.path}/audio.m4a');
        final poster = File('${root.path}/poster.png');
        final jobs = <List<String>>[
          [
            '-f',
            'lavfi',
            '-i',
            'color=red:s=320x180:r=30:d=3',
            '-f',
            'lavfi',
            '-i',
            'color=blue:s=320x180:r=30:d=3',
            '-f',
            'lavfi',
            '-i',
            'color=green:s=320x180:r=30:d=15',
            '-filter_complex',
            '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]',
            '-map',
            '[v]',
            '-c:v',
            'libx264',
            '-g',
            longGop ? '900' : '30',
            if (longGop) ...['-keyint_min', '900', '-sc_threshold', '0'],
            '-pix_fmt',
            'yuv420p',
            '-an',
            '-movflags',
            '+frag_keyframe+empty_moov',
            video.path,
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
            audio.path,
          ],
          [
            '-f',
            'lavfi',
            '-i',
            'color=gray:s=320x180',
            '-frames:v',
            '1',
            poster.path,
          ],
        ];
        for (final job in jobs) {
          final encoded = await Process.run('ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            ...job,
          ]);
          expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
        }
        final videoBytes = await video.readAsBytes();
        final audioBytes = await audio.readAsBytes();
        var delayPrimary = false;
        var origins = 0;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          origins++;
          try {
            if (delayPrimary && request.uri.path == '/video') {
              await Future<void>.delayed(const Duration(seconds: 3));
            }
            final bytes = request.uri.path == '/audio'
                ? audioBytes
                : videoBytes;
            final range = RegExp(
              r'^bytes=(\d+)-(\d*)$',
            ).firstMatch(request.headers.value('range') ?? '');
            final start = range == null ? 0 : int.parse(range[1]!);
            final requestedEnd = range == null
                ? bytes.length - 1
                : int.tryParse(range[2]!) ?? bytes.length - 1;
            if (start >= bytes.length) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              request.response.headers.set(
                'content-range',
                'bytes */${bytes.length}',
              );
              await request.response.close();
              return;
            }
            final end = requestedEnd.clamp(start, bytes.length - 1);
            request.response.headers.set('accept-ranges', 'bytes');
            request.response.headers.set(
              'etag',
              '"${request.uri.path}-${bytes.length}"',
            );
            request.response.headers.contentType = ContentType(
              request.uri.path == '/audio' ? 'audio' : 'video',
              'mp4',
            );
            if (range != null) {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            request.response.contentLength = end - start + 1;
            if (request.method != 'HEAD') {
              request.response.add(bytes.sublist(start, end + 1));
            }
            await request.response.close();
          } catch (_) {}
        });
        final origin = Uri.parse('http://127.0.0.1:${server.port}');
        final api = _StartupApi(origin);
        streaming = BilibiliStreamingService(
          api,
          cacheDirectory: Directory('${root.path}/cache'),
          mediaUriValidator: (uri) =>
              uri.host == origin.host && uri.port == origin.port,
        );
        await service.initialize(
          playlistManager: PlaylistManager(),
          progressTracker: ProgressTracker(
            playbackStateStore: PlaybackStateStore(
              directoryProvider: () async => root,
            ),
          ),
          bilibiliStreamingService: streaming,
        );
        service.setPlaybackPageVisible(owner, true);
        final frameKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 640,
                  height: 360,
                  child: RepaintBoundary(
                    key: frameKey,
                    child: ListenableBuilder(
                      listenable: service,
                      builder: (context, _) {
                        final controller = service.controller;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Colors.black),
                            if (controller != null &&
                                service.hasMountableController)
                              VideoPlayer(controller),
                            BilibiliStartupPoster(
                              startup: service.bilibiliStartup,
                              thumbnailPath: poster.path,
                              covered: service.isCoveringUntilVisibleVideoFrame,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        for (final mode in [
          'cold-paused',
          'cached-playing',
          'parked-playing',
          'parked-paused',
          'slow-primary',
        ]) {
          delayPrimary = mode == 'slow-primary';
          final id = delayPrimary ? 'native-slow' : 'native-resume';
          final item = VideoItem(
            id: id,
            path: 'bilibili://stream/BV1xx411c7mD?cid=1',
            title: mode,
            durationMs: 21000,
            lastPositionMs: resumePosition.inMilliseconds,
            lastUpdated: 0,
            thumbnailPath: poster.path,
            sourceRef: const MediaSourceRef(
              value: 'BV1xx411c7mD',
              kind: MediaSourceKind.bilibiliStream,
              bvid: 'BV1xx411c7mD',
              cid: 1,
            ),
          );
          var done = false;
          final pixels = <List<int>>[];
          final watch = Stopwatch()..start();
          final previousOrigins = origins;
          final playing = !mode.endsWith('paused');
          final parked = mode.startsWith('parked-');
          var frameChecks = 0;
          service.debugBilibiliFrameReadiness = parked
              ? (controller, startup) {
                  if (++frameChecks == 1) return Completer<void>().future;
                  // Inject the missing initial signal, then verify the correction
                  // with real native seeking, output parameters and texture state.
                  // ignore: invalid_use_of_visible_for_testing_member
                  return NativeVideoPlayerMediaKit.frameAtPositionFor(
                    controller.playerId,
                    startup,
                  )!;
                }
              : null;
          final opening = service
              .play(item, autoPlay: playing, startPosition: resumePosition)
              .whenComplete(() => done = true);
          while (!done && watch.elapsed < const Duration(seconds: 32)) {
            await tester.pump(const Duration(milliseconds: 16));
            if (service.bilibiliStartup?.isPending == true) {
              expect(
                service.positionForProgressChrome(Duration.zero),
                resumePosition,
              );
              final controller = service.controller;
              if (controller != null &&
                  controller.value.isInitialized &&
                  service.bilibiliStartup?.isPrepared != true) {
                // ignore: invalid_use_of_visible_for_testing_member
                expect(
                  await NativeVideoPlayerMediaKit.transportPausedFor(
                    controller.playerId,
                  ),
                  isTrue,
                  reason:
                      'Audio must remain paused until the target frame is composed',
                );
                // Check the real media clock, not video_player's optimistic flag.
                // ignore: invalid_use_of_visible_for_testing_member
                final held =
                    await NativeVideoPlayerMediaKit.transportPositionFor(
                      controller.playerId,
                    );
                expect(
                  (held! - resumePosition).inMilliseconds.abs(),
                  lessThanOrEqualTo(70),
                  reason:
                      'Native audio advanced under the startup cover: $mode',
                );
              }
            }
            pixels.add(
              await _pixel(
                frameKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary,
              ),
            );
          }
          await opening;
          expect(
            service.state,
            playing ? PlaybackState.playing : PlaybackState.paused,
            reason: '${service.bilibiliStartup?.marks}',
          );
          final readyMs = watch.elapsedMilliseconds;
          for (var frame = 0; frame < 12; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            pixels.add(
              await _pixel(
                frameKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary,
              ),
            );
          }
          expect(
            pixels.where((p) => p[0] > 170 && p[1] < 80 && p[2] < 80),
            isEmpty,
            reason: 'Red t=0 frames must never escape the poster: $mode',
          );
          expect(
            pixels.any((p) => p[2] > 120 && p[0] < 100),
            isTrue,
            reason:
                'The blue saved-position frame must become visible: $mode; $pixels',
          );
          // ignore: invalid_use_of_visible_for_testing_member
          final native = await NativeVideoPlayerMediaKit.transportPositionFor(
            service.controller!.playerId,
          );
          expect(
            native!.inMilliseconds,
            inInclusiveRange(
              resumePosition.inMilliseconds - 50,
              resumePosition.inMilliseconds + 1500,
            ),
          );
          if (!playing) {
            expect(
              native.inMilliseconds,
              inInclusiveRange(
                resumePosition.inMilliseconds - 50,
                resumePosition.inMilliseconds + 70,
              ),
            );
          }
          if (parked) {
            expect(frameChecks, 2);
            expect(
              service.bilibiliStartup!.marks.where(
                (mark) => mark.step == 'resume frame recovery seek',
              ),
              hasLength(1),
            );
          }
          if (delayPrimary) expect(readyMs, lessThan(2900));
          report.add({
            'mode': mode,
            'longGop': longGop,
            'resumeMs': resumePosition.inMilliseconds,
            'readyMs': readyMs,
            'capturedFrames': pixels.length,
            'originRequests': origins - previousOrigins,
            'apiCalls': api.calls,
            'nativeMs': native.inMilliseconds,
            'stages': [
              for (final mark in service.bilibiliStartup!.marks)
                {'step': mark.step, 'ms': mark.ms},
            ],
          });
          service.debugBilibiliFrameReadiness = null;
          if (mode == 'cached-playing') {
            settings.bilibiliBackgroundAudioOnly = true;
            for (final paused in [false, true]) {
              if (paused) await service.pause();
              final originalController = service.controller!;
              service.setPlaybackPageVisible(owner, false);
              if (paused) await service.seekTo(const Duration(seconds: 7));
              for (var i = 0; i < 20; i++) {
                await tester.pump(const Duration(milliseconds: 16));
              }
              // ignore: invalid_use_of_visible_for_testing_member
              final before =
                  await NativeVideoPlayerMediaKit.transportPositionFor(
                    originalController.playerId,
                  );
              final joining = Stopwatch()..start();
              service.setPlaybackPageVisible(owner, true);
              final joinPixels = <List<int>>[];
              while (service.isCoveringUntilVisibleVideoFrame &&
                  joining.elapsed < const Duration(seconds: 31)) {
                await tester.pump(const Duration(milliseconds: 16));
                // ignore: invalid_use_of_visible_for_testing_member
                expect(
                  await NativeVideoPlayerMediaKit.transportPausedFor(
                    originalController.playerId,
                  ),
                  paused,
                  reason:
                      'Joining Mini video must preserve the native audio intent',
                );
                joinPixels.add(
                  await _pixel(
                    frameKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary,
                  ),
                );
              }
              expect(identical(service.controller, originalController), isTrue);
              expect(
                service.bilibiliStartup!.isReady,
                isTrue,
                reason: '${service.bilibiliStartup!.marks}',
              );
              expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
              for (var i = 0; i < 10; i++) {
                await tester.pump(const Duration(milliseconds: 16));
                joinPixels.add(
                  await _pixel(
                    frameKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary,
                  ),
                );
              }
              if (paused) {
                expect(
                  joinPixels.any((p) => p[1] > 85 && p[0] < 80 && p[2] < 80),
                  isTrue,
                  reason:
                      'The current green frame at t=7s must replace the old blue frame',
                );
              }
              expect(
                joinPixels.where((p) => p[0] > 170 && p[1] < 80 && p[2] < 80),
                isEmpty,
              );
              // ignore: invalid_use_of_visible_for_testing_member
              final after =
                  await NativeVideoPlayerMediaKit.transportPositionFor(
                    originalController.playerId,
                  );
              expect(
                after!.inMilliseconds,
                greaterThanOrEqualTo(before!.inMilliseconds - 70),
              );
              if (paused) {
                expect(
                  (after - before).inMilliseconds.abs(),
                  lessThanOrEqualTo(70),
                );
              }
              report.add({
                'mode': paused ? 'mini-paused' : 'mini-playing',
                'readyMs': joining.elapsedMilliseconds,
                'capturedFrames': joinPixels.length,
                'nativeBeforeMs': before.inMilliseconds,
                'nativeAfterMs': after.inMilliseconds,
                'sameController': true,
                'stages': [
                  for (final mark in service.bilibiliStartup!.marks)
                    {'step': mark.step, 'ms': mark.ms},
                ],
              });
            }
            settings.bilibiliBackgroundAudioOnly = originalAudioOnly;
          }
          await service.stop();
          await tester.pump();
        }
        final complete = File('${root.path}/complete.mp4');
        final muxed = await Process.run('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-i',
          video.path,
          '-i',
          audio.path,
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          complete.path,
        ]);
        expect(muxed.exitCode, 0, reason: '${muxed.stderr}');
        api.removed = true;
        MediaCacheHooks.acquire = (item, {qualityId}) async =>
            MaterializedMediaLease(
              videoId: item.id,
              videoPath: complete.path,
              audioPath: complete.path,
              completePath: complete.path,
              qualityId: 80,
              width: 320,
              height: 180,
              retainedOffline: true,
              onRelease: () async {},
            );
        MediaCacheHooks.qualities = (_) => [
          CacheQuality(id: '80', label: '1080P'),
        ];
        for (final paused in [false, true]) {
          final item = VideoItem(
            id: 'removed-offline-$paused',
            path: 'bilibili://stream/BV1xx411c7mD?cid=404',
            title: 'retained offline',
            durationMs: 21000,
            lastPositionMs: resumePosition.inMilliseconds,
            lastUpdated: 0,
            thumbnailPath: poster.path,
            bilibiliDownloadPath: complete.path,
            sourceRef: const MediaSourceRef(
              value: 'BV1xx411c7mD',
              kind: MediaSourceKind.bilibiliStream,
              bvid: 'BV1xx411c7mD',
              cid: 404,
            ),
          );
          final watch = Stopwatch()..start();
          final deniedBefore = api.deniedCalls;
          var done = false;
          final pixels = <List<int>>[];
          final opening = service
              .play(item, autoPlay: !paused, startPosition: resumePosition)
              .whenComplete(() => done = true);
          while (!done && watch.elapsed < const Duration(seconds: 31)) {
            await tester.pump(const Duration(milliseconds: 16));
            pixels.add(
              await _pixel(
                frameKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary,
              ),
            );
          }
          await opening;
          expect(
            service.state,
            paused ? PlaybackState.paused : PlaybackState.playing,
          );
          expect(service.selectedStreamQuality!.isLocalMaterialized, isTrue);
          expect(
            api.deniedCalls,
            greaterThan(deniedBefore),
            reason: 'Optional remote metadata is actually unavailable',
          );
          final readyMs = watch.elapsedMilliseconds;
          final original = service.controller!;
          final callsBeforeReturn = api.calls;
          final before = await NativeVideoPlayerMediaKit.transportPositionFor(
            original.playerId,
          );
          for (var cycle = 0; cycle < 3; cycle++) {
            service.handleAppLifecycleState(AppLifecycleState.paused);
            await tester.pump(const Duration(milliseconds: 100));
            service.handleAppLifecycleState(AppLifecycleState.resumed);
            await tester.pump(const Duration(milliseconds: 150));
            expect(service.controller, same(original));
            expect(service.isCoveringUntilVisibleVideoFrame, isFalse);
            expect(service.bilibiliStartup!.isReady, isTrue);
            final pixel = await _pixel(
              frameKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary,
            );
            pixels.add(pixel);
            expect(
              pixel[0],
              lessThan(80),
              reason: 'The poster/intro must not cover live video',
            );
            expect(pixel[1] > 85 || pixel[2] > 120, isTrue);
          }
          final after = await NativeVideoPlayerMediaKit.transportPositionFor(
            original.playerId,
          );
          expect(api.calls, callsBeforeReturn);
          expect(
            await NativeVideoPlayerMediaKit.transportPausedFor(
              original.playerId,
            ),
            paused,
          );
          expect(
            pixels.where((p) => p[0] > 170 && p[1] < 80 && p[2] < 80),
            isEmpty,
          );
          if (paused) {
            expect(
              (after! - before!).inMilliseconds.abs(),
              lessThanOrEqualTo(70),
            );
          } else {
            expect(
              after! - before!,
              greaterThan(const Duration(milliseconds: 100)),
            );
          }
          report.add({
            'mode': paused
                ? 'removed-offline-paused'
                : 'removed-offline-playing',
            'readyMs': readyMs,
            'capturedFrames': pixels.length,
            'sameController': true,
            'foregroundCycles': 3,
            'nativeBeforeMs': before.inMilliseconds,
            'nativeAfterMs': after.inMilliseconds,
            'deniedMetadataCalls': api.deniedCalls - deniedBefore,
          });
          await service.stop();
          await tester.pump();
        }
        final destination = Platform.environment['BILIBILI_STARTUP_REPORT'];
        if (destination != null) {
          final output = File(destination);
          await output.parent.create(recursive: true);
          await output.writeAsString(
            const JsonEncoder.withIndent('  ').convert(report),
          );
        }
        debugPrint('BILIBILI_STARTUP_RESULT ${jsonEncode(report)}');
      } finally {
        MediaCacheHooks.acquire = null;
        MediaCacheHooks.qualities = null;
        service.debugBilibiliFrameReadiness = null;
        settings.bilibiliBackgroundAudioOnly = originalAudioOnly;
        await service.stop();
        service.setPlaybackPageVisible(owner, false);
        await streaming?.shutdown();
        await tester.pumpWidget(const SizedBox());
        await server?.close(force: true);
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
