import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';

class _RealHttpOverrides extends HttpOverrides {}

HttpClient _realClient() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttpOverrides());

HttpClient _redirectClient(HttpServer server) {
  final client = _realClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) =>
      Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
  return client;
}

const _messages = <Map<String, String>>[
  {'role': 'user', 'content': '请总结视频。'},
];

class _ConnectionProbe extends AiChatTransport {
  AiChatSettings? sent;
  @override
  Stream<AiChatDelta> stream({
    required AiChatSettings settings,
    required List<Map<String, String>> messages,
    required AiChatCancellation cancellation,
  }) async* {
    sent = settings;
    yield const AiChatDelta(content: 'OK');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'model endpoint handles provider roots and full completion URLs safely',
    () {
      expect(
        AiChatTransport.modelsUri('https://api.openai.com').toString(),
        'https://api.openai.com/v1/models',
      );
      expect(
        AiChatTransport.modelsUri('https://api.deepseek.com/').path,
        '/models',
      );
      expect(
        AiChatTransport.modelsUri(
          'https://example.com/v1/chat/completions?version=2',
        ).toString(),
        'https://example.com/v1/models?version=2',
      );
      expect(
        AiChatTransport.modelsUri('http://localhost:11434/v1/models').path,
        '/v1/models',
      );
      expect(
        () => AiChatTransport.modelsUri('https://secret@example.com'),
        throwsA(isA<AiChatException>()),
      );
    },
  );

