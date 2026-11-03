import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('SMART_TRANSLATION_LIVE');
  test('Bing translates mixed scripts through its real web adapter', () async {
    SharedPreferences.setMockInitialValues({});
    // flutter_tester has no native system-proxy plugin. Keep this explicit
    // live transport separate from the app's unchanged NetworkHttp settings.
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
      ),
    );
    final service = SubtitleTranslationService(dio: dio);
    addTearDown(service.dispose);
    addTearDown(() => dio.close(force: true));
    final cancelled = Completer<void>();
    final texts = [
      '大家好，欢迎来到这里。',
      'Please sit down and take a break.',
      '皆さん、こんにちは。お元気ですか。',
      '안녕하세요. 오늘 날씨가 좋아요.',
      'Bonjour tout le monde. Merci pour votre aide.',
      '<i>大家好。</i> Please sit down.ありがとう。',
    ];
    final watch = Stopwatch()..start();
    final output = await HttpOverrides.runWithHttpOverrides(
      () => service
          .translateCueBatch(
            items: [
              for (final (index, text) in texts.indexed)
                SubtitleItem(
                  index: index + 1,
                  startTime: Duration(seconds: index),
                  endTime: Duration(seconds: index + 1),
                  text: text,
                ),
            ],
            sourceLanguage: 'auto',
            targetLanguage: 'mul',
            provider: SubtitleTranslateProvider.bing,
            smartPolicy: const SmartTranslationPolicy(),
            cancelSignal: cancelled.future,
            onProgress: (_) {},
          )
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () {
              if (!cancelled.isCompleted) cancelled.complete();
              throw TimeoutException(
                'Bing smart translation live test exceeded 45 seconds',
              );
            },
          ),
      _RealHttp(),
    );
    watch.stop();
    await File(
      '.artifacts/smart-translation-2026-10-21/bing-live.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'elapsedMs': watch.elapsedMilliseconds,
        'source': texts,
        'translation': output,
      }),
    );
    expect(output, hasLength(texts.length));
    expect(RegExp(r'[A-Za-z]{3}').hasMatch(output[0]), isTrue);
    for (var i = 1; i <= 4; i++) {
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(output[i]),
        isTrue,
        reason: output[i],
      );
    }
    expect(output.last, contains('<i>'));
    expect(output.last, contains('</i>'));
    expect(RegExp(r'[A-Za-z]{3}').hasMatch(output.last), isTrue);
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(output.last), isTrue);
    expect(output.last, isNot(contains('ありがとう')));
  }, skip: !live);
}
