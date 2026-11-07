import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/services/subtitle_font_preview_service.dart';

SubtitleOnlineFont _font([String name = 'Brawler']) => SubtitleOnlineFont(
  name: name,
  languages: const ['en'],
  files: const [
    'https://raw.githubusercontent.com/google/fonts/revision/ofl/brawler/Brawler-Regular.ttf',
  ],
  licenseFile:
      'https://raw.githubusercontent.com/google/fonts/revision/ofl/brawler/OFL.txt',
  sourceUrl: 'https://github.com/google/fonts/tree/revision/ofl/brawler',
);

Uint8List _css([String url = 'https://fonts.gstatic.com/l/font?kit=preview']) =>
    Uint8List.fromList(
      utf8.encode("@font-face { src: url('$url') format('truetype'); }"),
    );

final _cancelled = throwsA(
  isA<DioException>().having(
    (error) => error.type,
    'type',
    DioExceptionType.cancel,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List face;
  setUpAll(() async {
    face = await File('assets/fonts/Brawler-Regular.otf').readAsBytes();
  });

  test(
    'loads a real specimen once without fetching a complete catalog font',
    () async {
      final requests = <Uri>[];
      final limits = <int>[];
      final loaded = <String>[];
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, cancel, limit) async {
          requests.add(uri);
          limits.add(limit);
          return uri.host == 'fonts.googleapis.com' ? _css() : face;
        },
        fontLoader: (family, bytes) async {
          expect(bytes, face);
          loaded.add(family);
        },
      );
      final alias = await service.load(
        _font(),
        'We meet again.',
        cancel: CancelToken(),
      );
      expect(alias, startsWith('subtitle_preview_'));
      expect(loaded, [alias]);
      expect(requests.map((uri) => uri.host), [
        'fonts.googleapis.com',
        'fonts.gstatic.com',
      ]);
      expect(requests.first.queryParameters['family'], 'Brawler:wght@400');
      expect(
        requests.first.queryParameters['text']!.runes.toSet(),
        'We meet again.'.runes.toSet(),
      );
      expect(limits, [
        SubtitleFontPreviewService.maxCssBytes,
        SubtitleFontPreviewService.maxFontBytes,
      ]);
      expect(
        await service.load(_font(), 'We meet again.', cancel: CancelToken()),
        alias,
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'one subscriber cancellation preserves the shared preview request',
    () async {
      final fontResponse = Completer<Uint8List>();
      final started = Completer<void>();
      late CancelToken sharedCancel;
      var fontRequests = 0, loads = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, cancel, limit) async {
          if (uri.host == 'fonts.googleapis.com') return _css();
          fontRequests++;
          sharedCancel = cancel;
          started.complete();
          return fontResponse.future;
        },
        fontLoader: (_, _) async => loads++,
      );
      final firstCancel = CancelToken();
      final first = service.load(_font(), 'Subtitle', cancel: firstCancel);
      final firstCheck = expectLater(first, _cancelled);
      final second = service.load(_font(), 'Subtitle', cancel: CancelToken());
      await started.future;
      firstCancel.cancel('row disposed');
      await firstCheck;
      expect(sharedCancel.isCancelled, isFalse);
      fontResponse.complete(face);
      expect(await second, startsWith('subtitle_preview_'));
      expect(fontRequests, 1);
      expect(loads, 1);
    },
  );

  test(
    'all subscribers cancelling aborts the request before native loading',
    () async {
      final started = Completer<void>();
      late CancelToken sharedCancel;
      var loads = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, cancel, limit) async {
          if (uri.host == 'fonts.googleapis.com') return _css();
          sharedCancel = cancel;
          started.complete();
          throw await cancel.whenCancel;
        },
        fontLoader: (_, _) async => loads++,
      );
      final one = CancelToken(), two = CancelToken();
      final first = expectLater(
        service.load(_font(), 'Subtitle', cancel: one),
        _cancelled,
      );
      final second = expectLater(
        service.load(_font(), 'Subtitle', cancel: two),
        _cancelled,
      );
      await started.future;
      one.cancel();
      two.cancel();
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);
      expect(sharedCancel.isCancelled, isTrue);
      expect(loads, 0);
    },
  );

  for (final cssTooLarge in [true, false]) {
    test('rejects oversized ${cssTooLarge ? 'CSS' : 'font'} data', () async {
      var loads = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, cancel, limit) async {
          if (uri.host == 'fonts.googleapis.com') {
            return cssTooLarge ? Uint8List(limit + 1) : _css();
          }
          return Uint8List(limit + 1);
        },
        fontLoader: (_, _) async => loads++,
      );
      await expectLater(
        service.load(_font(), 'Subtitle', cancel: CancelToken()),
        throwsFormatException,
      );
      expect(loads, 0);
    });
  }

  for (final uri in [
    'https://fonts.gstatic.com.evil.example/l/font.ttf',
    'https://evil.example/l/font.ttf',
    'https://fonts.gstatic.com:444/l/font.ttf',
    'https://user@fonts.gstatic.com/l/font.ttf',
    'http://fonts.gstatic.com/l/font.ttf',
  ]) {
    test('does not follow an untrusted font URL: $uri', () async {
      var calls = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (_, _, _) async {
          calls++;
          return _css(uri);
        },
      );
      await expectLater(
        service.load(_font(), 'Subtitle', cancel: CancelToken()),
        throwsFormatException,
      );
      expect(calls, 1);
    });
  }

  test(
    'rejects a missing-glyph fallback rather than showing a false preview',
    () async {
      var loads = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, _, _) async =>
            uri.host == 'fonts.googleapis.com' ? _css() : face,
        fontLoader: (_, _) async => loads++,
      );
      await expectLater(
        service.load(_font(), '中文字幕', cancel: CancelToken()),
        throwsFormatException,
      );
      expect(loads, 0);
    },
  );

  test(
    'retries a failed preview and only caches the successful load',
    () async {
      var attempts = 0, loads = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, _, _) async {
          if (uri.host == 'fonts.googleapis.com') {
            attempts++;
            if (attempts == 1) throw const SocketException('offline');
            return _css();
          }
          return face;
        },
        fontLoader: (_, _) async => loads++,
      );
      await expectLater(
        service.load(_font(), 'Subtitle', cancel: CancelToken()),
        throwsA(isA<SocketException>()),
      );
      expect(
        await service.load(_font(), 'Subtitle', cancel: CancelToken()),
        startsWith('subtitle_preview_'),
      );
      expect(attempts, 2);
      expect(loads, 1);
    },
  );

  test(
    'bounds parallel previews and starts the next only after a job finishes',
    () async {
      final gates = {
        for (final name in ['One', 'Two', 'Three']) name: Completer<void>(),
      };
      final starts = {for (final name in gates.keys) name: Completer<void>()};
      var running = 0, peak = 0;
      final service = SubtitleFontPreviewService(
        maxConcurrent: 2,
        fetchBytes: (uri, _, _) async {
          if (uri.host != 'fonts.googleapis.com') return face;
          final name = uri.queryParameters['family']!.split(':').first;
          running++;
          if (running > peak) peak = running;
          starts[name]!.complete();
          await gates[name]!.future;
          running--;
          return _css();
        },
        fontLoader: (_, _) async {},
      );
      final futures = [
        for (final name in gates.keys)
          service.load(_font(name), 'Subtitle', cancel: CancelToken()),
      ];
      await Future.wait([starts['One']!.future, starts['Two']!.future]);
      expect(starts['Three']!.isCompleted, isFalse);
      gates['One']!.complete();
      await starts['Three']!.future;
      gates['Two']!.complete();
      gates['Three']!.complete();
      expect(await Future.wait(futures), hasLength(3));
      expect(peak, 2);
    },
  );

  test(
    'never contacts a server for a cancelled or official-link-only font',
    () async {
      var calls = 0;
      final service = SubtitleFontPreviewService(
        fetchBytes: (_, _, _) async {
          calls++;
          return face;
        },
      );
      await expectLater(
        service.load(_font(), 'Subtitle', cancel: CancelToken()..cancel()),
        _cancelled,
      );
      const officialOnly = SubtitleOnlineFont(
        name: 'Official only',
        sourceUrl: 'https://www.hanyi.com.cn/productdetail?id=10750',
      );
      await expectLater(
        service.load(officialOnly, 'Subtitle', cancel: CancelToken()),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );
}
