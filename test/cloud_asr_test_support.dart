import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:video_player_app/features/model_center/cloud_asr_types.dart';
import 'package:video_player_app/services/app_storage_service.dart';

// Shapes and units from the vendor references listed in docs/cloud-transcription.md.
// Deliberately small, independently constructed examples; no paid API is called.
Map<String, dynamic> cloudReply(CloudAsrProvider provider) =>
    switch (provider) {
      CloudAsrProvider.elevenlabs => {
        'text': 'Hello world',
        'language_code': 'en',
        'transcription_id': 'transcript-1',
        'new_field': {'ignored': true},
        'words': [
          {'type': 'word', 'text': 'Hello', 'start': 0.1, 'end': 0.4},
          {'type': 'spacing', 'text': ' '},
          {'type': 'word', 'text': 'world', 'start': 0.5, 'end': 0.8},
          {'type': 'audio_event', 'text': '(laughs)', 'start': 0.8, 'end': 1.0},
        ],
      },
      CloudAsrProvider.soniox => {
        'id': 'job-1',
        'tokens': [
          {
            'text': 'Hel',
            'start_ms': 100,
            'end_ms': 250,
            'speaker': '1',
            'language': 'en',
          },
          {
            'text': 'lo',
            'start_ms': 250,
            'end_ms': 400,
            'speaker': '1',
            'language': 'en',
          },
          {
            'text': ' world',
            'start_ms': 500,
            'end_ms': 800,
            'speaker': '1',
            'language': 'en',
          },
          {'text': '<end>'},
        ],
        'new_field': true,
      },
      CloudAsrProvider.assemblyai => {
        'id': 'job-1',
        'status': 'completed',
        'text': 'Hello world',
        'language_code': 'en',
        'speech_model_used': 'universal-3-5-pro',
        'new_field': true,
        'words': [
          {'text': 'Hello', 'start': 100, 'end': 400, 'speaker': 'A'},
          {'text': 'world', 'start': 500, 'end': 800, 'speaker': 'A'},
        ],
      },
      CloudAsrProvider.deepgram => {
        'metadata': {
          'model_info': {
            'opaque-version': {'name': 'nova-3', 'version': 'new-version'},
          },
        },
        'results': {
          'channels': [
            {
              'alternatives': [
                {
                  'transcript': 'Hello world',
                  'words': [
                    {
                      'word': 'hello',
                      'punctuated_word': 'Hello',
                      'language': 'en',
                      'start': 0.1,
                      'end': 0.4,
                    },
                    {
                      'word': 'world',
                      'start': 0.5,
                      'end': 0.8,
                      'language': 'en',
                    },
                  ],
                },
              ],
            },
          ],
        },
        'new_field': true,
      },
      CloudAsrProvider.gemini => {
        'id': 'interactions/example',
        'status': 'completed',
        'new_field': true,
        'steps': [
          {
            'type': 'model_output',
            'content': [
              {
                'type': 'text',
                'text': 'Hello world',
                'annotations': [
                  {
                    'type': 'word_info',
                    'text': 'Hello',
                    'start_offset': '0.100s',
                    'end_offset': '0.400s',
                    'speaker': 'spk_1',
                  },
                  {'type': 'future_annotation', 'value': 1},
                  {
                    'type': 'word_info',
                    'text': 'world',
                    'start_offset': '0.500s',
                    'end_offset': '0.800s',
                    'speaker': 'spk_1',
                  },
                ],
              },
            ],
          },
        ],
      },
    };

CloudAsrConnection cloudConnection(
  CloudAsrProvider provider, {
  String? endpoint,
  String? model,
  String key = 'test-secret',
  String language = 'auto',
  CloudAsrOptions options = const CloudAsrOptions(),
  CloudAsrCapabilities? capabilities,
}) => CloudAsrConnection(
  provider: provider,
  endpoint: endpoint ?? provider.endpoint,
  model: model ?? provider.defaultModel,
  apiKey: key,
  language: language,
  options: options,
  capabilities:
      capabilities ??
      cloudAsrCapabilities(provider, model ?? provider.defaultModel),
);

class CloudWireRequest {
  CloudWireRequest(HttpRequest request, this.bytes)
    : method = request.method,
      uri = request.uri {
    request.headers.forEach((name, values) => headers[name] = values.join(','));
  }
  final String method;
  final Uri uri;
  final headers = <String, String?>{};
  final List<int> bytes;
  String get text => utf8.decode(bytes, allowMalformed: true);
  Map<String, dynamic> get json =>
      Map<String, dynamic>.from(jsonDecode(text) as Map);
}

class CloudWireServer {
  CloudWireServer._(this.server);
  final HttpServer server;
  final requests = <CloudWireRequest>[];
  String get endpoint => 'http://127.0.0.1:${server.port}';
  FutureOr<void> Function(CloudWireRequest, HttpResponse)? handler;
  static Future<CloudWireServer> start() async {
    final server = CloudWireServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.server.listen((request) async {
      final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      final received = CloudWireRequest(request, bytes);
      server.requests.add(received);
      request.response.headers.contentType = ContentType.json;
      try {
        if (server.handler != null) {
          await server.handler!(received, request.response);
        }
      } finally {
        await request.response.close();
      }
    });
    return server;
  }

  Future<void> close() => server.close(force: true);
}

Future<AppStorageService> cloudTestStorage(Directory root) async {
  final storage = AppStorageService(
    locations: () async => StorageLocations(
      platform: StoragePlatform.windows,
      support: Directory('${root.path}/support'),
      documents: Directory('${root.path}/documents'),
      defaultData: Directory('${root.path}/data'),
      executable: Directory('${root.path}/executable'),
    ),
  );
  await storage.initialize();
  return storage;
}

Dio cloudTestDio() => Dio();
