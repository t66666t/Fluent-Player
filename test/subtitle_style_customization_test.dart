import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_parser.dart';
import 'package:video_player_app/utils/subtitle_font_resolver.dart';
import 'package:video_player_app/models/subtitle_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('old styles retain fonts, weights, opacity and dimensions', () {
    final original = const SubtitleStyle();
    final old = original.toJson()
      ..remove('backgroundEnabled')
      ..remove('overallScale');
    final restored = SubtitleStyle.fromJson(old);
    expect(restored.overallScale, 1);
    expect(restored.backgroundEnabled, isTrue);
    expect(
      restored.textStyle.resolvedLanguageFonts['zh'],
      const SubtitleFontChoice('MiSans', 600),
    );
    expect(
      restored.textStyle.resolvedLanguageFonts['en'],
      const SubtitleFontChoice('Comic Relief', 700),
    );
    expect(restored.backgroundOpacity, original.backgroundOpacity);
    final transparent = SubtitleStyle.fromJson({
      ...old,
      'backgroundOpacity': 0,
    });
    expect(transparent.backgroundEnabled, isFalse);
  });

  test('background toggle and removed language survive serialization', () {
    final style =
        const SubtitleTextStyle(
          backgroundColor: Colors.blue,
          backgroundOpacity: .64,
        ).copyWith(
          backgroundEnabled: false,
          languageFonts: {},
          defaultFontFamily: 'Inter',
          defaultFontWeight: 500,
        );
    final reloaded = SubtitleTextStyle.fromJson(style.toJson());
    expect(reloaded.backgroundEnabled, isFalse);
    expect(reloaded.backgroundOpacity, .64);
    expect(reloaded.backgroundColor.toARGB32(), Colors.blue.toARGB32());
    expect(reloaded.resolvedLanguageFonts, isEmpty);
    expect(reloaded.defaultFont, const SubtitleFontChoice('Inter', 500));
  });

  test('overall size scales metrics once and preserves the primary ratio', () {
    const style = SubtitleStyle(
      layoutStyle: SubtitleLayoutStyle(
        fontSize: 40,
        secondaryFontSize: 24,
        lineSpacing: 4,
        letterSpacing: 2,
        overallScale: 1.5,
      ),
    );
    final metrics = SubtitleResolvedStyleMetrics.fromStyle(
      style,
      referenceHeight: 360,
    );
    expect(metrics.fontSize, 30);
    expect(metrics.secondaryFontSize, 18);
    expect(metrics.lineSpacing, 3);
    expect(metrics.letterSpacing, 1.5);
    final resolved = metrics.applyToStyle(style);
    expect(resolved.overallScale, 1);
    expect(
      resolved.effectiveBorderWidth,
      closeTo(
        style.borderWidth * 30 / kSubtitleTextMetricReferenceFontSize,
        .00001,
      ),
    );
    expect(
      SubtitleLayoutStyle.fromJson({'overallScale': double.nan}).overallScale,
      1,
    );
  });

  const multilingual = SubtitleTextStyle(
    defaultFontFamily: 'Inter',
    languageFonts: {
      'zh': SubtitleFontChoice('Noto Sans SC', 500),
      'zh-Hant': SubtitleFontChoice('Traditional', 600),
      'ja': SubtitleFontChoice('Japanese', 400),
      'ko': SubtitleFontChoice('Korean', 700),
      'fr': SubtitleFontChoice('French', 400),
      'ar': SubtitleFontChoice('Arabic', 400),
    },
  );
  test('Japanese kana and Han share a font, including Han-only track cues', () {
    final runs = resolveSubtitleFontRuns('日本語の字幕です', multilingual);
    expect(runs, hasLength(1));
    expect(runs.single.font.family, 'Japanese');
    expect(
      resolveSubtitleFontRuns(
        '字幕',
        multilingual,
        language: 'jpn',
      ).single.font.family,
      'Japanese',
    );
    expect(
      resolveSubtitleFontRuns('字幕', multilingual).single.font.family,
      'Noto Sans SC',
    );
    expect(
      resolveSubtitleFontRuns(
        '字幕',
        multilingual,
        language: 'zh-Hant',
      ).single.font.family,
      'Traditional',
    );
  });
  test(
    'language hints, non-Latin scripts and grapheme clusters survive runs',
    () {
      expect(
        resolveSubtitleFontRuns(
          'Bonjour',
          multilingual,
          language: 'fr-FR',
        ).single.font.family,
        'French',
      );
      expect(
        resolveSubtitleFontRuns(
          'مرحبا بالعالم',
          multilingual,
          language: 'ar',
        ).single.text,
        'مرحبا بالعالم',
      );
      final text = '日本語 Aa e\u0301 👨‍👩‍👧‍👦 𠮷';
      final runs = resolveSubtitleFontRuns(text, multilingual);
      expect(runs.map((r) => r.text).join(), text);
      expect(runs.any((r) => r.text.contains('e\u0301')), isTrue);
      expect(runs.any((r) => r.text.contains('👨‍👩‍👧‍👦')), isTrue);
    },
  );
  test('same family can have different explicit language weights', () {
    const style = SubtitleTextStyle(
      languageFonts: {
        'zh': SubtitleFontChoice('Inter', 400),
        'en': SubtitleFontChoice('Inter', 700),
      },
    );
    final runs = resolveSubtitleFontRuns('字幕 Hello', style);
    expect(runs.first.font.weight, 400);
    expect(runs.last.font.weight, 700);
  });

  test('real OpenType name, weight and Unicode coverage are parsed', () async {
    final font = parseSubtitleFont(
      await File('assets/fonts/Brawler-Regular.otf').readAsBytes(),
    );
    expect(font.family, contains('Brawler'));
    expect(font.weights, [400]);
    expect(font.coverage.any((r) => r[0] <= 65 && r[1] >= 65), isTrue);
    final cjk = parseSubtitleFont(
      await File('assets/fonts/NotoSansCJKsc-Regular.otf').readAsBytes(),
    );
    expect(
      cjk.coverage.any(
        (r) => r[0] <= '字'.runes.single && r[1] >= '字'.runes.single,
      ),
      isTrue,
    );
  });
  test('truncated and malicious OpenType offsets are rejected', () async {
    expect(() => parseSubtitleFont(Uint8List(50)), throwsFormatException);
    final font = await File('assets/fonts/Brawler-Regular.otf').readAsBytes();
    final corrupt = Uint8List.fromList(font);
    ByteData.sublistView(corrupt).setUint32(20, 0xffffffff);
    expect(() => parseSubtitleFont(corrupt), throwsFormatException);
    expect(
      () => parseSubtitleFont(Uint8List.sublistView(font, 0, 100)),
      throwsFormatException,
    );
  });
  test(
    'imports deduplicate, persist, reload and reject missing or changed files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_font_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      var loads = 0;
      final service = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {
          loads++;
        },
      );
      final font = await service.importFile('assets/fonts/Brawler-Regular.otf');
      final duplicate = await service.importFile(
        'assets/fonts/Brawler-Regular.otf',
      );
      expect(duplicate.id, font.id);
      expect(loads, 1);
      expect(font.license, SubtitleFontLicense.unknown);
      final reopened = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {},
      );
      await reopened.ready;
      expect(reopened.find(font.id)!.faceHashes, font.faceHashes);
      await reopened.verifyFiles([font.id]);
      await File(font.path!).writeAsBytes([1, 2, 3]);
      await expectLater(reopened.verifyFiles([font.id]), throwsStateError);
      await File(font.path!).delete();
      await expectLater(reopened.verifyFiles([font.id]), throwsStateError);
    },
  );
  test(
    'manual language is per source and independent for split secondary text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_language_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = SubtitleFontService(storageDirectory: directory);
      await service.ready;
      expect(service.languageForSource('movie.srt', texts: ['日本語の字幕']), 'ja');
      final secondary = service.secondarySource('movie.srt', null)!;
      await service.setSourceLanguage('movie.srt', 'ja');
      await service.setSourceLanguage(secondary, 'en');
      expect(service.languageForSource('movie.srt'), 'ja');
      expect(service.languageForSource(secondary), 'en');
      final reopened = SubtitleFontService(storageDirectory: directory);
      await reopened.ready;
      expect(reopened.languageForSource(secondary), 'en');
      await reopened.setSourceLanguage('movie.srt', 'auto');
      expect(reopened.manualLanguageForSource('movie.srt'), isNull);
    },
  );
  test(
    'font audit includes rendered languages and ignores unused overrides',
    () {
      final service = SubtitleFontService();
      final used = service.familiesForTracks(
        multilingual,
        primary: ['字幕\nBonjour'],
        secondary: [],
        primaryLanguage: 'ja',
        secondaryLanguage: 'fr',
        splitByLine: true,
      );
      expect(used, {'Japanese', 'French'});
    },
  );
  test(
    'downloads validate content and retain licenses; interrupted jobs can retry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_download_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = await File(
        'assets/fonts/Brawler-Regular.otf',
      ).readAsBytes();
      final hash = sha256.convert(bytes).toString();
      var interrupt = true;
      final service = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {},
        fetchBytes: (url, cancel, progress) async {
          if (url.endsWith('OFL.txt')) {
            return Uint8List.fromList(
              utf8.encode('SIL OPEN FONT LICENSE Version 1.1'),
            );
          }
          if (interrupt) throw const SocketException('interrupted');
          progress?.call(bytes.length, bytes.length);
          return bytes;
        },
      );
      final online = SubtitleOnlineFont(
        name: 'Brawler',
        files: const ['https://example.test/font.otf'],
        hashes: [hash],
        licenseFile: 'https://example.test/OFL.txt',
        sourceUrl: 'https://example.test',
        verifiedOn: '2026-10-18',
      );
      await expectLater(
        service.download(online, cancel: CancelToken()),
        throwsA(isA<SocketException>()),
      );
      expect(service.fonts.where((f) => f.path != null), isEmpty);
      interrupt = false;
      final installed = await service.download(online, cancel: CancelToken());
      expect(installed.license, SubtitleFontLicense.commercial);
      expect(installed.licenseText, contains('OPEN FONT LICENSE'));
      expect(
        File('${directory.path}/${installed.id}-LICENSE.txt').existsSync(),
        isTrue,
      );
      final canceled = CancelToken()..cancel();
      await expectLater(
        service.download(online, cancel: canceled),
        throwsA(isA<DioException>()),
      );
      final corrupt = SubtitleOnlineFont(
        name: 'bad',
        files: online.files,
        hashes: const ['wrong'],
        licenseFile: online.licenseFile,
        sourceUrl: online.sourceUrl,
      );
      await expectLater(
        service.download(corrupt, cancel: CancelToken()),
        throwsFormatException,
      );
      await File(installed.path!).delete();
      final repaired = await service.importFile(
        'assets/fonts/Brawler-Regular.otf',
      );
      expect(repaired.id, installed.id);
      await service.verifyFiles([installed.id]);
    },
  );
  test(
    'shipped catalog has pinned files, licenses, Japanese and personal entries',
    () async {
      final catalog = await SubtitleFontService().catalog();
      expect(catalog.length, greaterThan(1000));
      expect(
        catalog.any((f) => f.languages.contains('ja') && f.directDownload),
        isTrue,
      );
      expect(
        catalog.any(
          (f) => f.license == SubtitleFontLicense.personal && !f.directDownload,
        ),
        isTrue,
      );
      for (final family in catalog.where((f) => f.directDownload)) {
        expect(family.files.length, family.hashes.length);
        expect(
          family.files.every(
            (u) => u.contains('47d54ca1ebb14fd864695f1d39dc734f39017c33'),
          ),
          isTrue,
        );
        expect(family.licenseFile, endsWith('/OFL.txt'));
      }
    },
  );
  test(
    'ASS export shares font choices, overall size and disabled background',
    () {
      final ass = VideoComposeAssRenderer(VideoComposeFontService())
          .buildAssContent(
            width: 1280,
            height: 720,
            primary: [
              SubtitleItem(
                index: 0,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 2),
                text: '日本語の字幕',
              ),
            ],
            secondary: [],
            style: SubtitleStyle(
              textStyle: const SubtitleTextStyle(
                backgroundEnabled: false,
                languageFonts: {'ja': SubtitleFontChoice('Inter', 600)},
              ),
              layoutStyle: const SubtitleLayoutStyle(
                fontSize: 40,
                overallScale: 1.5,
              ),
            ),
            alignment: Alignment.bottomCenter,
            primaryLanguage: 'ja',
          );
      expect(ass, contains(r'\fnInter'));
      expect(ass, contains(r'\fs60.00'));
      expect(ass, isNot(contains('Dialogue: 0,')));
    },
  );
}
