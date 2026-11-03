import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/platform/local_playback_backend_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';

class _Api extends BilibiliApiService {
  _Api(this.origin);
  final Uri origin;
  int opens = 0;
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    opens++;
    return BilibiliStreamInfo(
      durationMs: 21000,
      qualityMap: const {80: '1080P'},
      videoStreams: [
        StreamItem(
          id: 80,
          baseUrl: origin.resolve('/video').toString(),
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

class _Lifecycle extends WidgetsBindingObserver {
  _Lifecycle(this.service);
  final MediaPlaybackService service;
  bool sawBackground = false;
  DateTime? backgroundedAt;
  DateTime? foregroundedAt;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      sawBackground = true;
      backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed && sawBackground) {
      foregroundedAt = DateTime.now();
    }
    service.handleAppLifecycleState(state);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'native recovery preserves paused pixels, clock and audio-only policy',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'playback-recovery-native-',
      );
      for (final name in ['video.mp4', 'audio.m4a', 'local.mp4', 'wide.mkv']) {
        final bytes = await rootBundle.load('assets/$name');
        await File('${root.path}/$name').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final files = {
        '/video': File('${root.path}/video.mp4'),
        '/audio': File('${root.path}/audio.m4a'),
      };
      final subscription = server.listen((request) async {
        try {
          final file = files[request.uri.path];
          if (file == null) {
            request.response.statusCode = 404;
            await request.response.close();
            return;
          }
          final length = await file.length();
          final range = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = range == null ? 0 : int.parse(range[1]!);
          var end = range == null
              ? length - 1
              : int.tryParse(range[2]!) ?? length - 1;
          if (end >= length) end = length - 1;
          if (start >= length) {
            request.response.statusCode = 416;
            await request.response.close();
            return;
          }
          request.response.headers.set('accept-ranges', 'bytes');
          request.response.headers.contentType = ContentType(
            request.uri.path == '/audio' ? 'audio' : 'video',
            'mp4',
          );
          if (range != null) {
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$length',
            );
          }
          request.response.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            await request.response.addStream(file.openRead(start, end + 1));
          }
          await request.response.close();
        } catch (_) {
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      final api = _Api(Uri.parse('http://127.0.0.1:${server.port}'));
      final streaming = BilibiliStreamingService(
        api,
        mediaUriValidator: (uri) =>
            uri.host == '127.0.0.1' && uri.port == server.port,
        cacheDirectory: Directory('${root.path}/cache'),
      );
      final service = MediaPlaybackService.forTesting();
      final owner = Object();
      final lifecycle = _Lifecycle(service);
      final frameKey = GlobalKey();
      final results = <String, Object?>{};
      final originalAudioOnly = SettingsService().bilibiliBackgroundAudioOnly;
      Future<T> drive<T>(Future<T> work) async {
        var done = false;
        T? result;
        Object? failure;
        StackTrace? stack;
        unawaited(
          work.then<void>(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object error, StackTrace trace) {
              failure = error;
              stack = trace;
              done = true;
            },
          ),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!done && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        if (failure != null) Error.throwWithStackTrace(failure!, stack!);
        if (!done) throw TimeoutException('Native probe did not settle');
        return result as T;
      }

      Future<void> greenFrame(String stage) async {
        await tester.pump(const Duration(milliseconds: 300));
        // Native size/texture callbacks may dirty the widget after the
        // preceding frame's post-frame callbacks. Paint that revision before
        // reading pixels, instead of treating a dirty tree as a black frame.
        for (var frame = 0; frame < 100; frame++) {
          final boundary =
              frameKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          if (!boundary.debugNeedsPaint) break;
          await tester.pump(const Duration(milliseconds: 20));
        }
        final image =
            await (frameKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final offset =
              ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
          final pixel = [
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          ];
          results[stage] = {
            'pixel': pixel, 'positionMs': service.position.inMilliseconds,
            'playing': service.controller!.value.isPlaying,
            // ignore: invalid_use_of_visible_for_testing_member
            'native': await NativeVideoPlayerMediaKit.transportStateFor(
              service.controller!.playerId,
            ),
          };
          debugPrint(
            'PLAYBACK_RECOVERY_NATIVE_STAGE=$stage ${jsonEncode(results[stage])}',
          );
          expect(
            pixel[1],
            greaterThan(60),
            reason: '$stage must render the green resume segment',
          );
          expect(pixel[0], lessThan(50));
          expect(pixel[2], lessThan(50));
        } finally {
          image.dispose();
        }
      }

      try {
        await service.initialize(
          playlistManager: PlaylistManager(),
          progressTracker: ProgressTracker(
            playbackStateStore: PlaybackStateStore(
              directoryProvider: () async => root,
            ),
          ),
          bilibiliStreamingService: streaming,
        );
        WidgetsBinding.instance.addObserver(lifecycle);
        service.setPlaybackPageVisible(owner, true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Text('Playback Recovery Audit — isolated test data'),
                  AnimatedBuilder(
                    animation: service,
                    builder: (context, _) => Text(
                      '${service.currentItem?.id} ${service.state.name} ${service.position}',
                    ),
                  ),
                  Center(
                    child: RepaintBoundary(
                      key: frameKey,
                      child: SizedBox(
                        width: 320,
                        height: 180,
                        child: AnimatedBuilder(
                          animation: service,
                          builder: (context, _) {
                            final controller = service.controller;
                            return controller != null &&
                                    service.canMountControllerFor(
                                      service.currentItem!.id,
                                    )
                                ? VideoPlayer(controller)
                                : const ColoredBox(color: Colors.black);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        for (final name in ['local.mp4', 'wide.mkv']) {
          if (name == 'wide.mkv') {
            // MKV/AAC can be platform-safe. Exercise the existing fallback
            // policy explicitly, as after a platform backend failure.
            LocalPlaybackBackendPolicy.preferWideCodecBackend(
              '${root.path}/$name',
            );
          }
          final item = VideoItem(
            id: name,
            path: '${root.path}/$name',
            title: name,
            durationMs: 21000,
            lastUpdated: 0,
          );
          await drive(
            service.play(
              item,
              startPosition: const Duration(seconds: 8),
              autoPlay: false,
            ),
          );
          await greenFrame(name);
          expect(service.controller!.value.isPlaying, isFalse);
          if (Platform.isAndroid) {
            // ignore: invalid_use_of_visible_for_testing_member
            expect(service.controller!.playerId < -1, name == 'local.mp4');
          }
        }
        final item = VideoItem(
          id: 'native-bilibili',
          path: 'bilibili://stream/BV1xx411c7mD?cid=1',
          title: 'Native Bilibili recovery',
          durationMs: 21000,
          lastUpdated: 0,
          sourceRef: MediaSourceRef(
            kind: MediaSourceKind.bilibiliStream,
            value: 'BV1xx411c7mD',
            bvid: 'BV1xx411c7mD',
            cid: 1,
          ),
        );
        await drive(
          service.play(
            item,
            startPosition: const Duration(seconds: 8),
            autoPlay: false,
          ),
        );
        await greenFrame('bilibili-paused');
        final controller = service.controller!;
        // ignore: invalid_use_of_visible_for_testing_member
        final playerId = controller.playerId;
        final opens = api.opens;
        if (Platform.isAndroid) {
          for (var cycle = 0; cycle < 2; cycle++) {
            var recoveryNeeded = false;
            var mountable = false;
            expect(
              await drive(
                NativeVideoPlayerMediaKit.debugCycleAndroidSurface(
                  playerId,
                  () async {
                    recoveryNeeded = service.needsVisibleVideoOutputRecovery(
                      item.id,
                    );
                    mountable = service.canMountControllerFor(item.id);
                    await service.pause();
                  },
                ),
              ),
              isTrue,
            );
            expect(recoveryNeeded, isTrue);
            expect(mountable, isTrue);
            expect(
              await drive(service.ensureVisibleVideoOutput(item.id)),
              isTrue,
            );
            expect(service.controller, same(controller));
            await greenFrame('surface-cycle-$cycle');
            expect(service.position.inMilliseconds, closeTo(8000, 500));
            expect(service.controller!.value.isPlaying, isFalse);
          }
        }
        SettingsService().bilibiliBackgroundAudioOnly = true;
        await drive(service.resume());
        service.handleAppLifecycleState(AppLifecycleState.paused);
        await tester.pump(const Duration(seconds: 1));
        final background = await NativeVideoPlayerMediaKit.transportStateFor(
          playerId,
        );
        results['audioOnlyBackground'] = background;
        expect(background['vid'], 'no');
        service.handleAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump(const Duration(seconds: 1));
        final foreground = await NativeVideoPlayerMediaKit.transportStateFor(
          playerId,
        );
        results['audioOnlyForeground'] = foreground;
        expect(foreground['vid'], isNot('no'));
        expect(service.controller, same(controller));
        expect(api.opens, opens);
        await drive(service.pause());
        // Optional host-controlled HOME/resume or real 6–8 h pause. The driver
        // records duration and charging conditions; a Dart lifecycle call alone
        // does not qualify as real background/overnight validation.
        const hostCycle = bool.fromEnvironment('PLAYBACK_AUDIT_HOST_CYCLE');
        if (hostCycle && Platform.isAndroid) {
          const heldAudioOnly = bool.fromEnvironment(
            'PLAYBACK_AUDIT_AUDIO_ONLY',
          );
          SettingsService().bilibiliBackgroundAudioOnly = heldAudioOnly;
          lifecycle.sawBackground = false;
          lifecycle.backgroundedAt = null;
          lifecycle.foregroundedAt = null;
          final phase = File('${root.path}/phase.json');
          await phase.writeAsString(
            jsonEncode({
              'phase': 'ready',
              'positionMs': service.position.inMilliseconds,
            }),
          );
          debugPrint('AUDIT_DEVICE_PHASE=${phase.path}');
          const holdSeconds = int.fromEnvironment(
            'PLAYBACK_AUDIT_HOLD_SECONDS',
            defaultValue: 10,
          );
          final deadline = DateTime.now().add(
            Duration(seconds: holdSeconds + 120),
          );
          while (DateTime.now().isBefore(deadline)) {
            if (lifecycle.sawBackground &&
                binding.lifecycleState == AppLifecycleState.resumed) {
              break;
            }
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(lifecycle.sawBackground, isTrue);
          expect(binding.lifecycleState, AppLifecycleState.resumed);
          final held = lifecycle.foregroundedAt!.difference(
            lifecycle.backgroundedAt!,
          );
          results['hostCycle'] = {
            'audioOnly': heldAudioOnly,
            'requestedSeconds': holdSeconds,
            'actualBackgroundMs': held.inMilliseconds,
          };
          expect(held, greaterThanOrEqualTo(Duration(seconds: holdSeconds)));
          await drive(service.ensureVisibleVideoOutput(item.id));
          expect(service.controller!.value.isPlaying, isFalse);
          await greenFrame('host-background-resume');
        }
        debugPrint('PLAYBACK_RECOVERY_NATIVE_RESULT=${jsonEncode(results)}');
        await File(
          '${root.path}/result.json',
        ).writeAsString(jsonEncode(results));
      } finally {
        WidgetsBinding.instance.removeObserver(lifecycle);
        SettingsService().bilibiliBackgroundAudioOnly = originalAudioOnly;
        service.setPlaybackPageVisible(owner, false);
        await drive(service.stop());
        await tester.pumpWidget(const SizedBox.shrink());
        service.dispose();
        await streaming.shutdown();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(hours: 9)),
  );
}
