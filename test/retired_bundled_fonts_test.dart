import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/models/subtitle_font.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/utils/subtitle_font_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final retired in const ['方正黑体', '方正楷体', '方正黑体简体', '方正楷体简体']) {
    test(
      'saved styles migrate $retired across legacy and multilingual fields',
      () {
        final style = SubtitleStyle.fromJson({
          'fontFamilyChinese': retired,
          'fontFamilyEnglish': 'Inter',
          'defaultFontFamily': retired,
          'defaultFontWeight': 500,
          'languageFonts': {
            'zh': {'family': retired, 'weight': 700},
            'en': {'family': 'Inter', 'weight': 400},
          },
          'fontSize': 42.0,
          'borderWidth': 2.5,
        });
        expect(style.fontFamilyChinese, 'Noto Sans SC');
        expect(style.fontFamilyEnglish, 'Inter');
        expect(
          style.textStyle.defaultFont,
          const SubtitleFontChoice('Noto Sans SC', 500),
        );
        expect(
          style.textStyle.resolvedLanguageFonts['zh'],
          const SubtitleFontChoice('Noto Sans SC', 700),
        );
        expect(
          style.textStyle.resolvedLanguageFonts['en'],
          const SubtitleFontChoice('Inter'),
        );
        expect(style.fontSize, 42);
        expect(style.borderWidth, 2.5);
        expect(jsonEncode(style.toJson()), isNot(contains(retired)));
        expect(
          resolveSubtitleFontRuns(
            '字幕',
            style.textStyle,
            language: 'zh',
          ).single.font,
          const SubtitleFontChoice('Noto Sans SC', 700),
        );
      },
    );
  }

  for (final retired in const ['方正黑体', '方正楷体']) {
    test(
      'legacy $retired renders and exports with the embedded replacement',
      () {
        final style = SubtitleStyle.fromJson({
          'fontFamilyChinese': retired,
          'fontFamilyEnglish': retired,
          'backgroundEnabled': false,
        });
        expect(style.getTextStyle().fontFamily, 'Noto Sans SC');
        final fonts = VideoComposeFontService();
        expect(fonts.requiresBundledFonts(style), isTrue);
        expect(fonts.resolveSystemFont(retired), 'Noto Sans CJK SC');
        final ass = VideoComposeAssRenderer(fonts).buildAssContent(
          width: 1280,
          height: 720,
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 2),
              text: '字幕迁移验证',
            ),
          ],
          secondary: [],
          style: style,
          alignment: Alignment.bottomCenter,
        );
        expect(ass, contains('Style: Default,Noto Sans CJK SC,'));
        expect(ass, isNot(contains(retired)));
      },
    );

    test('persisted danmaku $retired remains a valid font selection', () async {
      SharedPreferences.setMockInitialValues({
        'bilibiliDanmakuFontFamily': retired,
        'bilibiliDanmakuFontWeight': 700,
      });
      final settings = SettingsService();
      settings.resetForTest();
      addTearDown(settings.resetForTest);
      await settings.init();
      expect(settings.bilibiliDanmakuFontFamily, 'Noto Sans SC');
      expect(
        kDanmakuFontFamilies,
        contains(settings.bilibiliDanmakuFontFamily),
      );
      expect(settings.bilibiliDanmakuFontWeight, 700);
    });
  }

  test('custom font IDs remain unchanged on round trip', () {
    const choice = SubtitleFontChoice('subtitle_font_user_asset', 600);
    expect(SubtitleFontChoice.fromJson(choice.toJson()), choice);
  });

  test(
    'built asset manifest excludes retired fonts and retains the OFL fallback',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      expect(jsonEncode(manifest), isNot(contains('方正')));
      final fallback = manifest
          .where((node) => node['family'] == 'Noto Sans SC')
          .single;
      expect(
        (fallback['fonts'] as List).any(
          (face) => face['asset'] == 'assets/fonts/NotoSansCJKsc-Regular.otf',
        ),
        isTrue,
      );
      expect(
        (await rootBundle.load(
          'assets/fonts/NotoSansCJKsc-Regular.otf',
        )).lengthInBytes,
        greaterThan(0),
      );
      expect(
        await rootBundle.loadString('assets/fonts/licenses/NotoSans-OFL.txt'),
        contains('SIL OPEN FONT LICENSE'),
      );
    },
  );
}