  test(
    'real GET directory preserves rich metadata, explicit denials and arbitrary IDs',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestDetails = Completer<List<String?>>();
      server.listen((request) async {
        requestDetails.complete([
          request.method,
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader),
        ]);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': 'deepseek-flash',
                'name': 'Service Flash',
                'context_window': 131072,
                'max_output_tokens': 32768,
                'effort': {
                  'supported_levels': ['max', 'low'],
                  'default_level': 'max',
                },
                'thinking_types': ['enabled', 'disabled'],
                'supports_thinking_budget': false,
              },
              {
                'id': 'deepseek-v4-pro',
                'supports_thinking': false,
                'supports_reasoning_effort': false,
              },
              {
                'id': 'my-custom-model',
                'created': 1704067200,
                'description': '自建模型',
              },
              {'id': 'my-custom-model'},
              {'id': ''},
              17,
              {'name': 'missing id'},
            ],
          }),
        );
        await request.response.close();
      });
      const settings = AiChatSettings(
        baseUrl: 'http://api.deepseek.com/v1',
        apiKey: 'catalog-key',
      );
      final models = await AiChatTransport(
        httpClientFactory: () => _redirectClient(server),
      ).fetchModels(settings);
      expect(await requestDetails.future, [
        'GET',
        '/v1/models',
        'Bearer catalog-key',
      ]);
      expect(models.map((model) => model.id), [
        'deepseek-flash',
        'deepseek-v4-pro',
        'my-custom-model',
      ]);
      expect(models.first.displayName, 'Service Flash');
      expect(models.first.contextWindow, 131072);
      expect(models.first.maxOutputTokens, 32768);
      expect(models.first.reasoningEfforts, ['max', 'low']);
      expect(models.first.lowestReasoningEffort, 'low');
      expect(models.first.supportsThinkingBudget, isFalse);
      expect(models[1].supportsThinking, isFalse);
      expect(models[1].supportsReasoningEffort, isFalse);
      expect(models[1].reasoningEfforts, isEmpty);
      expect(models[2].supportsThinking, isNull);
      expect(models[2].description, '自建模型');
      expect(models[2].releasedAt?.toUtc(), DateTime.utc(2024, 1, 1));
      final denied = settings.copyWith(
        model: models[1].id,
        savedModels: models,
        modelCatalogBaseUrl: settings.baseUrl,
      );
      final body = AiChatTransport.apiRequestBody(denied, _messages);
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['temperature'], 0.3);
    },
  );
  test(
    'Alibaba ID-only model directory fills verified limits but preserves explicit ceilings',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'qwen-plus'},
              {'id': 'glm_5.3_prime'},
              {
                'id': 'qwen-flash',
                'max_input_tokens': 24000,
                'context_window': 32768,
                'max_output_tokens': 4096,
              },
              {'id': 'unverified-private-model'},
            ],
          }),
        );
        await request.response.close();
      });
      const settings = AiChatSettings(
        baseUrl: 'http://dashscope.aliyuncs.com/compatible-mode/v1',
        apiKey: 'local-test-key',
      );
      final models = await AiChatTransport(
        httpClientFactory: () => _redirectClient(server),
      ).fetchModels(settings);
      expect(models[0].contextWindow, 1000000);
      expect(models[0].maxThinkingInputTokens, 995904);
      expect(models[1].contextWindow, 1048576);
      expect(models[1].canDisableThinking, isFalse);
      expect(models[2].contextWindow, 32768);
      expect(models[2].maxInputTokens, 24000);
      expect(models[2].inputLimit(thinking: true), 24000);
      expect(models[2].maxOutputTokens, 4096);
      expect(models[3].contextWindow, isNull);
    },
  );

  test(
    'OpenRouter directory controls exact effort, mandatory reasoning and budgets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': 'provider/optional',
                'supported_parameters': ['reasoning'],
              },
              {
                'id': 'provider/mandatory',
                'reasoning': {
                  'supported_efforts': ['max', 'high', 'low'],
                  'mandatory': true,
                },
              },
              {
                'id': 'provider/budget',
                'reasoning': {'supports_max_tokens': true, 'mandatory': false},
              },
            ],
          }),
        );
        await request.response.close();
      });
      const settings = AiChatSettings(baseUrl: 'http://openrouter.ai/api/v1');
      final models = await AiChatTransport(
        httpClientFactory: () => _redirectClient(server),
      ).fetchModels(settings);
      AiChatSettings selected(String id) => settings.copyWith(
        model: id,
        savedModels: models,
        modelCatalogBaseUrl: settings.baseUrl,
      );
      final optional = selected('provider/optional');
      expect(optional.selectedModelInfo!.canDisableThinking, isTrue);
      expect(
        AiChatTransport.apiRequestBody(
          optional.copyWith(thinkingEnabled: false),
          _messages,
        )['reasoning'],
        {'enabled': false},
      );
      expect(AiChatTransport.apiRequestBody(optional, _messages)['reasoning'], {
        'effort': 'high',
      });
      final mandatory = selected('provider/mandatory');
      expect(mandatory.selectedModelInfo!.canDisableThinking, isFalse);
      expect(mandatory.selectedModelInfo!.reasoningEfforts, [
        'max',
        'high',
        'low',
      ]);
      expect(
        AiChatTransport.apiRequestBody(
          mandatory.copyWith(thinkingEnabled: false),
          _messages,
        )['reasoning'],
        {'effort': 'low'},
      );
      final budget = selected('provider/budget');
      expect(budget.selectedModelInfo!.supportsReasoningEffort, isFalse);
      expect(AiChatTransport.apiRequestBody(budget, _messages)['reasoning'], {
        'enabled': true,
      });
      expect(
        AiChatTransport.apiRequestBody(
          budget.copyWith(thinkingBudget: 2048),
          _messages,
        )['reasoning'],
        {'max_tokens': 2048},
      );
    },
  );

  test(
    'provider-specific thinking flags stay on verified hosts and models',
    () {
      const settings = AiChatSettings();
      Map<String, dynamic> body(AiChatSettings config) =>
          AiChatTransport.apiRequestBody(config, _messages);
      expect(body(settings)['reasoning_effort'], 'high');
      final deepSeekOff = body(settings.copyWith(thinkingEnabled: false));
      expect(deepSeekOff['thinking'], {'type': 'disabled'});
      expect(deepSeekOff.containsKey('reasoning_effort'), isFalse);
      final qwen = settings.copyWith(
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        model: 'qwen3.8-max',
        thinkingBudget: 2048,
      );
      expect(body(qwen)['enable_thinking'], isTrue);
      expect(body(qwen)['thinking_budget'], 2048);
      expect(body(qwen).containsKey('reasoning_effort'), isFalse);
      expect(
        body(qwen.copyWith(thinkingEnabled: false))['enable_thinking'],
        isFalse,
      );
      final qwenOnly = body(
        qwen.copyWith(model: 'qwen3.8-2.4t-a95b', thinkingEnabled: false),
      );
      expect(qwenOnly.containsKey('enable_thinking'), isFalse);
      expect(qwenOnly.containsKey('temperature'), isFalse);
      final glm = settings.copyWith(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-5.2',
      );
      final glmOff = body(glm.copyWith(thinkingEnabled: false, temperature: 2));
      expect(glmOff['thinking'], {'type': 'disabled'});
      expect(glmOff.containsKey('reasoning_effort'), isFalse);
      expect(glmOff['temperature'], 1.0);
      expect(
        body(
          glm.copyWith(
            model: 'custom-glm-id',
            thinkingEnabled: false,
            temperature: 2,
          ),
        )['temperature'],
        1.0,
      );
      expect(glm.selectedModelInfo!.maxOutputTokens, isNull);
      expect(
        body(
          glm.copyWith(model: 'glm-5.3', thinkingEnabled: false),
        )['reasoning_effort'],
        'low',
      );
      final unknown = body(
        settings.copyWith(
          baseUrl: 'https://my-gateway.example/v1',
          model: 'qwen3.8-max',
          thinkingBudget: 2048,
        ),
      );
      for (final flag in [
        'thinking',
        'enable_thinking',
        'thinking_budget',
        'reasoning',
        'reasoning_effort',
      ]) {
        expect(unknown.containsKey(flag), isFalse, reason: flag);
      }
    },
  );

  test(
    'verified OpenAI optional and mandatory reasoning have distinct request parameters',
    () {
      const luna = AiChatSettings(
        baseUrl: 'https://api.openai.com',
        model: 'gpt-6-luna',
        thinkingEnabled: false,
      );
      expect(luna.selectedModelInfo!.canDisableThinking, isTrue);
      expect(
        AiChatTransport.apiRequestBody(luna, _messages)['reasoning_effort'],
        'none',
      );
      expect(
        AiChatTransport.apiRequestBody(
          luna,
          _messages,
        )['max_completion_tokens'],
        8192,
      );
      final astra = luna.copyWith(model: 'gpt-6-astra');
      expect(astra.selectedModelInfo!.canDisableThinking, isFalse);
      expect(
        AiChatTransport.apiRequestBody(astra, _messages)['reasoning_effort'],
        'low',
      );
      expect(
        luna.copyWith(model: 'gpt-5.1').selectedModelInfo!.canDisableThinking,
        isTrue,
      );
      expect(
        luna.copyWith(model: 'gpt-5.2').selectedModelInfo!.reasoningEfforts,
        ['low', 'medium', 'high', 'xhigh'],
      );
      expect(luna.copyWith(model: 'gpt-9-unknown').selectedModelInfo, isNull);
      final generic = luna.copyWith(
        baseUrl: 'https://custom.example/v1',
        savedModels: const [
          AiModelInfo(
            id: 'gpt-6-luna',
            supportsThinking: true,
            supportsReasoningEffort: true,
            thinkingTypes: ['enabled', 'disabled'],
          ),
        ],
        modelCatalogBaseUrl: 'https://custom.example/v1',
      );
      expect(
        AiChatTransport.apiRequestBody(
          generic,
          _messages,
        ).containsKey('reasoning_effort'),
        isFalse,
      );
    },
  );

  test(
    'declared model limits and effort are enforced without blocking arbitrary IDs',
    () {
      const url = 'http://localhost:1234/v1';
      const settings = AiChatSettings(
        baseUrl: url,
        model: 'custom',
        contextTokens: 8192,
        maxOutputTokens: 2048,
        savedModels: [
          AiModelInfo(
            id: 'custom',
            contextWindow: 8192,
            maxOutputTokens: 2048,
            supportsThinking: true,
            supportsReasoningEffort: true,
            reasoningEfforts: ['low', 'high'],
          ),
        ],
        modelCatalogBaseUrl: url,
      );
      expect(
        () => AiChatTransport.apiRequestBody(settings, _messages),
        returnsNormally,
      );
      expect(
        () => AiChatTransport.apiRequestBody(
          settings.copyWith(maxOutputTokens: 4096),
          _messages,
        ),
        throwsA(isA<AiChatException>()),
      );
      expect(
        () => AiChatTransport.apiRequestBody(
          settings.copyWith(contextTokens: 16000),
          _messages,
        ),
        throwsA(isA<AiChatException>()),
      );
      expect(
        () => AiChatTransport.apiRequestBody(
          settings.copyWith(reasoningEffort: 'max'),
          _messages,
        ),
        throwsA(isA<AiChatException>()),
      );
      expect(
        () => AiChatTransport.apiRequestBody(
          settings.copyWith(model: 'hand-written-id'),
          _messages,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'connection probe chooses lowest supported reasoning and a useful mandatory budget',
    () async {
      final probe = _ConnectionProbe();
      final token = AiChatCancellation();
      await probe.testConnection(
        const AiChatSettings(
          apiProtocol: AiApiProtocol.gemini,
          model: 'gemini-test',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          modelCatalogBaseUrl:
              'https://generativelanguage.googleapis.com/v1beta',
          modelCatalogProtocol: AiApiProtocol.gemini,
          savedModels: [
            AiModelInfo(
              id: 'gemini-test',
              supportsThinking: true,
              canDisableThinking: false,
              reasoningEfforts: ['high', 'low'],
            ),
          ],
        ),
        cancellation: token,
      );
      expect(probe.sent!.maxOutputTokens, 4096);
      expect(probe.sent!.thinkingEnabled, isTrue);
      expect(probe.sent!.reasoningEffort, 'low');
      expect(token.isCancelled, isTrue);
      await probe.testConnection(const AiChatSettings());
      expect(probe.sent!.thinkingEnabled, isFalse);
      expect(probe.sent!.maxOutputTokens, 64);
      expect(probe.sent!.reasoningEffort, isEmpty);
    },
  );

  test(
    'model list cancellation aborts silent requests and errors redact the API key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final accepted = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        await request.drain<void>();
        requests++;
        if (requests == 1) {
          accepted.complete();
          return;
        }
        request.response.statusCode = 401;
        request.response.write(
          jsonEncode({
            'error': {'message': 'Invalid private-secret'},
          }),
        );
        await request.response.close();
      });
      final transport = AiChatTransport(httpClientFactory: _realClient);
      final settings = AiChatSettings(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'private-secret',
      );
      final cancellation = AiChatCancellation();
      final pending = transport.fetchModels(
        settings,
        cancellation: cancellation,
      );
      final assertion = expectLater(pending, throwsA(isA<AiChatException>()));
      await accepted.future;
      cancellation.cancel();
      await assertion.timeout(const Duration(seconds: 2));
      await expectLater(
        transport.fetchModels(settings),
        throwsA(
          isA<AiChatException>()
              .having((error) => error.statusCode, 'status', 401)
              .having(
                (error) => error.message,
                'redacted key',
                isNot(contains('private-secret')),
              ),
        ),
      );
    },
  );
}
