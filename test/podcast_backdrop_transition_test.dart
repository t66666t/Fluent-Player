import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

const _greenUrl = 'https://example.test/green.png';
const _redUrl = 'https://example.test/red.png';
const _green = Color(0xFF16491D);
const _red = Color(0xFF491D16);

ArtworkRef _reference(String url) =>
    podcastArtworkRef(ownerKind: 'backdrop', ownerId: url, primaryUrl: url);

ArtworkFetchResponse _response(Uri uri) {
  final image = image_lib.Image(width: 24, height: 24);
  image_lib.fill(
    image,
    color: uri.path.contains('red')
        ? image_lib.ColorRgb8(190, 44, 24)
        : image_lib.ColorRgb8(24, 190, 44),
  );
  return ArtworkFetchResponse(
    status: 200,
    headers: const {'cache-control': 'max-age=3600'},
    bytes: image_lib.encodePng(image),
    finalUri: uri,
  );
}

Color _paintedTint(WidgetTester tester) {
  final ink = tester.widget<Ink>(
    find.descendant(
      of: find.byType(PodcastBackdrop),
      matching: find.byType(Ink),
    ),
  );
  return (ink.decoration! as BoxDecoration).gradient!.colors.first;
}

Widget _backdrop(String url) => PodcastBackdrop(
  imageUrl: url,
  intensity: 0.30,
  child: const SizedBox.expand(),
);

Future<MediaArtworkRepository> _repository(
  WidgetTester tester, {
  ArtworkFetcher? fetcher,
}) async {
  late Directory root;
  late MediaArtworkRepository repository;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('podcast-backdrop-motion-');
    repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: fetcher ?? (request) async => _response(request.uri),
    );
  });
  MediaArtworkRepository.debugOverride = repository;
  addTearDown(() async {
    MediaArtworkRepository.debugOverride = null;
    repository.close();
    await root.delete(recursive: true);
  });
  return repository;
}

Future<void> _seed(
  WidgetTester tester,
  MediaArtworkRepository repository,
  String url,
  Color color,
) async {
  await tester.runAsync(() async {
    final snapshot = await repository.load(_reference(url));
    repository.rememberPalette(snapshot.blobHash!, color.toARGB32());
  });
}

Future<void> _flushUntil(WidgetTester tester, bool Function() ready) async {
  // File/codec callbacks need the real event loop, followed by a fake-frame
  // microtask flush. Keep animation time still while the bytes arrive.
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (ready()) return;
  }
  fail('The local cover work did not finish.');
}

void main() {
  testWidgets('a cached channel colour is present on the first painted frame', (
    tester,
  ) async {
    final repository = await _repository(tester);
    await _seed(tester, repository, _greenUrl, _green);
    await tester.pumpWidget(MaterialApp(home: _backdrop(_greenUrl)));
    expect(_paintedTint(tester), _green);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late tint fades visibly while the incoming route is zooming', (
    tester,
  ) async {
    final repository = await _repository(tester);
    await tester.runAsync(() => repository.load(_reference(_greenUrl)));
    final boundaryKey = GlobalKey();
    late AppMaterialPageRoute<void> route;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        builder: (_, child) => RepaintBoundary(key: boundaryKey, child: child),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                route = AppMaterialPageRoute<void>(
                  builder: (_) => _backdrop(_greenUrl),
                );
                Navigator.of(context).push(route);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final neutral = _paintedTint(tester);
    await _flushUntil(
      tester,
      () => repository.cachedPalette(_reference(_greenUrl)) != null,
    );
    await tester.pump();
    expect(_paintedTint(tester), neutral);
    await tester.pump(const Duration(milliseconds: 120));
    final halfway = _paintedTint(tester);
    final target = Color(repository.cachedPalette(_reference(_greenUrl))!);
    expect(halfway, isNot(neutral));
    expect(halfway, isNot(target));
    expect(route.animation!.status, AnimationStatus.forward);

    // Check actual pixels, since a tween running behind a frozen route
    // snapshot used to pass widget-only animation assertions.
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = boundary.toImageSync();
    final pixels = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final offset = (100 * image.width + 100) * 4;
    expect(
      pixels!.getUint8(offset + 1) - pixels.getUint8(offset),
      greaterThan(5),
    );
    image.dispose();

    await tester.pumpAndSettle();
    expect(_paintedTint(tester), target);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an old cover request cannot recolour a newer or empty channel', (
    tester,
  ) async {
    final gate = Completer<ArtworkFetchResponse>();
    final repository = await _repository(
      tester,
      fetcher: (request) => request.uri.toString() == _redUrl
          ? gate.future
          : Future.value(_response(request.uri)),
    );
    await _seed(tester, repository, _greenUrl, _green);
    final url = ValueNotifier(_redUrl);
    addTearDown(url.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<String>(
          valueListenable: url,
          builder: (_, value, _) => _backdrop(value),
        ),
      ),
    );
    // Keep the first request pending while switching to an already-known cover.
    var finished = false;
    unawaited(
      repository.load(_reference(_redUrl)).then((old) {
        repository.rememberPalette(old.blobHash!, _red.toARGB32());
        finished = true;
      }),
    );
    url.value = _greenUrl;
    await tester.pumpAndSettle();
    expect(_paintedTint(tester), _green);
    gate.complete(_response(Uri.parse(_redUrl)));
    await _flushUntil(tester, () => finished);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(_paintedTint(tester), _green);
    url.value = '';
    await tester.pumpAndSettle();
    expect(_paintedTint(tester), const Color(0xFF303034));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
