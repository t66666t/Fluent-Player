import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/bing_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

void main() {
  late Directory root;
  late File input;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('translation-progress-');
    input = File('${root.path}/input.srt');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'AI batches publish completed item counts while a request is pending',
    () async {
      await input.writeAsString(
        List.generate(
          10,
          (i) =>
              '${i + 1}\n00:00:${i.toString().padLeft(2, '0')},000 --> 00:00:${(i + 1).toString().padLeft(2, '0')},000\nLine $i\n',
        ).join('\n'),
      );
      final secondRequest = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final translator = AiSubtitleTranslator(
        loadSettings: () async => const AiChatSettings(
          baseUrl: 'https://example.test/v1',
          model: 'test',
          apiKey: 'test',
        ),
        complete: (_, messages) async {
          if (++requests == 2) {
            secondRequest.complete();
            await release.future;
          }
          final source =
              jsonDecode(
                    messages.firstWhere((m) => m['role'] == 'user')['content']!,
                  )
                  as Map;
          return jsonEncode({for (final key in source.keys) key: '译文 $key'});
        },
      );
      final service = SubtitleTranslationService(aiTranslator: translator);
      addTearDown(service.dispose);
      var progress = 0.0;
      final updates = <(double, String?)>[];
      final job = service.translateSubtitleFile(
        inputPath: input.path,
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.ai,
        aiOptions: const AiSubtitleTranslationSettings(
          batchSize: 5,
          threadNum: 1,
        ),
        onProgress: (value) => progress = value,
        onActivity: (activity) => updates.add((progress, activity)),
      );
      try {
        await secondRequest.future.timeout(const Duration(seconds: 3));
        expect(service.isTranslating, isTrue);
        expect(progress, 0.5);
        expect(updates.last.$2, contains('已处理 5/10 条'));
        expect(updates.any((entry) => entry.$1 == 1), isFalse);
      } finally {
        release.complete();
      }
      final result = await job;
      expect(updates.first, (0.0, '已处理 0/10 条'));
      expect(updates.last, (1.0, '已处理 10/10 条 · 正在保存翻译字幕'));
      expect(await File(result.outputPath).exists(), isTrue);
      expect(service.isTranslating, isFalse);
      expect(service.activity, isNull);
    },
  );

  test(
    'Bing file translation reports completed item counts while the next batch is pending',
    () async {
      await input.writeAsString(
        '1\n00:00:00,000 --> 00:00:01,000\nFirst line\n\n'
        '2\n00:00:01,000 --> 00:00:02,000\nSecond line\n',
      );
      final secondRequest = Completer<void>(), release = Completer<void>();
      var posts = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.method == 'GET') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data:
                        'IG:"test" <div data-iid="translator">'
                        'var params_AbusePreventionHelper = [123,"test",3600000];',
                  ),
                );
                return;
              }
              if (++posts == 2) {
                secondRequest.complete();
                await release.future;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: [
                    {
                      'translations': [
                        {'text': '译文$posts', 'to': 'zh-Hans'},
                      ],
                    },
                  ],
                ),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      final service = SubtitleTranslationService(
        dio: dio,
        bingTranslator: BingSubtitleTranslator(
          dio: dio,
          batchSize: 1,
          concurrency: 1,
          requestInterval: Duration.zero,
        ),
      );
      addTearDown(service.dispose);
      var progress = 0.0;
      final updates = <(double, String?)>[];
      final job = service.translateSubtitleFile(
        inputPath: input.path,
        sourceLanguage: 'auto',
        targetLanguage: 'zh-CN',
        provider: SubtitleTranslateProvider.bing,
        onProgress: (value) => progress = value,
        onActivity: (activity) => updates.add((progress, activity)),
      );
      try {
        await secondRequest.future.timeout(const Duration(seconds: 2));
        expect(service.isTranslating, isTrue);
        expect(progress, 0.5);
        expect(updates.last.$2, '已处理 1/2 条');
      } finally {
        release.complete();
      }
      final result = await job;
      expect(posts, 2);
      expect(updates.last, (1.0, '已处理 2/2 条 · 正在保存翻译字幕'));
      expect(await File(result.outputPath).readAsString(), contains('译文2'));
    },
  );
}
