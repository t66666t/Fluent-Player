import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pixels;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'package:video_player_app/services/network/scoped_network_image.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';
import 'package:video_player_app/widgets/media_library_root_surface_host.dart';

import 'test_dir_cleanup.dart';

const _video = ValueKey('video-cover');
const _avatar = ValueKey('user-avatar');
const _blue = Color(0xFF2196F3);
const _green = Color(0xFF4CAF50);

bool _hasPixels(WidgetTester tester, Key key) {
  final images = tester.widgetList<RawImage>(
    find.descendant(of: find.byKey(key), matching: find.byType(RawImage)),
  );
  return images.any((image) => image.image != null);
}

ui.Image? _decodedImage(WidgetTester tester, Key key) => tester
    .widget<RawImage>(
      find.descendant(of: find.byKey(key), matching: find.byType(RawImage)),
    )
    .image;

bool _showsError(WidgetTester tester, Key key) => find
    .descendant(of: find.byKey(key), matching: find.byType(RawImage))
    .evaluate()
    .isEmpty;

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 100 && !ready(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'The local image response must finish');
  await tester.pumpAndSettle();
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Uint8List _png(Color color) {
  final image = pixels.Image(width: 8, height: 8);
  final argb = color.toARGB32();
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgba(
        x,
        y,
        (argb >> 16) & 255,
        (argb >> 8) & 255,
        argb & 255,
        255,
      );
    }
  }
  return Uint8List.fromList(pixels.encodePng(image));
}

