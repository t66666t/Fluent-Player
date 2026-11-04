import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/network_proxy_bridge.dart';

import 'cloud_drive_gateway_test.dart' show sample;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  final ffmpeg = p.absolute('assets', 'binaries', 'windows', 'ffmpeg.exe');
  final mpv = p.absolute(
    'build',
    'windows',
    'x64',
    'runner',
    'Release',
    'libmpv-2.dll',
  );
  final available =
      Platform.isWindows && File(ffmpeg).existsSync() && File(mpv).existsSync();

  test(
    'discarding a rejected segment aborts its unread body instead of waiting for EOF',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.statusCode = 403;
        request.response.write('expired address');
        try {
          await request.response.flush();
        } catch (_) {
          // The tested client deliberately aborts this rejected response.
        }
        // An error CDN need not close its chunked body before we can refresh.
      });
      final uri = Uri.parse('http://127.0.0.1:${origin.port}/segment.ts');
      try {
        final upstream = await NetworkCloudDriveUpstreamClient().open(
          CloudDriveUpstreamRequest(
            method: 'GET',
            uri: uri,
            connectionScope: 'unread-${origin.port}',
          ),
        );
        expect(upstream.statusCode, 403);
        await upstream.close().timeout(const Duration(milliseconds: 500));
        await upstream.close().timeout(const Duration(milliseconds: 500));
      } finally {
        CloudDriveClientPools.discard(scope: 'unread-${origin.port}');
        await origin.close(force: true);
      }
    },
  );

  test(
    'headers and retries share a deadline and preserve the upstream status',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.statusCode = 503;
        await request.response.close();
      });
      final diagnostics = <String>[];
      final gateway = CloudDriveStreamGateway(
        onDiagnostic: diagnostics.add,
        headerTimeout: const Duration(milliseconds: 180),
        retryDelays: List.filled(20, const Duration(milliseconds: 50)),
      );
      final lease = await gateway.open(
        descriptor: sample(
          uri: Uri.parse('http://127.0.0.1:${origin.port}/seg.ts'),
        ),
        accountLocalId: 'deadline-${origin.port}',
      );
      final client = HttpClient();
      try {
        final clock = Stopwatch()..start();
        final response = await (await client.getUrl(lease.loopbackUri)).close();
        await response.drain<void>();
        expect(response.statusCode, 504);
        expect(clock.elapsedMilliseconds, lessThan(800));
        expect(diagnostics.any((line) => line.contains('status=503')), isTrue);
        expect(
          diagnostics.any((line) => line.contains('gateway error StateError')),
          isFalse,
        );
      } finally {
        client.close(force: true);
        await lease.release();
        await gateway.close();
        CloudDriveClientPools.discard(scope: 'deadline-${origin.port}');
        await origin.close(force: true);
      }
    },
  );

  test('releasing a candidate cancels a pending upstream open', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    origin.listen((request) {
      if (!requested.isCompleted) requested.complete();
    });
    final diagnostics = <String>[];
    final gateway = CloudDriveStreamGateway(onDiagnostic: diagnostics.add);
    final lease = await gateway.open(
      descriptor: sample(
        uri: Uri.parse('http://127.0.0.1:${origin.port}/seg.ts'),
      ),
      accountLocalId: 'cancel-${origin.port}',
    );
    final client = HttpClient();
    try {
      final response = (await client.getUrl(lease.loopbackUri)).close();
      await requested.future.timeout(const Duration(seconds: 2));
      await lease.release();
      final cancelled = await response.timeout(const Duration(seconds: 1));
      await cancelled.drain<void>();
      expect(cancelled.statusCode, 410);
      expect(
        diagnostics.any((line) => line.contains('gateway cancelled')),
        isTrue,
      );
      expect(
        diagnostics.any((line) => line.contains('gateway error StateError')),
        isFalse,
      );
    } finally {
      client.close(force: true);
      await gateway.close();
      CloudDriveClientPools.discard(scope: 'cancel-${origin.port}');
      await origin.close(force: true);
    }
  });

  for (final scenario in [
    (false, false, false),
    (true, false, false),
    (false, true, false),
    (true, false, true),
  ]) {
    final (extensionless, rejectSegments, baiduFallback) = scenario;
    test(
      'native HLS reads real gateway segments (extensionless=$extensionless, rejected=$rejectSegments, baiduFallback=$baiduFallback)',
      () async {
        final root = await Directory.systemTemp.createTemp('cloud_hls_native');
        final generated = await Process.run(ffmpeg, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x180:rate=12',
          '-t',
          '8',
          '-an',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-g',
          '24',
          '-pix_fmt',
          'yuv420p',
          '-f',
          'hls',
          '-hls_time',
          '2',
          '-hls_playlist_type',
          'vod',
          '-hls_segment_filename',
          p.join(root.path, 'seg-%d.ts'),
          p.join(root.path, 'video.m3u8'),
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final original = await File(
          p.join(root.path, 'video.m3u8'),
        ).readAsString();
        var playlist = extensionless
            ? original.replaceAllMapped(
                RegExp(r'seg-(\d+)\.ts'),
                (m) => 'streaming?segment=${m[1]}&sign=fixture',
              )
            : original;
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        if (baiduFallback) {
          final backhost = Uri.encodeQueryComponent(
            '["backup.baidupcs.com:${origin.port}"]',
          );
          playlist = playlist.replaceFirst(
            'sign=fixture',
            'sign=fixture&backhost=$backhost',
          );
        }
        final reads = <String>[];
        final rejected = <String>{};
        origin.listen((request) async {
          reads.add(request.uri.path);
          final name = request.uri.path == '/streaming'
              ? 'seg-${request.uri.queryParameters['segment']}.ts'
              : p.basename(request.uri.path);
          if (rejectSegments && name.endsWith('.ts') && rejected.add(name)) {
            request.response.statusCode = 403;
            request.response.write('expired segment');
            try {
              await request.response.flush();
            } catch (_) {}
            return; // Error body deliberately has no EOF.
          }
          final bytes = await File(p.join(root.path, name)).readAsBytes();
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.contentLength = bytes.length;
          if (request.method != 'HEAD') request.response.add(bytes);
          await request.response.close();
        });
        final diagnostics = <String>[];
        final settings = NetworkSettingsService(
          store: MemoryNetworkStore(),
          credentials: MemoryCredentials(),
          migrateLegacy: false,
        );
        await settings.ready;
        await settings.setMode(NetworkScope.cloudDrive, NetworkMode.direct);
        final bridge = NetworkProxyBridge(
          settings: settings,
          socketConnector: (host, port, secure) {
            if (baiduFallback && host == 'v2-ant.baidu.com') {
              throw const SocketException('PCDN route unavailable');
            }
            return Socket.connect('127.0.0.1', origin.port);
          },
        );
        final network = NetworkHttp(settings: settings, bridge: bridge);
        final gateway = CloudDriveStreamGateway(
          onDiagnostic: diagnostics.add,
          upstream: NetworkCloudDriveUpstreamClient(network: network),
          refresher: (descriptor) async =>
              descriptor.copyWith(dropManifest: true),
        );
        final uri = Uri.parse(
          'http://${baiduFallback ? 'v2-ant.baidu.com' : 'media.fixture.test'}:${origin.port}/video.m3u8',
        );
        final lease = await gateway.open(
          descriptor: sample(uri: uri, transport: CloudDriveTransport.hls)
              .copyWith(
                manifest: CloudDriveManifestSnapshot(
                  text: playlist,
                  baseUri: uri,
                  fetchedAt: DateTime.now(),
                ),
              ),
          accountLocalId: 'native-fixture-${origin.port}',
        );
        MediaKit.ensureInitialized(libmpv: mpv);
        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null'),
        );
        final errors = <String>[];
        final errorSub = player.stream.error.listen(errors.add);
        try {
          await player.setVolume(0);
          await player.setVideoTrack(VideoTrack.auto());
          final native = player.platform as NativePlayer;
          for (final option
              in NativeVideoPlayerMediaKit.cloudDriveNativeOptions(
                hls: true,
                fastStart: true,
              ).entries) {
            await native.setProperty(option.key, option.value);
          }
          await player.open(Media(lease.loopbackUri.toString()), play: false);
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          while (player.state.duration == Duration.zero &&
              DateTime.now().isBefore(deadline) &&
              errors.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          expect(
            player.state.duration,
            greaterThan(Duration.zero),
            reason: '${errors.join('; ')}\n${diagnostics.join('\n')}',
          );
          expect(
            reads,
            isNotEmpty,
            reason:
                'the manifest alone does not validate a working HLS gateway',
          );
          expect(
            diagnostics.where((d) => d.contains('gateway error')),
            isEmpty,
          );
          if (baiduFallback) {
            expect(
              diagnostics.any((d) => d.contains('baidu host fallback')),
              isTrue,
            );
          }
          if (rejectSegments) {
            expect(rejected, isNotEmpty);
            expect(diagnostics.any((d) => d.contains('status=403')), isTrue);
          }
          await player.seek(const Duration(seconds: 3));
          await player.play();
          final decodeDeadline = DateTime.now().add(const Duration(seconds: 5));
          while (player.state.position < const Duration(milliseconds: 3200) &&
              DateTime.now().isBefore(decodeDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          expect(
            player.state.position,
            greaterThan(const Duration(milliseconds: 3100)),
            reason:
                'Native decode must advance after a non-zero HLS seek: $errors',
          );
          expect(await native.getProperty('video-dec-params/w'), '320');
        } finally {
          await errorSub.cancel();
          await player.dispose();
          await lease.release();
          await gateway.close();
          await network.dispose();
          await origin.close(force: true);
          await root.delete(recursive: true);
        }
      },
      skip: available ? false : 'Requires bundled Windows ffmpeg and libmpv',
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }
}
