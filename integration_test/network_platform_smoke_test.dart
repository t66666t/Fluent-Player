import 'dart:io';
import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player_app/screens/network_settings_screen.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

void _setTestProcessProxy(String? value) {
  final library = DynamicLibrary.open('kernel32.dll');
  final allocate = library
      .lookupFunction<
        Pointer<Void> Function(Uint32, UintPtr),
        Pointer<Void> Function(int, int)
      >('GlobalAlloc');
  final free = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GlobalFree');
  final set = library
      .lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<Uint16>),
        int Function(Pointer<Uint16>, Pointer<Uint16>)
      >('SetEnvironmentVariableW');
  Pointer<Uint16> text(String value) {
    final units = [...value.codeUnits, 0];
    final pointer = allocate(0, units.length * 2).cast<Uint16>();
    if (pointer == nullptr) throw StateError('Test allocation failed');
    pointer.asTypedList(units.length).setAll(0, units);
    return pointer;
  }

  final name = text('http_proxy');
  final address = value == null ? nullptr.cast<Uint16>() : text(value);
  try {
    if (set(name, address) == 0) {
      throw StateError('Test environment update failed');
    }
  } finally {
    free(name.cast<Void>());
    if (address != nullptr) free(address.cast<Void>());
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native proxy resolver, credential storage, local gateway and saved settings',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'network_native_smoke_',
      );
      const credentials = SecureNetworkCredentialStore();
      final key = 'network_smoke_${const Uuid().v4()}';
      final settings = NetworkSettingsService(
        store: FileNetworkConfigStore(directory: () async => directory),
        credentials: credentials,
        migrateLegacy: false,
      );
      final network = NetworkHttp(settings: settings);
      HttpServer? origin;
      try {
        debugPrint('Network smoke: resolving device policy');
        final routes = await PlatformProxyResolver()
            .resolve(Uri.parse('https://www.bilibili.com/'))
            .timeout(const Duration(seconds: 45));
        expect(routes, isNotEmpty);
        debugPrint('Network smoke: checking secure storage');
        await credentials.write(key, 'native-test-secret');
        expect(await credentials.read(key), 'native-test-secret');
        await settings.ready;
        debugPrint('Network smoke: checking settings and local gateway');
        await settings.setMode(NetworkScope.translation, NetworkMode.direct);
        final restored = NetworkSettingsService(
          store: settings.store,
          credentials: credentials,
          migrateLegacy: false,
        );
        await restored.ready;
        expect(
          restored.configuration.modes[NetworkScope.translation],
          NetworkMode.direct,
        );
        origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        origin.listen((request) async {
          request.response.write('local gateway');
          await request.response.close();
        });
        final dio = network.createDio();
        try {
          final response = await dio.get<String>(
            'http://127.0.0.1:${origin.port}/gateway',
          );
          expect(response.data, 'local gateway');
        } finally {
          dio.close(force: true);
        }
        await tester.pumpWidget(
          MaterialApp(home: NetworkSettingsScreen(service: restored)),
        );
        await tester.pumpAndSettle();
        expect(find.text('网络设置'), findsOneWidget);
        expect(find.text('已应用'), findsOneWidget);
        debugPrint('Network smoke: all checks passed');
      } finally {
        await credentials.delete(key);
        await network.dispose();
        await origin?.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'native decoder reads the loopback gateway despite an inherited proxy',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'network_decoder_smoke_',
      );
      final video = File(
        '${directory.path}${Platform.pathSeparator}sample.mp4',
      );
      HttpServer? server;
      VideoPlayerController? controller;
      final inherited = Platform.environment.entries
          .where((entry) => entry.key.toLowerCase() == 'http_proxy')
          .firstOrNull
          ?.value;
      try {
        final encoded = await Process.run(
          'ffmpeg',
          [
            '-hide_banner',
            '-loglevel',
            'error',
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=black:s=160x90:r=10',
            '-f',
            'lavfi',
            '-i',
            'anullsrc=r=44100:cl=stereo',
            '-t',
            '2',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            '-movflags',
            '+faststart',
            '-shortest',
            video.path,
          ],
          environment: NetworkHttp.childEnvironment(),
          includeParentEnvironment: false,
        );
        expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
        final bytes = await video.readAsBytes();
        var requests = 0;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests++;
          final range = request.headers.value('Range');
          final start = range == null
              ? 0
              : int.tryParse(range.split('=')[1].split('-')[0]) ?? 0;
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.headers.set('Accept-Ranges', 'bytes');
          if (range != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-${bytes.length - 1}/${bytes.length}',
            );
          }
          request.response.contentLength = bytes.length - start;
          try {
            request.response.add(bytes.sublist(start));
            await request.response.close();
          } catch (_) {}
        });
        NativeVideoPlayerMediaKit.ensureInitialized();
        _setTestProcessProxy('http://127.0.0.1:1');
        controller = VideoPlayerController.networkUrl(
          Uri.parse('http://127.0.0.1:${server.port}/sample.mp4'),
        );
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: VideoPlayer(controller))),
        );
        var initialized = false;
        Object? initializationError;
        controller.initialize().then(
          (_) => initialized = true,
          onError: (Object error) {
            initializationError = error;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!initialized &&
            initializationError == null &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(initializationError, isNull);
        expect(
          initialized,
          isTrue,
          reason:
              'Native initialize did not finish; gateway requests=$requests',
        );
        expect(controller.value.isInitialized, isTrue);
        expect(
          controller.value.duration.inMilliseconds,
          greaterThanOrEqualTo(1800),
        );
        await controller.play();
        await tester.pump(const Duration(milliseconds: 500));
        await controller.pause();
        expect(requests, greaterThan(0));
        expect(controller.value.hasError, isFalse);
        debugPrint('Network smoke: native loopback media decoded');
      } finally {
        _setTestProcessProxy(inherited);
        await tester.pumpWidget(const SizedBox.shrink());
        await controller?.dispose();
        await server?.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isWindows,
  );
}
