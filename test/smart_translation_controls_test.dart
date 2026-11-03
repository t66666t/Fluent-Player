import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/batch_subtitle_configuration_bar.dart';
import 'package:video_player_app/widgets/transcript_translate_settings_sheet.dart';
import 'package:video_player_app/widgets/translation_language_controls.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [220.0, 320.0, 480.0]) {
    testWidgets('smart rule elements are editable without overflow at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const capture = bool.fromEnvironment('CAPTURE_SMART_TRANSLATION');
      if (capture) {
        final font = FontLoader('SmartPreview')
          ..addFont(rootBundle.load('assets/fonts/OPPO Sans 4.0.ttf'));
        await tester.runAsync(font.load);
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await tester.runAsync(icons.load);
      }
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      final surface = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: surface,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.dark,
              useMaterial3: true,
              fontFamily: capture ? 'SmartPreview' : null,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: TranslationLanguageControls(settings: settings),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings.mode, SubtitleTranslationMode.smart);
      final smartPosition = tester.getTopLeft(
        find.byKey(const ValueKey('translation-mode-smart')),
      );
      final fixedPosition = tester.getTopLeft(
        find.byKey(const ValueKey('translation-mode-fixed')),
      );
      expect(
        smartPosition.dy < fixedPosition.dy ||
            smartPosition.dy == fixedPosition.dy &&
                smartPosition.dx < fixedPosition.dx,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('translation-mode-smart')));
      await tester.pumpAndSettle();
      expect(settings.mode, SubtitleTranslationMode.smart);
      expect(
        find.byKey(const ValueKey('translation-source-language')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('smart-rule-0-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-other-target')), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final boundary =
              surface.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.artifacts/smart-translation-2026-10-21/settings-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      Future<void> choose(String field, String code) async {
        await tester.tap(find.byKey(ValueKey(field)));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('translation-language-auto')),
          findsNothing,
        );
        final original = find.byKey(
          const ValueKey('translation-language-original'),
        );
        expect(
          original,
          field.endsWith('source') ? findsNothing : findsOneWidget,
        );
        final search = find.byKey(
          const ValueKey('translation-language-search'),
        );
        await tester.enterText(search, code);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('translation-language-$code')));
        await tester.pumpAndSettle();
      }

      await choose('smart-rule-0-source', 'ja');
      await choose('smart-rule-0-target', 'ko');
      await choose('smart-other-target', 'fr');
      expect(settings.smartPolicy.rules.single.source, 'ja');
      expect(settings.smartPolicy.rules.single.target, 'ko');
      expect(settings.smartPolicy.otherTarget, 'fr');
      await tester.tap(find.byKey(const ValueKey('smart-add-rule')));
      await tester.pumpAndSettle();
      expect(settings.smartPolicy.rules, hasLength(2));
      await choose('smart-rule-1-target', keepOriginal);
      expect(settings.smartPolicy.rules.last.target, keepOriginal);
      await tester.tap(find.byKey(const ValueKey('smart-rule-1-delete')));
      await tester.pumpAndSettle();
      expect(settings.smartPolicy.rules, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('smart-keep-uncertain')));
      await tester.pumpAndSettle();
      expect(settings.smartPolicy.keepUncertain, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
      final restored = SubtitleTranslateSettings();
      await restored.ensureLoaded();
      addTearDown(restored.dispose);
      expect(restored.mode, SubtitleTranslationMode.smart);
      expect(restored.smartPolicy.rules.single.source, 'ja');
      expect(restored.smartPolicy.otherTarget, 'fr');
    });
  }

  testWidgets(
    'transcription settings sheet scrolls many rules on a short screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setMode(SubtitleTranslationMode.smart);
      await settings.setSmartPolicy(
        const SmartTranslationPolicy(
          rules: [
            SmartTranslationRule(source: 'zh-CN', target: 'en'),
            SmartTranslationRule(source: 'ja', target: 'ko'),
            SmartTranslationRule(source: 'en', target: 'fr'),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTranscriptTranslateSettings(
                  context,
                  settings: settings,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('smart-other-target')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('smart-other-target')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );

  testWidgets(
    'batch configuration shows a compact smart summary and opens the shared rule editor',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SubtitleTranslateSettings();
      await settings.ensureLoaded();
      await settings.setMode(SubtitleTranslationMode.smart);
      await settings.setSmartPolicy(
        const SmartTranslationPolicy(
          rules: [
            SmartTranslationRule(source: 'zh-CN', target: 'en'),
            SmartTranslationRule(source: 'ja', target: 'ko'),
            SmartTranslationRule(source: 'en', target: 'fr'),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                BatchSubtitleConfigurationBar(
                  settings: SettingsService(),
                  translateSettings: settings,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('智能互译：', findRichText: true), findsOneWidget);
      expect(find.textContaining('+2', findRichText: true), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('batch-configuration-bar')))
            .height,
        lessThan(240),
      );
      await tester.tap(
        find.byKey(const ValueKey('batch-translation-settings')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('smart-rule-2-source')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}
