import 'dart:async';
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
    root = await Directory.systemTemp.createTemp('transcription-stop-');
    input = File('${root.path}/transcript.srt')
      ..writeAsStringSync(
        '1\n00:00:00,000 --> 00:00:01,000\nHello\n\n'
        '2\n00:00:01,000 --> 00:00:02,000\nWorld\n',
      );
  });
  tearDown(() async => root.delete(recursive: true));

  Future<SubtitleTranslationResult> start(
    SubtitleTranslationService service,
    SubtitleTranslateProvider provider,
    Completer<void> cancel,
  ) => service.translateSubtitleFile(
    inputPath: input.path,
    sourceLanguage: 'en',
    targetLanguage: 'zh-CN',
    provider: provider,
    onProgress: (_) {},
    cancelSignal: cancel.future,
    aiOptions: const AiSubtitleTranslationSettings(),
  );

  test(
    'stopping translation aborts the in-flight HTTP request and sends no next line',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(),
          release = Completer<void>(),
          cancel = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (!entered.isCompleted) entered.complete();
        await release.future;
        try {
          request.response.write('unused');
          await request.response.close();
        } catch (_) {}
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
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
              options.path = 'http://127.0.0.1:${server.port}/translation';
              options.baseUrl = '';
              handler.next(options);
            },
          ),
        );
      final service = SubtitleTranslationService(dio: dio);
      try {
        final job = start(service, SubtitleTranslateProvider.bing, cancel);
        final done = expectLater(
          job,
          throwsA(
            isA<DioException>().having(
              (e) => CancelToken.isCancel(e),
              'cancelled',
              isTrue,
            ),
          ),
        );
        await entered.future.timeout(const Duration(seconds: 2));
        cancel.complete();
        await done.timeout(const Duration(seconds: 1));
        expect(requests, 1);
        expect(service.isTranslating, isFalse);
        expect(root.listSync().whereType<File>(), hasLength(1));
      } finally {
        release.complete();
        dio.close(force: true);
        service.dispose();
        await server.close(force: true);
      }
    },
  );

  test(
    'stopping AI translation exits without line fallback, retry, or output publication',
    () async {
      final entered = Completer<void>(),
          release = Completer<String>(),
          cancel = Completer<void>();
      var requests = 0;
      final translator = AiSubtitleTranslator(
        loadSettings: () async => const AiChatSettings(
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
          model: 'test',
        ),
        complete: (settings, messages) async {
          requests++;
          if (!entered.isCompleted) entered.complete();
          return release.future;
        },
      );
      final service = SubtitleTranslationService(aiTranslator: translator);
      try {
        final job = start(service, SubtitleTranslateProvider.ai, cancel);
        final done = expectLater(
          job,
          throwsA(isA<AiSubtitleTranslationCancelled>()),
        );
        await entered.future.timeout(const Duration(seconds: 2));
        cancel.complete();
        await done.timeout(const Duration(seconds: 1));
        expect(requests, 1);
        expect(service.isTranslating, isFalse);
        expect(root.listSync().whereType<File>(), hasLength(1));
      } finally {
        release.complete('{}');
        service.dispose();
      }
    },
  );

  test(
    'stopping during Bing dispatch wait prevents the next HTTP request',
    () async {
      final entered = Completer<void>(),
          release = Completer<void>(),
          cancel = Completer<void>();
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data:
                      'IG:"test" <div data-iid="translator">'
                      'var params_AbusePreventionHelper = [123,"test",3600000];',
                ),
              );
            },
          ),
        );
      final client = BingSubtitleTranslator(
        dio: dio,
        now: () => DateTime.utc(2026, 10, 21),
        requestInterval: const Duration(minutes: 1),
        delay: (_) {
          if (!entered.isCompleted) entered.complete();
          return release.future;
        },
      );
      final service = SubtitleTranslationService(
        dio: dio,
        bingTranslator: client,
      );
      try {
        final job = start(service, SubtitleTranslateProvider.bing, cancel);
        final done = expectLater(
          job,
          throwsA(
            isA<DioException>().having(
              (e) => CancelToken.isCancel(e),
              'cancelled',
              isTrue,
            ),
          ),
        );
        await entered.future.timeout(const Duration(seconds: 2));
        cancel.complete();
        await done.timeout(const Duration(seconds: 1));
        expect(requests, 1);
        expect(service.isTranslating, isFalse);
      } finally {
        release.complete();
        dio.close(force: true);
        service.dispose();
      }
    },
  );
}