class _Host {
  _Host(this.videoUrl, this.avatarUrl);
  String videoUrl;
  String avatarUrl;
  final boundary = GlobalKey();
  MediaLibraryRootEntry selected = MediaLibraryRootEntry.bilibili;
  late StateSetter change;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(384, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const preload = ValueKey('preload-context');
    await tester.pumpWidget(const MaterialApp(home: SizedBox(key: preload)));
    await tester.runAsync(() async {
      final context = tester.element(find.byKey(preload));
      await Future.wait([
        precacheImage(ScopedNetworkImage(videoUrl), context),
        precacheImage(ScopedNetworkImage(avatarUrl), context),
      ]).timeout(const Duration(seconds: 5));
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return MediaLibraryRootSurfaceHost(
                  displayedEntry: selected,
                  onUserSwipe: (entry) => change(() => selected = entry),
                  continueBuilder: (_, _) => const SizedBox(),
                  recentBuilder: (_, _) => const SizedBox(),
                  foldersBuilder: (_, _) => const SizedBox(),
                  podcastsBuilder: (_, _) => const SizedBox(),
                  bilibiliBuilder: (_, active) => TickerMode(
                    // The search page pauses its video/user result tab when the
                    // root host marks it inactive at the start of a held swipe.
                    enabled: active,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BilibiliCoverImage(
                            key: _video,
                            url: videoUrl,
                            width: 160,
                            height: 100,
                          ),
                          const SizedBox(height: 24),
                          BilibiliAvatar(
                            key: _avatar,
                            url: avatarUrl,
                            size: 64,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<Color> colorAt(WidgetTester tester, Key key) async {
    final point = tester.getTopLeft(find.byKey(key)) + const Offset(16, 16);
    final value = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final pointInImage = render.globalToLocal(point);
      final image = await render.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset =
          (pointInImage.dy.floor() * image.width + pointInImage.dx.floor()) * 4;
      final color = Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
      image.dispose();
      return color;
    });
    return value!;
  }

  Future<void> expectPictures(WidgetTester tester) async {
    expect(
      await colorAt(tester, _video),
      _blue,
      reason: 'The already displayed video cover must stay painted',
    );
    expect(
      await colorAt(tester, _avatar),
      _green,
      reason: 'The already displayed user avatar must stay painted',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late Directory directory;
  late PathProviderPlatform previousPaths;
  HttpOverrides? previousHttp;
  final requests = <String, int>{};
  final gates = <String, Completer<void>>{};
  final payloads = <String, Uint8List>{};
  late NetworkMode initialMode;

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  Future<void> arrived(WidgetTester tester, String path, int count) async {
    await _pumpUntil(tester, () => (requests[path] ?? 0) >= count);
  }

  Future<void> changePolicy(WidgetTester tester) async {
    final settings = NetworkSettingsService.instance;
    final oldMode = settings.configuration.modes[NetworkScope.bilibili];
    await tester.runAsync(
      () => settings.setMode(
        NetworkScope.bilibili,
        oldMode == NetworkMode.direct ? NetworkMode.system : NetworkMode.direct,
      ),
    );
    await tester.pump();
  }

  setUpAll(() async {
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp(
      'bilibili-cover-lifecycle-',
    );
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    await NetworkSettingsService.instance.init();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests.update(path, (value) => value + 1, ifAbsent: () => 1);
      await gates[path]?.future;
      final bytes = payloads[path];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      }
      await request.response.close();
    });
  });

  setUp(() {
    initialMode = NetworkSettingsService
        .instance
        .configuration
        .modes[NetworkScope.bilibili]!;
    requests.clear();
    gates.clear();
    payloads
      ..clear()
      ..addAll({'/video.png': _png(_blue), '/avatar.png': _png(_green)});
  });

  tearDown(() async {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    if (NetworkSettingsService.instance.configuration.modes[NetworkScope
            .bilibili] !=
        initialMode) {
      await NetworkSettingsService.instance.setMode(
        NetworkScope.bilibili,
        initialMode,
      );
    }
  });

  tearDownAll(() async {
    await server.close(force: true);
    PathProviderPlatform.instance = previousPaths;
    HttpOverrides.global = previousHttp;
    await deleteTestTempDir(directory);
  });

  for (final dx in [-36.0, 36.0]) {
    testWidgets(
      'held root swipe $dx preserves covers and avatars without GETs',
      (tester) async {
        final host = _Host(url('/video.png'), url('/avatar.png'));
        await host.mount(tester);
        await host.expectPictures(tester);
        final originalX = tester.getTopLeft(find.byKey(_video)).dx;

        for (var repeat = 0; repeat < 3; repeat++) {
          final drag = await tester.startGesture(const Offset(192, 540));
          await drag.moveBy(Offset(dx, 0));
          await tester.pump();
          expect(tester.getTopLeft(find.byKey(_video)).dx, isNot(originalX));
          expect(
            TickerMode.valuesOf(tester.element(find.byKey(_video))).enabled,
            isFalse,
          );
          await host.expectPictures(tester);
          await tester.pump(const Duration(milliseconds: 350));
          await host.expectPictures(tester);
          expect(requests, {'/video.png': 1, '/avatar.png': 1});
          await drag.cancel();
          await tester.pumpAndSettle();
          await host.expectPictures(tester);
          expect(host.selected, MediaLibraryRootEntry.bilibili);
        }
        expect(requests, {'/video.png': 1, '/avatar.png': 1});
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('leaving and returning reuses the displayed pictures', (
    tester,
  ) async {
    final host = _Host(url('/video.png'), url('/avatar.png'));
    await host.mount(tester);
    final coverState = tester.state(find.byKey(_video));
    host.change(() => host.selected = MediaLibraryRootEntry.podcasts);
    await tester.pumpAndSettle();
    host.change(() => host.selected = MediaLibraryRootEntry.bilibili);
    await tester.pump();
    await tester.pumpAndSettle();
    await host.expectPictures(tester);
    expect(tester.state(find.byKey(_video)), same(coverState));
    expect(requests, {'/video.png': 1, '/avatar.png': 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('new video and user URLs never inherit the previous picture', (
    tester,
  ) async {
    final host = _Host(url('/video.png'), url('/avatar.png'));
    await host.mount(tester);
    payloads['/next-video.png'] = _png(_green);
    payloads['/next-avatar.png'] = _png(_blue);
    final videoGate = gates['/next-video.png'] = Completer<void>();
    final avatarGate = gates['/next-avatar.png'] = Completer<void>();
    host.change(() {
      host.videoUrl = url('/next-video.png');
      host.avatarUrl = url('/next-avatar.png');
    });
    await tester.pump();
    expect(await host.colorAt(tester, _video), isNot(_blue));
    expect(await host.colorAt(tester, _avatar), isNot(_green));
    await arrived(tester, '/next-video.png', 1);
    await arrived(tester, '/next-avatar.png', 1);
    videoGate.complete();
    avatarGate.complete();
    await _pumpUntil(
      tester,
      () => _hasPixels(tester, _video) && _hasPixels(tester, _avatar),
    );
    expect(await host.colorAt(tester, _video), _green);
    expect(await host.colorAt(tester, _avatar), _blue);
    expect(requests['/next-video.png'], 1);
    expect(requests['/next-avatar.png'], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real image errors show placeholders and policy retries recover',
    (tester) async {
      final host = _Host(url('/video.png'), url('/avatar.png'));
      await host.mount(tester);
      host.change(() {
        host.videoUrl = url('/failed-video.png');
        host.avatarUrl = url('/failed-avatar.png');
      });
      await tester.pump();
      await arrived(tester, '/failed-video.png', 1);
      await arrived(tester, '/failed-avatar.png', 1);
      await _pumpUntil(
        tester,
        () => _showsError(tester, _video) && _showsError(tester, _avatar),
      );
      expect(await host.colorAt(tester, _video), isNot(_blue));
      expect(await host.colorAt(tester, _avatar), isNot(_green));

      payloads['/failed-video.png'] = _png(_blue);
      payloads['/failed-avatar.png'] = _png(_green);
      await changePolicy(tester);
      await arrived(tester, '/failed-video.png', 2);
      await arrived(tester, '/failed-avatar.png', 2);
      await _pumpUntil(
        tester,
        () => _hasPixels(tester, _video) && _hasPixels(tester, _avatar),
      );
      await host.expectPictures(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a network policy change still refreshes the same URL', (
    tester,
  ) async {
    final host = _Host(url('/video.png'), url('/avatar.png'));
    await host.mount(tester);
    final oldVideo = _decodedImage(tester, _video);
    final oldAvatar = _decodedImage(tester, _avatar);
    final videoGate = gates['/video.png'] = Completer<void>();
    final avatarGate = gates['/avatar.png'] = Completer<void>();
    payloads['/video.png'] = _png(_green);
    payloads['/avatar.png'] = _png(_blue);
    await changePolicy(tester);
    await arrived(tester, '/video.png', 2);
    await arrived(tester, '/avatar.png', 2);
    await host.expectPictures(tester);
    videoGate.complete();
    avatarGate.complete();
    await _pumpUntil(
      tester,
      () =>
          !identical(_decodedImage(tester, _video), oldVideo) &&
          !identical(_decodedImage(tester, _avatar), oldAvatar),
    );
    expect(await host.colorAt(tester, _video), _green);
    expect(await host.colorAt(tester, _avatar), _blue);
    expect(requests, {'/video.png': 2, '/avatar.png': 2});
    expect(tester.takeException(), isNull);
  });

  testWidgets('cache eviction can reload without blanking the held swipe', (
    tester,
  ) async {
    final host = _Host(url('/video.png'), url('/avatar.png'));
    await host.mount(tester);
    final oldVideo = _decodedImage(tester, _video);
    final oldAvatar = _decodedImage(tester, _avatar);
    final videoGate = gates['/video.png'] = Completer<void>();
    final avatarGate = gates['/avatar.png'] = Completer<void>();
    payloads['/video.png'] = _png(_green);
    payloads['/avatar.png'] = _png(_blue);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final drag = await tester.startGesture(const Offset(192, 540));
    await drag.moveBy(const Offset(-36, 0));
    await tester.pump();
    await arrived(tester, '/video.png', 2);
    await arrived(tester, '/avatar.png', 2);
    await host.expectPictures(tester);
    videoGate.complete();
    avatarGate.complete();
    await drag.cancel();
    await _pumpUntil(
      tester,
      () =>
          !identical(_decodedImage(tester, _video), oldVideo) &&
          !identical(_decodedImage(tester, _avatar), oldAvatar),
    );
    expect(await host.colorAt(tester, _video), _green);
    expect(await host.colorAt(tester, _avatar), _blue);
    expect(requests, {'/video.png': 2, '/avatar.png': 2});
    expect(tester.takeException(), isNull);
  });
}
