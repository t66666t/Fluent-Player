import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_parser.dart';
import 'package:video_player_app/widgets/subtitle_font_settings_page.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';

const _fixture = 'test/fixtures/fonts/RobotoSlab-VariableFont_wght.ttf';

class _Paths extends PathProviderPlatform {
  final String directory;
  _Paths(this.directory);
  @override
  Future<String?> getApplicationSupportPath() async => directory;
  @override
  Future<String?> getTemporaryPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory uiDirectory;
  late Directory paintDirectory;
  late SubtitleFontService uiService;
  late SubtitleFontAsset uiFont;
  late SubtitleFontAsset paintFont;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    uiDirectory = await Directory.systemTemp.createTemp(
      'subtitle_variable_ui_',
    );
    paintDirectory = await Directory.systemTemp.createTemp(
      'subtitle_variable_paint_',
    );
    final bytes = await File(_fixture).readAsBytes();
    uiService = SubtitleFontService(
      storageDirectory: uiDirectory,
      fontLoader: (_, _) async {},
      fetchBytes: (url, _, _) async => url.endsWith('LICENSE')
          ? Uint8List.fromList(utf8.encode('Apache License'))
          : bytes,
    );
    await uiService.importFile('assets/fonts/Brawler-Regular.otf');
    uiFont = await uiService.download(
      SubtitleOnlineFont(
        name: 'Roboto Slab',
        sourceUrl: 'https://example.test/roboto-slab',
        files: const ['https://example.test/font.ttf'],
        hashes: [sha256.convert(bytes).toString()],
        licenseFile: 'https://example.test/LICENSE',
      ),
      cancel: CancelToken(),
    );
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(paintDirectory.path);
    paintFont = await SubtitleFontService.instance.importFile(_fixture);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    await uiDirectory.delete(recursive: true);
    await paintDirectory.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'new downloads come first and existing variable fonts gain axis metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_variable_font_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = await File(_fixture).readAsBytes();
      final parsed = parseSubtitleFont(bytes);
      expect(parsed.variableWeightRange, (100, 900));
      expect(parseSubtitleFontWeightAxis(bytes), (100, 900));
    final broken = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(broken);
    final count = data.getUint16(4);
    final entry = List.generate(count, (i) => 12 + i * 16).singleWhere(
      (offset) => data.getUint32(offset) == 0x66766172,
    );
    data.setUint16(data.getUint32(entry + 8) + 4, 0xffff);
    expect(() => parseSubtitleFontWeightAxis(broken), throwsFormatException);
    expect(() => parseSubtitleFont(broken), throwsFormatException);
      final staticBytes = await File(
        'assets/fonts/Brawler-Regular.otf',
      ).readAsBytes();
      expect(parseSubtitleFontWeightAxis(staticBytes), isNull);

