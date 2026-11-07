import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/subtitle_font_preview_service.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_preview.dart';
import 'package:video_player_app/widgets/subtitle_font_settings_page.dart';
import 'package:video_player_app/widgets/subtitle_online_font_preview.dart';

class _PreviewRequest {
  final SubtitleOnlineFont font;
  final String text;
  final CancelToken cancel;
  final Completer<String> result = Completer<String>();

  _PreviewRequest(this.font, this.text, this.cancel);
}

class _PreviewService extends SubtitleFontPreviewService {
  final requests = <_PreviewRequest>[];

  @override
  Future<String> load(
    SubtitleOnlineFont font,
    String text, {
    required CancelToken cancel,
  }) {
    final request = _PreviewRequest(font, text, cancel);
    requests.add(request);
    return request.result.future;
  }
}

class _CatalogService extends SubtitleFontService {
  final List<SubtitleOnlineFont> entries;
  _CatalogService(this.entries);

  @override
  Future<void> get ready => Future.value();

  @override
  Future<List<SubtitleOnlineFont>> catalog() async => entries;
}

SubtitleOnlineFont _font(String name, List<String> languages) =>
    SubtitleOnlineFont(
      name: name,
      languages: languages,
      sourceUrl: 'https://github.com/google/fonts/tree/revision/ofl/$name',
      files: [
        'https://raw.githubusercontent.com/google/fonts/revision/$name.ttf',
      ],
      licenseFile:
          'https://raw.githubusercontent.com/google/fonts/revision/OFL.txt',
    );

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: ThemeData(
    platform: TargetPlatform.android,
    brightness: Brightness.dark,
  ),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets('a specimen appears only after its preview family loads', (
    tester,
  ) async {
    final service = _PreviewService();
    final font = _font('Simplified', ['zh-Hans', 'en']);
    final sample = subtitleFontPreviewSample(font.languages);
    final specimen = find.byKey(
      const ValueKey('subtitle-font-preview-sample-Simplified'),
    );
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 200,
          child: SubtitleOnlineFontPreview(
            font: font,
            sample: sample,
            previewService: service,
          ),
        ),
      ),
    );
    expect(service.requests, isEmpty);
    expect(specimen, findsNothing);
    expect(find.text(sample.primary), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(service.requests, hasLength(1));
    expect(service.requests.single.text, sample.text);
    expect(find.text('正在加载预览'), findsOneWidget);
    expect(specimen, findsNothing);

    service.requests.single.result.complete('LoadedPreviewFamily');
    await tester.pumpAndSettle();
    expect(specimen, findsOneWidget);
    expect(find.text('简体中文 · 英语'), findsNothing);
    expect(find.byTooltip(sample.languageLabel), findsOneWidget);
    expect(sample.text, '字幕预览 Aa');
    expect(sample.secondary, isNull);
    final primary = tester.widget<Text>(find.text(sample.primary));
    expect(primary.style?.fontFamily, 'LoadedPreviewFamily');
    expect(primary.maxLines, 1);
    expect(tester.getSize(specimen).height, lessThanOrEqualTo(24));
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('subtitle-font-preview-Simplified')),
          )
          .height,
      lessThanOrEqualTo(24),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('online rows keep a single compact language specimen', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fonts = [
      _font('Simplified', ['zh-Hans', 'en']),
      _font('Traditional', ['zh-Hant', 'en']),
      _font('Japanese', ['ja', 'en']),
      _font('Korean', ['ko', 'en']),
      _font('Arabic', ['ar', 'en']),
    ];
    for (final width in [200.0, 248.0, 390.0]) {
      for (final scale in [1.0, 2.0]) {
        await tester.binding.setSurfaceSize(Size(width, 500));
        for (final font in fonts) {
          final service = _PreviewService();
          final catalog = _CatalogService([font]);
          final sample = subtitleFontPreviewSample(font.languages);
          await tester.pumpWidget(
            _app(
              SubtitleFontSettingsPage(
                key: UniqueKey(),
                fontService: catalog,
                previewService: service,
                style: const SubtitleTextStyle(
                  defaultFontFamily: 'Swei Gothic CJK SC',
                  defaultFontWeight: 700,
                  languageFonts: {},
                ),
                onChanged: (_) {},
                onBack: () {},
                onClose: () {},
              ),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('通用字体'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('在线'));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 200));
          expect(service.requests, hasLength(1));
          service.requests.single.result.complete('Preview${font.name}');
          await tester.pumpAndSettle();

          final specimen = find.byKey(
            ValueKey('subtitle-font-preview-sample-${font.name}'),
          );
          expect(specimen, findsOneWidget);
          expect(tester.getSize(specimen).height, lessThanOrEqualTo(24));
          final root = find.byKey(
            ValueKey('subtitle-font-preview-${font.name}'),
          );
          expect(tester.getSize(root).height, lessThanOrEqualTo(24));
          expect(find.text(sample.languageLabel), findsNothing);
          expect(find.byTooltip(sample.languageLabel), findsOneWidget);
          expect(sample.text, isNot(contains('\n')));
          expect(sample.secondary, isNull);
          expect(
            find.descendant(of: root, matching: find.byType(Text)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: root, matching: find.byType(DecoratedBox)),
            findsNothing,
          );
          final primary = tester.widget<Text>(find.text(sample.primary));
          expect(primary.textDirection, sample.direction);
          expect(primary.style?.fontFamily, 'Preview${font.name}');
          expect(primary.maxLines, 1);
          expect(
            tester.takeException(),
            isNull,
            reason: '${font.name}, width=$width, scale=$scale',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          catalog.dispose();
        }
      }
    }
  });

  testWidgets('failed previews can retry without installing a font', (
    tester,
  ) async {
    final service = _PreviewService();
    final font = _font('Retry', ['ja', 'en']);
    final sample = subtitleFontPreviewSample(font.languages);
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 180,
          child: SubtitleOnlineFontPreview(
            font: font,
            sample: sample,
            previewService: service,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    service.requests.single.result.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('预览暂不可用'), findsOneWidget);
    expect(find.text(sample.primary), findsNothing);
    final firstCancel = service.requests.single.cancel;
    await tester.tap(
      find.byKey(const ValueKey('subtitle-font-preview-retry-Retry')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(firstCancel.isCancelled, isTrue);
    expect(service.requests, hasLength(2));
    service.requests.last.result.complete('RetriedPreview');
    await tester.pumpAndSettle();
    expect(find.text(sample.primary), findsOneWidget);
    expect(find.text('预览暂不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a short font panel keeps the specimen and download action reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(248, 190));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final font = _font('ShortJapanese', ['ja', 'en']);
      final previewService = _PreviewService();
      final catalog = _CatalogService([font]);
      await tester.pumpWidget(
        _app(
          SubtitleFontSettingsPage(
            fontService: catalog,
            previewService: previewService,
            style: const SubtitleTextStyle(
              defaultFontFamily: 'Swei Gothic CJK SC',
              defaultFontWeight: 700,
              languageFonts: {},
            ),
            onChanged: (_) {},
            onBack: () {},
            onClose: () {},
          ),
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('通用字体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在线'));
      await tester.pumpAndSettle();
      final use = find.byKey(const ValueKey('subtitle-font-use-ShortJapanese'));
      await tester.scrollUntilVisible(
        use,
        60,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(previewService.requests, hasLength(1));
      previewService.requests.single.result.complete('ShortPreview');
      await tester.pumpAndSettle();
      final specimen = find.byKey(
        const ValueKey('subtitle-font-preview-sample-ShortJapanese'),
      );
      await tester.ensureVisible(specimen);
      await tester.pumpAndSettle();
      expect(tester.getSize(specimen).height, lessThanOrEqualTo(24));
      expect(tester.getBottomRight(specimen).dy, lessThanOrEqualTo(190));
      await tester.ensureVisible(use);
      await tester.pumpAndSettle();
      expect(use.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      catalog.dispose();
    },
  );

  testWidgets('an installed font is prepared before showing its sample', (
    tester,
  ) async {
    final font = _font('Installed', ['ja', 'en']);
    final sample = subtitleFontPreviewSample(font.languages);
    final previewService = _PreviewService();
    final prepared = Completer<void>();
    var preparations = 0;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 200,
          child: SubtitleOnlineFontPreview(
            font: font,
            sample: sample,
            previewService: previewService,
            installedFamily: 'AlreadyInstalled',
            prepareInstalled: () {
              preparations++;
              return prepared.future;
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(preparations, 1);
    expect(previewService.requests, isEmpty);
    expect(find.text(sample.primary), findsNothing);
    prepared.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(sample.primary)).style?.fontFamily,
      'AlreadyInstalled',
    );
    expect(previewService.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview work is canceled when a row changes or disappears', (
    tester,
  ) async {
    final service = _PreviewService();
    final first = _font('First', ['zh-Hans', 'en']);
    final second = _font('Second', ['ko', 'en']);
    Widget row(SubtitleOnlineFont font) => _app(
      SizedBox(
        width: 200,
        child: SubtitleOnlineFontPreview(
          key: const ValueKey('reused-row'),
          font: font,
          sample: subtitleFontPreviewSample(font.languages),
          previewService: service,
        ),
      ),
    );

    await tester.pumpWidget(row(first));
    await tester.pump(const Duration(milliseconds: 200));
    final old = service.requests.single;
    await tester.pumpWidget(row(second));
    expect(old.cancel.isCancelled, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(service.requests, hasLength(2));
    old.result.complete('StalePreview');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('subtitle-font-preview-sample-Second')),
      findsNothing,
    );
    service.requests.last.result.complete('SecondPreview');
    await tester.pumpAndSettle();
    final sample = subtitleFontPreviewSample(second.languages);
    expect(
      tester.widget<Text>(find.text(sample.primary)).style?.fontFamily,
      'SecondPreview',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(service.requests.last.cancel.isCancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the color emoji specimen uses a compact bundled image without a font request',
    (tester) async {
      final service = _PreviewService();
      final font = _font('Noto Color Emoji', ['en']);
      final sample = subtitleFontPreviewSample(
        font.languages,
        fontName: font.name,
      );
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 200,
            child: SubtitleOnlineFontPreview(
              font: font,
              sample: sample,
              previewService: service,
            ),
          ),
          scale: 2,
        ),
      );
      final specimen = find.byKey(
        const ValueKey('subtitle-color-emoji-preview'),
      );
      expect(specimen, findsOneWidget);
      final image = tester.widget<Image>(specimen);
      expect(image.image, isA<AssetImage>());
      expect(
        (image.image as AssetImage).assetName,
        'assets/fonts/previews/noto-color-emoji.png',
      );
      await tester.runAsync(() async {
        await precacheImage(image.image, tester.element(specimen));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.requests, isEmpty);
      expect(tester.getSize(specimen).height, lessThanOrEqualTo(20));
      expect(
        tester
            .getSize(
              find.byKey(
                const ValueKey('subtitle-font-preview-Noto Color Emoji'),
              ),
            )
            .height,
        lessThanOrEqualTo(20),
      );
      expect(find.byTooltip('表情符号'), findsOneWidget);
      expect(find.text('表情符号'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quickly discarded rows do not fetch and restricted fonts use the official preview',
    (tester) async {
      final service = _PreviewService();
      final ordinary = _font('Discarded', ['en']);
      await tester.pumpWidget(
        _app(
          SubtitleOnlineFontPreview(
            font: ordinary,
            sample: subtitleFontPreviewSample(ordinary.languages),
            previewService: service,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      expect(service.requests, isEmpty);

      const restricted = SubtitleOnlineFont(
        name: '汉仪个人版',
        languages: ['zh', 'en'],
        license: SubtitleFontLicense.personal,
        sourceUrl: 'https://www.hanyi.com.cn/productdetail?id=10750',
      );
      var opened = false;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 200,
            child: SubtitleOnlineFontPreview(
              font: restricted,
              sample: subtitleFontPreviewSample(restricted.languages),
              previewService: service,
              onOfficialPreview: () => opened = true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.requests, isEmpty);
      expect(find.text('官网预览'), findsOneWidget);
      expect(opened, isFalse);
      await tester.tap(find.text('官网预览'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
