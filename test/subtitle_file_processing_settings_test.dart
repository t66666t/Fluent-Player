import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/subtitle_file_processing_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first use keeps the existing stage defaults', () async {
    final value = await SubtitleFileProcessingSettings.load();
    expect(value.toJson(), {'optimize': false, 'translate': true});
    expect(value.hasWork, isTrue);
  });

  test('legacy optimization is migrated once and then independent', () async {
    const original = SubtitleOptimizationSettings(
      enabled: true,
      connectionId: 'existing-model',
      prompt: 'Preserve this prompt',
    );
    await original.save();
    final value = await SubtitleFileProcessingSettings.load();
    expect(value.optimize, isTrue);
    await original.copyWith(enabled: false).save();
    expect((await SubtitleFileProcessingSettings.load()).optimize, isTrue);
    await SubtitleFileProcessingSettings.update(
      optimize: false,
      translate: false,
    );
    final global = await SubtitleOptimizationSettings.load();
    expect(global.enabled, isFalse);
    expect(global.connectionId, original.connectionId);
    expect(global.prompt, original.prompt);
  });

  test('all four combinations survive reopening, including both off', () async {
    for (final optimize in [false, true]) {
      for (final translate in [false, true]) {
        await SubtitleFileProcessingSettings.update(
          optimize: optimize,
          translate: translate,
        );
        final reopened = await SubtitleFileProcessingSettings.load();
        expect(reopened.toJson(), {
          'optimize': optimize,
          'translate': translate,
        });
        expect(reopened.hasWork, optimize || translate);
      }
    }
  });

  test(
    'rapid edits and an immediate reopen retain the last explicit choices',
    () async {
      final writes = [
        SubtitleFileProcessingSettings.update(optimize: true),
        SubtitleFileProcessingSettings.update(translate: false),
        SubtitleFileProcessingSettings.update(optimize: false),
        SubtitleFileProcessingSettings.update(optimize: true),
      ];
      final reopening = SubtitleFileProcessingSettings.load();
      await Future.wait(writes);
      expect((await reopening).toJson(), {
        'optimize': true,
        'translate': false,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          prefs.getString(SubtitleFileProcessingSettings.preferencesKey)!,
        ),
        {'optimize': true, 'translate': false},
      );
    },
  );

  test('an unreadable preference fails visibly without replacing it', () async {
    SharedPreferences.setMockInitialValues({
      SubtitleFileProcessingSettings.preferencesKey: 'damaged data',
    });
    await expectLater(
      SubtitleFileProcessingSettings.load(),
      throwsFormatException,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        SubtitleFileProcessingSettings.preferencesKey,
      ),
      'damaged data',
    );
    // A failed read must not poison subsequent ordered operations.
    SharedPreferences.setMockInitialValues({});
    expect((await SubtitleFileProcessingSettings.load()).translate, isTrue);
  });
}
