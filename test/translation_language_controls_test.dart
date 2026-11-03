import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/transcript_translate_settings_sheet.dart';
import 'package:video_player_app/widgets/translation_language_controls.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [320.0, 480.0]) {
    testWidgets('compact direction and service remain visible at $width', (
      tester,
    ) async {
      const capture = bool.fromEnvironment('CAPTURE_TRANSLATION_DIRECTIONS');
      if (capture) {
        final font = FontLoader('DirectionPreview')
          ..addFont(rootBundle.load('assets/fonts/OPPO Sans 4.0.ttf'));
        await tester.runAsync(font.load);
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await tester.runAsync(icons.load);
      }
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setMode(SubtitleTranslationMode.fixed);
      final repaint = GlobalKey();
      final surface = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              useMaterial3: true,
              fontFamily: capture ? 'DirectionPreview' : null,
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: repaint,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    TranslationDirectionSummary(
                      settings: settings,
                      onOpen: (selected) => showTranscriptTranslateSettings(
                        tester.element(find.byKey(repaint)),
                        settings: selected,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const FilledButton(onPressed: null, child: Text('转录并翻译')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自动检测 → 简体中文'), findsOneWidget);
      expect(find.text('必应翻译'), findsOneWidget);
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('translation-direction-summary')),
            )
            .height,
        lessThanOrEqualTo(54),
      );
      expect(tester.takeException(), isNull);
      Future<void> screenshot(GlobalKey key, String name) async {
        if (!capture) return;
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '.artifacts/translation-directions-2026-10-21/$name-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await screenshot(repaint, 'direction');
      await tester.tap(
        find.byKey(const ValueKey('translation-direction-summary')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('translation-source-language')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('translation-target-language')),
        findsOneWidget,
      );
      await screenshot(surface, 'settings');
      await tester.tap(
        find.byKey(const ValueKey('translation-source-language')),
      );
      await tester.pumpAndSettle();
      final auto = find.byKey(const ValueKey('translation-language-auto'));
      expect(auto, findsOneWidget);
      final chinese = find.byKey(const ValueKey('translation-language-zh-CN'));
      expect(
        tester.getTopLeft(auto).dy,
        lessThan(tester.getTopLeft(chinese).dy),
      );
      expect(find.text('当前翻译：必应翻译'), findsWidgets);
      await screenshot(surface, 'languages');
      await tester.tap(find.byKey(const ValueKey('translation-language-ja')));
      await tester.pumpAndSettle();
      expect(settings.sourceLanguage, 'ja');
      expect(settings.targetLanguage, 'zh-CN');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    });
  }

  testWidgets(
    'language picker shows its AI model, searches languages, and keeps target explicit',
    (tester) async {
      final settings = SubtitleTranslateSettings(
        readApiSettings: () async => const AiSubtitleApiSettings(
          providerId: 'custom',
          baseUrl: 'https://models.example/v1',
          model: 'translator-a',
        ),
      );
      await settings.setProviderEnZh(SubtitleTranslateProvider.ai);
      await settings.setMode(SubtitleTranslationMode.fixed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TranslationLanguageControls(settings: settings)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('models.example · translator-a'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('translation-target-language')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('translation-language-auto')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('translation-language-search')),
        '俄语',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('translation-language-ru')));
      await tester.pumpAndSettle();
      expect(settings.targetLanguage, 'ru');
      expect(settings.sourceLanguage, 'auto');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}
