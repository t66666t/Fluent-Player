import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  test(
    'one ASR response supplies sentence and word times; legacy modes remain compatible',
    () async {
      final root = await Directory.systemTemp.createTemp('gongyi_words_');
      addTearDown(() => root.delete(recursive: true));
      final audio = File('${root.path}/audio.m4a')..writeAsBytesSync([1, 2, 3]);
      var tasks = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              Object body;
              if (options.method == 'PUT') {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {},
                    headers: Headers.fromMap({
                      'etag': ['tag'],
                    }),
                  ),
                );
                return;
              }
              if (options.path.endsWith('/resource/create')) {
                body = {
                  'code': 0,
                  'data': {
                    'upload_urls': ['https://test.local/upload'],
                    'per_size': 10,
                    'in_boss_key': 'key',
                    'resource_id': 'r',
                    'upload_id': 'u',
                  },
                };
              } else if (options.path.endsWith('/resource/create/complete')) {
                body = {
                  'code': 0,
                  'data': {'download_url': 'https://test.local/audio'},
                };
              } else if (options.path.endsWith('/task/result')) {
                body = {
                  'code': 0,
                  'data': {
                    'state': 4,
                    'result': jsonEncode({
                      'utterances': [
                        {
                          'start_time': 1000,
                          'end_time': 3000,
                          'transcript': '你好，世界！',
                          'words': [
                            {
                              'label': '你好',
                              'start_time': 1000,
                              'end_time': 1900,
                            },
                            {
                              'label': '世界',
                              'start_time': 2100,
                              'end_time': 3000,
                            },
                          ],
                        },
                        {
                          'start_time': 4000,
                          'end_time': 5000,
                          'transcript': '只有句子',
                        },
                      ],
                    }),
                  },
                };
              } else {
                tasks++;
                body = {
                  'code': 0,
                  'data': {'task_id': 't'},
                };
              }
              handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: body),
              );
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      final service = GongyiAsrService(dio: dio);
      final bound = await service.transcribeAudio(
        audio.path,
        includeWordTimings: true,
      );
      expect(tasks, 1);
      expect(bound.length, 2);
      expect(bound.first.text, '你好，世界！');
      expect(bound.first.timedSpans.length, 2);
      expect(bound.first.timedSpans.last.startTime.inMilliseconds, 2100);
      expect(bound.last.timedSpans, isEmpty);
      final ordinary = await service.transcribeAudio(audio.path);
      expect(ordinary.map((c) => c.text), ['你好，世界！', '只有句子']);
      expect(ordinary.first.timedSpans, isEmpty);
      final flattened = await service.transcribeAudio(
        audio.path,
        needWordTimestamp: true,
      );
      expect(flattened.map((c) => c.text), ['你好', '世界']);
      expect(tasks, 3);
    },
  );
}
