import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_font_preview_service.dart';
import 'package:video_player_app/services/subtitle_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_resolver.dart';
import 'package:video_player_app/widgets/subtitle_font_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new video and audio subtitle defaults use the bundled Swei face',
    () async {
      final settings = SettingsService();
      for (final style in [
        settings.subtitleTextStyle,
        settings.audioSubtitleTextStyle,
      ]) {
        expect(
          style.defaultFont,
          const SubtitleFontChoice('Swei Gothic CJK SC', 700),
        );
        expect(style.resolvedLanguageFonts, isEmpty);
        for (final language in ['zh', 'en']) {
          final text = language == 'zh' ? '字幕' : 'Subtitle';
          expect(
            resolveSubtitleFontRuns(
              text,
              style,
              language: language,
            ).single.font,
            style.defaultFont,
          );
        }
      }
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      final swei = manifest.singleWhere(
        (entry) => entry['family'] == 'Swei Gothic CJK SC',
      );
      expect(
        (swei['fonts'] as List).any(
          (face) => face['asset'] == 'assets/fonts/SweiGothicCJKsc-Bold.ttf',
        ),
        isTrue,
      );
      final noto = manifest.singleWhere(
        (entry) => entry['family'] == 'Noto Sans SC',
      );
      expect(
        (noto['fonts'] as List).single['asset'],
        'assets/fonts/NotoSansSC-Variable.ttf',
      );
      final bundled = SubtitleFontService.bundled.singleWhere(
        (font) => font.id == 'Noto Sans SC',
      );
      expect(
        (bundled.variableWeightMin, bundled.variableWeightMax),
        (100, 900),
      );
    },
  );

  testWidgets('unbundled Noto Serif is recommended and searchable in Chinese', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => SubtitleFontService.instance.ready);
    await tester.runAsync(() => SubtitleFontService.instance.catalog());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleFontSettingsPage(
            style: const SubtitleTextStyle(
              defaultFontFamily: 'Swei Gothic CJK SC',
            ),
            onChanged: (_) {},
            onBack: () {},
            onClose: () {},
            previewService: SubtitleFontPreviewService(
              fetchBytes: (_, _, _) async =>
                  throw StateError('offline preview'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('通用字体'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '思源宋体');
    await tester.pumpAndSettle();
    expect(find.text('推荐字体 · 思源宋体'), findsOneWidget);
    expect(find.text('Noto Serif SC'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subtitle-font-use-Noto Serif SC')),
      findsOneWidget,
    );
  });

  testWidgets('general font applies until a language is explicitly changed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => SubtitleFontService.instance.ready);

    var style = const SubtitleTextStyle(
      defaultFontFamily: 'Swei Gothic CJK SC',
      defaultFontWeight: 700,
      languageFonts: {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SubtitleFontSettingsPage(
              style: style,
              onChanged: (next) => setState(() => style = next),
              onBack: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('跟随通用字体'), findsNWidgets(2));

    Future<void> choose(String row, String fontName) async {
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
      final button = find.byKey(ValueKey('subtitle-font-use-$fontName'));
      await tester.ensureVisible(button);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('字体设置'), findsOneWidget);
    }

    await choose('通用字体', '思源黑体');
    expect(style.defaultFont.family, 'Noto Sans SC');
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('subtitle-font-weight-')),
    );
    expect((slider.min, slider.max), (100, 900));
    slider.onChanged!(575);
    await tester.pump();
    expect(style.defaultFont.weight, 575);
    expect(style.resolvedLanguageFonts, isEmpty);
    expect(
      resolveSubtitleFontRuns('字幕', style, language: 'zh').single.font.family,
      'Noto Sans SC',
    );
    expect(
      resolveSubtitleFontRuns(
        'Subtitle',
        style,
        language: 'en',
      ).single.font.family,
      'Noto Sans SC',
    );

    await choose('中文', '狮尾圆体');
    expect(style.resolvedLanguageFonts['zh']?.family, 'Swei Gothic CJK SC');
    expect(style.resolvedLanguageFonts.containsKey('en'), isFalse);

    await choose('通用字体', 'Comic Relief');
    expect(
      resolveSubtitleFontRuns('字幕', style, language: 'zh').single.font.family,
      'Swei Gothic CJK SC',
    );
    expect(
      resolveSubtitleFontRuns(
        'Subtitle',
        style,
        language: 'en',
      ).single.font.family,
      'Comic Relief',
    );
    final restored = SubtitleTextStyle.fromJson(style.toJson());
    expect(restored.defaultFont, style.defaultFont);
    expect(restored.resolvedLanguageFonts, style.resolvedLanguageFonts);

    await tester.tap(find.byTooltip('恢复通用字体'));
    await tester.pumpAndSettle();
    expect(style.resolvedLanguageFonts, isEmpty);
    expect(
      resolveSubtitleFontRuns('字幕', style, language: 'zh').single.font.family,
      'Comic Relief',
    );
    await choose('英文', 'Brawler');
    expect(style.resolvedLanguageFonts['en']?.family, 'Brawler');
    await choose('通用字体', '思源黑体');
    expect(
      resolveSubtitleFontRuns('字幕', style, language: 'zh').single.font.family,
      'Noto Sans SC',
    );
    expect(
      resolveSubtitleFontRuns(
        'Subtitle',
        style,
        language: 'en',
      ).single.font.family,
      'Brawler',
    );
    expect(tester.takeException(), isNull);
  });
}
