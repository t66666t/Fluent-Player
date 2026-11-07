import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/services/subtitle_font_preview_service.dart';
import 'package:video_player_app/utils/subtitle_font_preview.dart';
import 'package:video_player_app/utils/subtitle_font_parser.dart';
import 'package:video_player_app/widgets/subtitle_online_font_preview.dart';

void main() {
  testWidgets(
    'official live CJK and Latin subsets load and paint in the native engine',
    (tester) async {
      final captureKey = GlobalKey();
      final fonts = <SubtitleOnlineFont>[];
      final samples = <SubtitleFontPreviewSample>[];
      final directory = Directory('build/font-preview-verification');
      final byFamily = <String, Uint8List>{};
      final service = SubtitleFontPreviewService(
        fetchBytes: (uri, _, _) async {
          if (uri.host == 'fonts.googleapis.com') {
            final name = uri.queryParameters['family']!.split(':').first;
            return Uint8List.fromList(
              utf8.encode(
                "@font-face { src: url('https://fonts.gstatic.com/l/font?kit=${Uri.encodeQueryComponent(name)}') format('truetype'); }",
              ),
            );
          }
          return byFamily[uri.queryParameters['kit']]!;
        },
      );
      await tester.runAsync(() async {
        await (FontLoader('NativePreviewUi')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        final manifest =
            jsonDecode(
                  await File('${directory.path}/manifest.json').readAsString(),
                )
                as List;
        expect(manifest, hasLength(5));
        for (var index = 0; index < manifest.length; index++) {
          final entry = manifest[index] as Map;
          final bytes = await File(
            '${directory.path}/${entry['file']}',
          ).readAsBytes();
          expect(
            bytes.length,
            lessThanOrEqualTo(SubtitleFontPreviewService.maxFontBytes),
          );
          expect(sha256.convert(bytes).toString(), entry['sha256']);
          final parsed = parseSubtitleFont(bytes);
          final text = entry['text'] as String;
          for (final rune in text.runes) {
            if (String.fromCharCode(rune).trim().isEmpty) continue;
            expect(
              parsed.coverage.any(
                (range) => rune >= range[0] && rune <= range[1],
              ),
              isTrue,
            );
          }
          final name = entry['family'] as String;
          final font = SubtitleOnlineFont(
            name: name,
            files: const [
              'https://raw.githubusercontent.com/google/fonts/revision/ofl/font.ttf',
            ],
            licenseFile:
                'https://raw.githubusercontent.com/google/fonts/revision/ofl/font/OFL.txt',
            sourceUrl: 'https://github.com/google/fonts/tree/revision/ofl/font',
          );
          final sample = subtitleFontPreviewSample([
            entry['language'] as String,
            'en',
          ], preferredLanguage: entry['language'] as String);
          expect(sample.text, text);
          fonts.add(font);
          samples.add(sample);
          byFamily[name] = bytes;
          expect(
            await service.load(font, text, cancel: CancelToken()),
            startsWith('subtitle_preview_'),
          );
        }
      });
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final scenario in [(248.0, 2.0), (390.0, 1.0)]) {
        await tester.binding.setSurfaceSize(Size(scenario.$1, 360));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'NativePreviewUi',
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scenario.$2)),
                  child: RepaintBoundary(
                    key: captureKey,
                    child: Material(
                      color: const Color(0xff202830),
                      child: DefaultTextStyle.merge(
                        style: const TextStyle(
                          fontFamilyFallback: ['NativePreviewUi'],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (
                                var index = 0;
                                index < fonts.length;
                                index++
                              ) ...[
                                Text(
                                  fonts[index].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                SubtitleOnlineFontPreview(
                                  font: fonts[index],
                                  sample: samples[index],
                                  previewService: service,
                                ),
                                const SizedBox(height: 8),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        for (final font in fonts) {
          final preview = find.byKey(
            ValueKey('subtitle-font-preview-sample-${font.name}'),
          );
          expect(preview, findsOneWidget);
          expect(
            tester.getSize(preview).width,
            lessThanOrEqualTo(scenario.$1 - 16),
          );
          expect(tester.getSize(preview).height, lessThanOrEqualTo(20));
        }
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${directory.path}/native-width${scenario.$1.toInt()}-scale${scenario.$2.toInt()}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
    skip: Platform.environment['SUBTITLE_FONT_NATIVE_PREVIEWS'] != '1',
  );
}