      final service = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {},
        fetchBytes: (url, _, _) async => url.endsWith('LICENSE')
            ? Uint8List.fromList(utf8.encode('Apache License'))
            : bytes,
      );
      final older = await service.importFile(
        'assets/fonts/Brawler-Regular.otf',
      );
      final online = SubtitleOnlineFont(
        name: 'Roboto Slab',
        sourceUrl: 'https://example.test/roboto-slab',
        files: const ['https://example.test/font.ttf'],
        hashes: [sha256.convert(bytes).toString()],
        licenseFile: 'https://example.test/LICENSE',
      );
      final newer = await service.download(online, cancel: CancelToken());
      expect(newer.hasVariableWeight, isTrue);
      expect((newer.variableWeightMin, newer.variableWeightMax), (100, 900));
      expect(service.fonts.take(2).map((font) => font.id), [
        newer.id,
        older.id,
      ]);

      final registry = File('${directory.path}/library.json');
      final saved = jsonDecode(await registry.readAsString()) as List;
      final oldEntry = saved.cast<Map>().singleWhere(
        (item) => item['id'] == newer.id,
      );
      oldEntry.remove('weightAxisChecked');
      oldEntry.remove('variableWeightMin');
      oldEntry.remove('variableWeightMax');
      await registry.writeAsString(jsonEncode(saved));
      final reopened = SubtitleFontService(
        storageDirectory: directory,
        fontLoader: (_, _) async {},
      );
      await reopened.ready;
      expect(reopened.fonts.take(2).map((font) => font.id), [
        newer.id,
        older.id,
      ]);
      expect(reopened.find(newer.id)!.weightAxisChecked, isFalse);
      await reopened.ensureLoaded(newer.id);
      expect(reopened.find(newer.id)!.hasVariableWeight, isTrue);
      final updated = (jsonDecode(await registry.readAsString()) as List)
          .cast<Map>()
          .singleWhere((item) => item['id'] == newer.id);
      expect(updated['variableWeightMin'], 100);
      expect(updated['variableWeightMax'], 900);
    },
  );

  testWidgets(
    'downloaded fonts appear first and variable weight uses a slider',
    (tester) async {
      final service = uiService;
      var style = const SubtitleTextStyle(
        defaultFontFamily: 'Swei Gothic CJK SC',
        defaultFontWeight: 700,
        languageFonts: {},
      );
      await tester.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SubtitleFontSettingsPage(
                fontService: service,
                style: style,
                onChanged: (value) => setState(() => style = value),
                onBack: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subtitle-font-weight-')), findsNothing);
      await tester.tap(find.text('通用字体'));
      await tester.pumpAndSettle();
      expect(find.text('已下载和导入'), findsOneWidget);
      expect(find.text('内置字体'), findsOneWidget);
      final downloaded = find.byKey(
        const ValueKey('subtitle-font-use-Roboto Slab'),
      );
      final imported = find
          .byKey(const ValueKey('subtitle-font-use-Brawler'))
          .first;
      expect(
        tester.getTopLeft(downloaded).dy,
        lessThan(tester.getTopLeft(imported).dy),
      );
      await tester.runAsync(() async {
        tester.widget<TextButton>(downloaded).onPressed!();
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (style.defaultFont.family != uiFont.id &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(style.defaultFont.family, uiFont.id);
      final slider = find.byKey(const ValueKey('subtitle-font-weight-'));
      expect(slider, findsOneWidget);
      final rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.left + rect.width * .43, rect.center.dy));
      await tester.pumpAndSettle();
      expect(style.defaultFont.weight, inInclusiveRange(100, 900));
      expect(style.defaultFont.weight % 100, isNot(0));
      expect(
        style.defaultFont.fontVariations!.single.value,
        style.defaultFont.weight.toDouble(),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final size in [const Size(320, 568), const Size(248, 320)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'intermediate weights change actual subtitle pixels and ASS tags',
    (tester) async {
      final font = paintFont;
      final boundary = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(640, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      SubtitleStyle style(int weight) => SubtitleStyle(
        textStyle: SubtitleTextStyle(
          defaultFontFamily: font.id,
          defaultFontWeight: weight,
          languageFonts: const {},
          backgroundEnabled: false,
          hasBorder: false,
          hasShadow: false,
        ),
        layoutStyle: const SubtitleLayoutStyle(fontSize: 70),
      );

      Future<String> pixels(int weight) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: RepaintBoundary(
                key: boundary,
                child: SubtitleOverlayGroup(
                  entries: const [
                    SubtitleOverlayEntry(text: 'Hamburgefontsiv'),
                  ],
                  style: style(weight),
                  alignment: Alignment.center,
                  referenceHeight: 300,
                  enableDebugPreview: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
              .toImage();
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return sha256.convert(pixels!.buffer.asUint8List()).toString();
        }))!;
      }

      final normal = await pixels(400);
      final intermediate = await pixels(450);
      final bold = await pixels(700);
      expect(intermediate, isNot(normal));
      expect(intermediate, isNot(bold));

      final ass = VideoComposeAssRenderer(VideoComposeFontService())
          .buildAssContent(
            width: 640,
            height: 360,
            primary: [
              SubtitleItem(
                index: 0,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 1),
                text: 'Subtitle',
              ),
            ],
            secondary: [],
            style: style(450),
            alignment: Alignment.center,
          );
      expect(ass, contains(r'\b450'));
      expect(tester.takeException(), isNull);
    },
  );
}
