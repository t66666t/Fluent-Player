import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';

class _MemorySecrets implements AiChatSecretStorage {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bound = AiChatSettings(
    apiKey: 'sk-test',
    model: 'demo-model',
    baseUrl: 'https://example.com/v1',
  );

  String echo(List<Map<String, String>> messages) {
    final source =
        jsonDecode(
              messages.firstWhere((message) {
                return message['role'] == 'user';
              })['content']!,
            )
            as Map;
    return jsonEncode({
      for (final entry in source.entries) '${entry.key}': '译:${entry.value}',
    });
  }

  AiSubtitleTranslator translator({
    required AiSubtitleCompleter complete,
    AiChatSettings settings = bound,
    Future<void> Function(Duration)? delay,
  }) {
    return AiSubtitleTranslator(
      complete: complete,
      loadSettings: () async => settings,
      delay: delay,
    );
  }

  Future<List<String>> run(
    AiSubtitleTranslator client,
    List<String> texts, {
    AiSubtitleTranslationSettings options = const AiSubtitleTranslationSettings(
      batchSize: 5,
      threadNum: 1,
    ),
    String sourceLanguage = 'en',
    bool reflect = false,
  }) {
    return client.translate(
      texts: texts,
      sourceLanguage: sourceLanguage,
      targetLanguage: 'zh-CN',
      targetLabel: '简体中文',
      sourceLabel: '英语',
      options: options.copyWith(reflect: reflect),
      onProgress: (_) {},
    );
  }

  test('批量 JSON 按原序号写回，空行不发给模型', () async {
    Map<String, dynamic>? sent;
    final result = await run(
      translator(
        complete: (settings, messages) async {
          sent = jsonDecode(messages.last['content']!) as Map<String, dynamic>;
          return '```json\n${echo(messages)}\n```';
        },
      ),
      ['Hello', '', 'World'],
    );

    expect(sent?.keys, ['0', '2']);
    expect(result, ['译:Hello', '', '译:World']);
  });

  test('键不齐时把错误发回模型，下一轮成功', () async {
    var calls = 0;
    final result = await run(
      translator(
        complete: (settings, messages) async {
          calls++;
          if (calls == 1) return '{"0":"只有一条"}';
          expect(messages.last['content'], contains('Missing keys'));
          expect(
            messages.any((message) => message['role'] == 'assistant'),
            isTrue,
          );
          return echo(messages);
        },
      ),
      ['Hello', 'World'],
    );

    expect(calls, 2);
    expect(result, ['译:Hello', '译:World']);
  });

  test('反思翻译只采用 native_translation', () async {
    final result = await run(
      translator(
        complete: (settings, messages) async {
          expect(messages.first['content'], contains('native_translation'));
          final source =
              jsonDecode(messages.last['content']!) as Map<String, dynamic>;
          return jsonEncode({
            for (final entry in source.entries)
              entry.key: {
                'initial_translation': '直译',
                'reflection': '太硬',
                'native_translation': '自然:${entry.value}',
              },
          });
        },
      ),
      ['Hello'],
      reflect: true,
    );

    expect(result, ['自然:Hello']);
  });

  test('认证失败立即停止，不再请求下一批', () async {
    var calls = 0;
    final client = translator(
      complete: (settings, messages) async {
        calls++;
        throw const AiChatException('API 认证失败，请检查密钥', statusCode: 401);
      },
    );

    await expectLater(
      run(
        client,
        List<String>.filled(10, 'Hello'),
        options: const AiSubtitleTranslationSettings(
          batchSize: 5,
          threadNum: 1,
        ),
      ),
      throwsA(isA<AiChatException>()),
    );
    expect(calls, 1);
  });

  test('频率限制会等待后重试', () async {
    final delays = <Duration>[];
    var calls = 0;
    final result = await run(
      translator(
        delay: (duration) async => delays.add(duration),
        complete: (settings, messages) async {
          calls++;
          if (calls < 3) {
            throw const AiChatException('API 请求过于频繁', statusCode: 429);
          }
          return echo(messages);
        },
      ),
      ['Hello'],
    );

    expect(result, ['译:Hello']);
    expect(delays, const [Duration(seconds: 2), Duration(seconds: 4)]);
  });

  test('失败超过一半时不把半成品当成成功', () async {
    final client = translator(
      complete: (settings, messages) async {
        final text = messages.last['content'] ?? '';
        if (text.contains('BAD')) throw Exception('这一批失败');
        return echo(messages);
      },
    );

    await expectLater(
      run(client, [
        ...List<String>.filled(10, 'BAD'),
        'Hello',
        'World',
        'Fine',
        'Four',
        'Five',
      ]),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.message,
          'message',
          contains('失败过多'),
        ),
      ),
    );
  });

  test('流式严格模式保留局部成功，并把前文和术语带入补译', () async {
    final accepted = <int, String>{};
    final requests = <List<Map<String, String>>>[];
    final client = translator(
      delay: (_) async {},
      complete: (_, messages) async {
        requests.add(List<Map<String, String>>.from(messages));
        if (messages.last['content'] == 'BAD') {
          throw const AiChatException('请求过于频繁', statusCode: 429);
        }
        return '{"0":"已完成译文"}';
      },
    );
    await expectLater(
      client.translate(
        texts: ['Hello', 'BAD'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        options: const AiSubtitleTranslationSettings(
          batchSize: 2,
          threadNum: 1,
          customPrompt: 'Acme 译为艾克米',
        ),
        precedingContext: 'Yesterday Acme shipped the package.',
        onProgress: (_) {},
        onTranslated: (index, text) => accepted[index] = text,
        requireAll: true,
      ),
      throwsA(isA<AiChatException>()),
    );
    expect(accepted, {0: '已完成译文'});
    expect(requests, hasLength(6));
    for (final request in requests) {
      expect(request.first['content'], contains('Yesterday Acme'));
      expect(request.first['content'], contains('Acme 译为艾克米'));
    }
  });

  test('API 可以并发，Codex 与 OpenCode 按顺序翻译', () async {
    Future<int> peak({
      required AiChatSettings settings,
      required int threads,
    }) async {
      var inFlight = 0;
      var highest = 0;
      final client = translator(
        settings: settings,
        complete: (settings, messages) async {
          inFlight++;
          if (inFlight > highest) highest = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          inFlight--;
          return echo(messages);
        },
      );
      await run(
        client,
        List<String>.filled(10, 'Hello'),
        options: AiSubtitleTranslationSettings(
          batchSize: 5,
          threadNum: threads,
        ),
      );
      return highest;
    }

    expect(await peak(settings: bound, threads: 8), 2);
    expect(
      await peak(
        settings: const AiChatSettings(
          backend: AiBackend.codex,
          model: 'gpt-5.4',
        ),
        threads: 8,
      ),
      1,
    );
    expect(
      await peak(
        settings: const AiChatSettings(
          backend: AiBackend.opencode,
          model: 'claude',
        ),
        threads: 8,
      ),
      1,
    );
  });

  test('未绑定接口时直接说明，不发起请求', () async {
    var calls = 0;
    await expectLater(
      run(
        translator(
          settings: const AiChatSettings(model: '', baseUrl: ''),
          complete: (settings, messages) async {
            calls++;
            return '{}';
          },
        ),
        ['Hello'],
      ),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.message,
          'message',
          contains('接口'),
        ),
      ),
    );
    expect(calls, 0);
  });

  test('关闭可关闭的思考，不能关闭时降到最低档', () {
    final quiet = prepareAiSubtitleRequest(
      const AiChatSettings(
        apiKey: 'sk-test',
        thinkingEnabled: true,
        reasoningEffort: 'high',
      ),
      const [
        {'role': 'user', 'content': 'Hello'},
      ],
      lineCount: 1,
      reflect: false,
    );
    expect(quiet.thinkingEnabled, isFalse);
    expect(quiet.cliPrompt, contains('JSON'));

    final forced = prepareAiSubtitleRequest(
      const AiChatSettings(
        model: 'custom-think',
        baseUrl: 'https://example.com/v1',
        apiKey: 'sk-test',
        modelCatalogBaseUrl: 'https://example.com/v1',
        thinkingEnabled: true,
        reasoningEffort: 'high',
        savedModels: [
          AiModelInfo(
            id: 'custom-think',
            supportsThinking: true,
            canDisableThinking: false,
            reasoningEfforts: ['low', 'high'],
            contextWindow: 32000,
            maxOutputTokens: 4096,
          ),
        ],
      ),
      const [
        {'role': 'user', 'content': 'Hello'},
      ],
      lineCount: 1,
      reflect: false,
    );
    expect(forced.thinkingEnabled, isTrue);
    expect(forced.reasoningEffort, 'low');
  });

  test('损坏的设置会吸附到支持的档位，并能存取', () async {
    SharedPreferences.setMockInitialValues({});
    const raw = AiSubtitleTranslationSettings(
      batchSize: 7,
      threadNum: 4,
      reflect: true,
      customPrompt: ' 术语 ',
    );
    expect(raw.normalized().batchSize, 5);
    expect(raw.normalized().threadNum, 3);
    expect(raw.normalized().customPrompt, '术语');

    await raw.save();
    final loaded = await AiSubtitleTranslationSettings.load();
    expect(loaded.batchSize, 5);
    expect(loaded.threadNum, 3);
    expect(loaded.reflect, isTrue);
    expect(loaded.customPrompt, '术语');
  });

  test('绑定说明只描述翻译接口，未配置时不请求', () {
    final ready = AiSubtitleBinding.describe(
      const AiSubtitleApiSettings(
        baseUrl: 'https://example.com/v1',
        apiKey: 'sk-test',
        model: 'demo-model',
      ),
    );
    expect(ready.ready, isTrue);
    expect(ready.usesCli, isFalse);
    expect(ready.summary, contains('demo-model'));
    expect(ready.summary, contains('example.com'));
    expect(
      AiSubtitleBinding.describe(const AiSubtitleApiSettings()).ready,
      isFalse,
    );
  });

  test('翻译接口单独保存，不写进对话设置', () async {
    SharedPreferences.setMockInitialValues({
      AiChatSettingsStore.preferencesKey: jsonEncode({
        'baseUrl': 'https://chat.example/v1',
        'model': 'chat-model',
        'apiKey': 'should-not-live-here',
      }),
    });
    final secrets = _MemorySecrets();
    final store = AiSubtitleApiSettingsStore(
      secretStorage: secrets,
      readChatSettings: () async => const AiChatSettings(
        baseUrl: 'https://chat.example/v1',
        apiKey: 'sk-chat',
        model: 'chat-model',
      ),
    );
    final seeded = await store.load();
    expect(seeded.model, 'chat-model');
    expect(seeded.apiKey, 'sk-chat');
    expect(secrets.values[AiSubtitleApiSettings.apiKeyStorageKey], 'sk-chat');

    await store.save(
      const AiSubtitleApiSettings(
        providerId: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-translate',
        model: 'gpt-4o-mini',
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(AiSubtitleApiSettings.preferencesKey)!;
    expect(raw, isNot(contains('sk-translate')));
    expect(
      preferences.getString(AiChatSettingsStore.preferencesKey),
      contains('chat-model'),
    );
    final loaded = await store.load();
    expect(loaded.model, 'gpt-4o-mini');
    expect(loaded.apiKey, 'sk-translate');
    expect(loaded.providerId, 'openai');
    expect(loaded.toChatSettings().backend, AiBackend.api);
    expect(loaded.toChatSettings().model, 'gpt-4o-mini');
  });

  test('每个连接服务各自记住密钥，旧的单密钥只属于当时的服务商', () async {
    SharedPreferences.setMockInitialValues({
      AiSubtitleApiSettings.preferencesKey: jsonEncode({
        'providerId': 'deepseek',
        'baseUrl': 'https://api.deepseek.com',
        'model': 'deepseek-chat',
      }),
    });
    final secrets = _MemorySecrets();
    secrets.values[AiSubtitleApiSettings.apiKeyStorageKey] = 'sk-old';
    final store = AiSubtitleApiSettingsStore(secretStorage: secrets);
    final migrated = await store.load();
    expect(migrated.apiKey, 'sk-old');
    expect(migrated.selecting('openai').apiKey, isEmpty);

    await store.save(
      migrated.copyWith(
        profiles: {
          ...migrated.profiles,
          'openai': const AiSubtitleApiProfile(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-openai',
            model: 'gpt-4o-mini',
          ),
        },
      ),
    );
    final loaded = await store.load();
    expect(loaded.selecting('deepseek').apiKey, 'sk-old');
    expect(loaded.selecting('openai').apiKey, 'sk-openai');
    expect(loaded.selecting('openai').baseUrl, 'https://api.openai.com/v1');
    final raw = (await SharedPreferences.getInstance()).getString(
      AiSubtitleApiSettings.preferencesKey,
    )!;
    expect(raw, isNot(contains('sk-old')));
    expect(raw, isNot(contains('sk-openai')));
  });

  test('能从代码块和尾逗号里取出 JSON', () {
    expect(parseAiSubtitleJson('说明\n```json\n{"0": "好",}\n```\n以上。'), {
      '0': '好',
    });
    expect(
      validateAiSubtitleResponse(
        {'0': '好'},
        {'0': 'a', '1': 'b'},
        reflect: false,
      ).message,
      contains('Missing keys'),
    );
  });

  test('翻译服务把 AI 结果写成字幕文件', () async {
    final directory = Directory.systemTemp.createTempSync('ai_subtitle');
    addTearDown(() => directory.deleteSync(recursive: true));
    final input = File('${directory.path}/input.srt');
    await input.writeAsString(
      '1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n'
      '2\r\n00:00:03,000 --> 00:00:04,000\r\nWorld\r\n\r\n',
    );
    final service = SubtitleTranslationService(
      dio: Dio(),
      aiTranslator: translator(
        complete: (settings, messages) async => echo(messages),
      ),
    );

    final result = await service.translateSubtitleFile(
      inputPath: input.path,
      sourceLanguage: 'en',
      targetLanguage: 'zh-CN',
      provider: SubtitleTranslateProvider.ai,
      aiOptions: const AiSubtitleTranslationSettings(
        batchSize: 5,
        threadNum: 1,
      ),
      onProgress: (_) {},
    );

    final written = await File(result.outputPath).readAsString();
    expect(written, contains('译:Hello'));
    expect(written, contains('译:World'));
    expect(service.activity, isNull);
    expect(service.isTranslating, isFalse);
  });

  testWidgets('翻译接口窗口收在一小块里，选择服务商会填上地址', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  const AiSubtitleApiDialog(settings: AiSubtitleApiSettings()),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('翻译接口'), findsOneWidget);
    expect(find.text('检查连接'), findsOneWidget);
    final box = tester
        .renderObjectList<RenderConstrainedBox>(
          find.descendant(
            of: find.byType(AiSubtitleApiDialog),
            matching: find.byType(ConstrainedBox),
          ),
        )
        .firstWhere(
          (item) =>
              item.additionalConstraints.maxWidth <= 340 &&
              item.additionalConstraints.maxHeight <= 420,
        );
    expect(box.additionalConstraints.maxWidth, lessThanOrEqualTo(340));
    expect(box.additionalConstraints.maxHeight, lessThanOrEqualTo(420));

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('硅基流动').last);
    await tester.pumpAndSettle();
    expect(find.text('https://api.siliconflow.cn/v1'), findsOneWidget);
  });

  testWidgets('切换服务商会保留各自已经输入的密钥', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AiSubtitleApiDialog(settings: AiSubtitleApiSettings()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> choose(String label) async {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('自定义');
    await choose('DeepSeek');
    await tester.enterText(find.byType(TextField).at(1), 'sk-deep');
    await choose('DeepSeek');
    await choose('OpenAI');
    await tester.enterText(find.byType(TextField).at(1), 'sk-openai');
    await choose('OpenAI');
    await choose('DeepSeek');

    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      'sk-deep',
    );
    expect(find.text('https://api.deepseek.com'), findsOneWidget);
    await choose('DeepSeek');
    await choose('OpenAI');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      'sk-openai',
    );
  });
}
