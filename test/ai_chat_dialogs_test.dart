import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_context_dialog.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/models/subtitle_model.dart';

class _ModelsTransport extends AiChatTransport {
  final calls = <AiChatSettings>[];
  @override
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async {
    calls.add(settings);
    return const [
      AiModelInfo(
        id: 'study-model',
        name: '学习模型',
        contextWindow: 128000,
        maxOutputTokens: 32768,
        supportsThinking: true,
        supportsReasoningEffort: true,
        reasoningEfforts: ['low', 'high', 'max'],
      ),
      AiModelInfo(
        id: 'fast-model',
        name: '快速模型',
        contextWindow: 32000,
        maxOutputTokens: 4096,
        supportsThinking: false,
        supportsReasoningEffort: false,
      ),
      AiModelInfo(id: 'custom-model', name: '自定义模型'),
    ];
  }
}

void main() {
  Future<void> surface(
    WidgetTester tester,
    WidgetBuilder dialog, {
    Size size = const Size(400, 760),
    ValueChanged<Object?>? onResult,
    double keyboard = 0,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewInsets: EdgeInsets.only(bottom: keyboard),
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  final result = await showDialog<Object?>(
                    context: context,
                    builder: dialog,
                  );
                  onResult?.call(result);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('settings autosave without closing and allow retry on failure', (
    tester,
  ) async {
    var gate = Completer<void>();
    var saves = 0;
    await surface(
      tester,
      (_) => AiSettingsDialog(
        settings: const AiChatSettings(apiKey: 'test-only-key'),
        transport: _ModelsTransport(),
        generationInProgress: true,
        onSave: (_) {
          saves++;
          return gate.future;
        },
      ),
    );
    expect(find.text('保存'), findsNothing);
    expect(find.text('取消'), findsNothing);
    expect(saves, 0);
    final model = find.byKey(const ValueKey('ai-settings-model'));
    await tester.ensureVisible(model);
    await tester.enterText(model, 'changed-model');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在自动保存…'), findsOneWidget);
    expect(find.text('AI 设置'), findsOneWidget);
    gate.completeError(StateError('模拟存储失败'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设置未保存'), findsOneWidget);
    expect(find.text('自动保存失败，请重试。'), findsOneWidget);
    gate = Completer<void>();
    await tester.tap(find.text('重试'));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.text('已自动保存'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    expect(find.text('AI 设置'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final backend in AiBackend.values) {
    testWidgets(
      'collapsed advanced settings preserve custom values on $backend',
      (tester) async {
        AiChatSettings? saved;
        final original = AiChatSettings(
          backend: backend,
          executablePath: backend == AiBackend.acp ? 'custom-agent' : '',
          baseUrl: 'https://custom.example/v1',
          apiKey: 'secret',
          model: 'my-model',
          contextTokens: 128000,
          maxOutputTokens: 32768,
          contextMode: AiContextMode.full,
          autoCompact: false,
          thinkingEnabled: false,
          temperature: .8,
          titlePrompt: '保留我的 AI 精修标题提示词',
        );
        await surface(
          tester,
          (_) => AiSettingsDialog(
            settings: original,
            transport: _ModelsTransport(),
          ),
          size: backend == AiBackend.opencode
              ? const Size(1200, 900)
              : const Size(320, 640),
          textScale: backend == AiBackend.codex ? 1.5 : 1,
          onResult: (value) => saved = value as AiChatSettings?,
        );
        expect(
          find.byKey(const ValueKey('ai-settings-context-mode')),
          findsNothing,
        );
        expect(find.text('常规上下文预算（含预留回答）'), findsNothing);
        expect(find.text('文稿处理：全文直读'), findsOneWidget);
        await tapVisible(tester, find.text('高级响应设置'));
        expect(
          find.byKey(const ValueKey('ai-settings-context-mode')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text('高级响应设置'));
        expect(
          find.byKey(const ValueKey('ai-settings-context-mode')),
          findsNothing,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('ai-settings-close')),
        );
        expect(saved!.contextTokens, original.contextTokens);
        expect(saved!.maxOutputTokens, original.maxOutputTokens);
        expect(saved!.contextMode, original.contextMode);
        expect(saved!.autoCompact, original.autoCompact);
        expect(saved!.titlePrompt, original.titlePrompt);
        expect(saved!.temperature, original.temperature);
        expect(saved!.optimizeTokens, isFalse);
        expect(saved!.fastSummaries, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('invalid hidden budgets are revealed without autosaving them', (
    tester,
  ) async {
    AiChatSettings? saved;
    await surface(
      tester,
      (_) => const AiSettingsDialog(
        settings: AiChatSettings(contextTokens: 8192, maxOutputTokens: 8192),
      ),
      onResult: (value) => saved = value as AiChatSettings?,
    );
    expect(find.text('常规上下文预算（含预留回答）'), findsNothing);
    final model = find.byKey(const ValueKey('ai-settings-model'));
    await tester.ensureVisible(model);
    await tester.enterText(model, 'changed-model');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(
      tester
          .widget<ExpansionTile>(
            find.byKey(const ValueKey('ai-settings-advanced')),
          )
          .controller!
          .isExpanded,
      isTrue,
    );
    expect(find.text('需为输入保留至少 512 Token，请增加上下文预算'), findsOneWidget);
    final budget = find.widgetWithText(TextFormField, '常规上下文预算（含预留回答）');
    await tester.ensureVisible(budget);
    await tester.enterText(budget, '64000');
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('高级响应设置'));
    await tapVisible(tester, find.byKey(const ValueKey('ai-settings-close')));
    expect(saved!.contextTokens, 64000);
    expect(saved!.maxOutputTokens, 8192);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reads all service models, searches IDs and exposes declared effort levels',
    (tester) async {
      final transport = _ModelsTransport();
      await surface(
        tester,
        (_) => AiSettingsDialog(
          transport: transport,
          settings: const AiChatSettings(
            baseUrl: 'https://models.example/v1',
            apiKey: 'private',
            model: 'study-model',
          ),
        ),
      );
      await tapVisible(tester, find.byKey(const ValueKey('ai-load-models')));
      expect(transport.calls.length, 1);
      await tapVisible(tester, find.byKey(const ValueKey('ai-select-model')));
      expect(find.text('学习模型'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('ai-model-search')),
        'fast-model',
      );
      await tester.pumpAndSettle();
      expect(find.text('快速模型'), findsOneWidget);
      expect(find.text('学习模型'), findsNothing);
      await tester.tap(find.text('快速模型'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('深度思考'));
      await tester.pumpAndSettle();
      final switchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '深度思考'),
      );
      expect(switchTile.value, isFalse);
      expect(switchTile.onChanged, isNull);
      expect(find.text('模型目录明确不支持深度思考。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'recommended response defaults keep custom credentials and model',
    (tester) async {
      AiChatSettings? saved;
      await surface(
        tester,
        (_) => const AiSettingsDialog(
          settings: AiChatSettings(
            baseUrl: 'https://custom.example/v1',
            apiKey: 'secret',
            model: 'my-model',
            contextTokens: 16000,
            maxOutputTokens: 4096,
            temperature: 0.7,
            optimizeTokens: true,
            fastSummaries: true,
            thinkingEnabled: false,
            thinkingBudget: 8192,
          ),
        ),
        onResult: (value) => saved = value as AiChatSettings?,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('ai-recommended-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.baseUrl, 'https://custom.example/v1');
      expect(saved!.apiKey, 'secret');
      expect(saved!.model, 'my-model');
      expect(saved!.contextTokens, 64000);
      expect(saved!.maxOutputTokens, 8192);
      expect(saved!.temperature, 0.3);
      expect(saved!.optimizeTokens, isFalse);
      expect(saved!.fastSummaries, isFalse);
      expect(saved!.thinkingEnabled, isTrue);
      expect(saved!.reasoningEffort, 'high');
      expect(saved!.thinkingBudget, 0);
    },
  );

  testWidgets(
    'small-screen users can choose full context and turn fast summary off',
    (tester) async {
      AiChatSettings? saved;
      await surface(
        tester,
        (_) => const AiSettingsDialog(
          settings: AiChatSettings(fastSummaries: true),
        ),
        size: const Size(320, 640),
        onResult: (value) => saved = value as AiChatSettings?,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('ai-settings-advanced')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('ai-settings-context-mode')),
      );
      await tester.tap(find.text('全文直读 · 一次发送完整字幕').last);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.widgetWithText(SwitchListTile, '快速总结'));
      await tapVisible(tester, find.byKey(const ValueKey('ai-settings-close')));
      expect(saved?.contextMode, AiContextMode.full);
      expect(saved?.fastSummaries, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recommended tracks use primary and secondary without selecting every translation',
    (tester) async {
      SubtitleItem cue(String text) => SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 10),
        text: text,
      );
      final context = AiVideoContext(
        videoId: 'video',
        title: '测试',
        tracks: [
          AiSubtitleTrack(
            id: 'other',
            label: '英文翻译',
            role: 'other',
            sourceDescription: '手动导入',
            cues: [cue('translated')],
          ),
          AiSubtitleTrack(
            id: 'secondary',
            label: '英语 · 副字幕',
            role: 'secondary',
            sourceDescription: 'B 站字幕',
            cues: [cue('secondary')],
          ),
          AiSubtitleTrack(
            id: 'primary',
            label: '中文 · 主字幕',
            role: 'primary',
            sourceDescription: '下载附带',
            cues: [cue('primary')],
          ),
        ],
      );
      AiContextSelection? saved;
      await surface(
        tester,
        (_) => AiContextDialog(
          videoContext: context,
          selectedTrackIds: const {'other'},
        ),
        onResult: (value) => saved = value as AiContextSelection?,
      );
      await tester.tap(find.byKey(const ValueKey('ai-context-recommend')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(saved!.ids, {'primary', 'secondary'});
      expect(saved!.automatic, isTrue);
    },
  );

  testWidgets(
    'native provider preset sets protocol and stores the matching model catalog',
    (tester) async {
      AiChatSettings? saved;
      final transport = _ModelsTransport();
      await surface(
        tester,
        (_) => AiSettingsDialog(
          settings: const AiChatSettings(),
          transport: transport,
        ),
        onResult: (value) => saved = value as AiChatSettings?,
      );
      await tapVisible(tester, find.text('DeepSeek'));
      await tapVisible(tester, find.text('Google · Gemini 原生').last);
      await tester.enterText(
        find.byKey(const ValueKey('ai-settings-model')),
        'study-model',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('ai-load-models')));
      expect(transport.calls.single.apiProtocol, AiApiProtocol.gemini);
      expect(
        transport.calls.single.baseUrl,
        'https://generativelanguage.googleapis.com/v1beta',
      );
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.apiProtocol, AiApiProtocol.gemini);
      expect(saved!.modelCatalogProtocol, AiApiProtocol.gemini);
      expect(saved!.selectedModelInfo!.id, 'study-model');
    },
  );

  testWidgets('mandatory thinking remains enabled and cannot be toggled off', (
    tester,
  ) async {
    AiChatSettings? saved;
    const settings = AiChatSettings(
      baseUrl: 'https://thinking.example/v1',
      model: 'always-thinking',
      thinkingEnabled: false,
      modelCatalogBaseUrl: 'https://thinking.example/v1',
      savedModels: [
        AiModelInfo(
          id: 'always-thinking',
          supportsThinking: true,
          thinkingTypes: ['enabled'],
          supportsReasoningEffort: true,
          reasoningEfforts: ['low', 'high'],
          contextWindow: 128000,
        ),
      ],
    );
    await surface(
      tester,
      (_) => const AiSettingsDialog(settings: settings),
      onResult: (value) => saved = value as AiChatSettings?,
    );
    await tester.ensureVisible(find.text('深度思考'));
    await tester.pumpAndSettle();
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '深度思考'),
    );
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    expect(find.text('此模型始终开启思考，不能关闭。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    expect(saved!.thinkingEnabled, isTrue);
  });

  testWidgets(
    'unknown thinking capability uses service defaults and preserves preference',
    (tester) async {
      AiChatSettings? saved;
      await surface(
        tester,
        (_) => const AiSettingsDialog(
          settings: AiChatSettings(
            baseUrl: 'https://unknown.example/v1',
            model: 'unknown-model',
            thinkingEnabled: true,
          ),
        ),
        onResult: (value) => saved = value as AiChatSettings?,
      );
      await tester.ensureVisible(find.text('深度思考'));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '深度思考'),
      );
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNull);
      expect(find.text('使用服务默认思考策略，目录未声明可调能力。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-settings-thinking-budget')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.thinkingEnabled, isTrue);
    },
  );

  testWidgets(
    'thinking budget is optional, validated and independent of answer length',
    (tester) async {
      AiChatSettings? saved;
      const settings = AiChatSettings(
        baseUrl: 'https://budget.example/v1',
        model: 'budget-model',
        modelCatalogBaseUrl: 'https://budget.example/v1',
        savedModels: [
          AiModelInfo(
            id: 'budget-model',
            supportsThinking: true,
            supportsThinkingBudget: true,
          ),
        ],
      );
      await surface(
        tester,
        (_) => const AiSettingsDialog(settings: settings),
        onResult: (value) => saved = value as AiChatSettings?,
      );
      final field = find.byKey(const ValueKey('ai-settings-thinking-budget'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(field).controller!.text, '0');
      await tester.enterText(field, '262145');
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('请输入 0（自动）或 1 到 262144 Token'), findsOneWidget);
      await tester.enterText(field, '8192');
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(saved!.thinkingBudget, 8192);
      expect(saved!.maxOutputTokens, 8192);
    },
  );

  testWidgets('long transcript preview is lazy, searchable and can seek', (
    tester,
  ) async {
    final cues = List.generate(
      2000,
      (i) => SubtitleItem(
        index: i,
        startTime: Duration(seconds: i * 3),
        endTime: Duration(seconds: i * 3 + 2),
        text: i == 1999 ? '关键帧：这是可以搜索到的最后一段' : '第 $i 段正常文稿内容',
      ),
    );
    Duration? selected;
    await surface(
      tester,
      (_) => AiTranscriptPreviewDialog(
        track: AiSubtitleTrack(id: 'long', label: '中文完整文稿', cues: cues),
        onSeek: (value) => selected = value,
      ),
    );
    expect(find.byType(SelectableText).evaluate().length, lessThan(30));
    expect(find.text('关键帧：这是可以搜索到的最后一段'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('ai-transcript-search')),
      '关键帧',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('关键帧：这是可以搜索到的最后一段'), findsOneWidget);
    await tester.tap(find.text('01:39:57 – 01:39:59'));
    expect(selected, const Duration(seconds: 5997));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('320px model picker and settings render without overflow', (
    tester,
  ) async {
    await surface(
      tester,
      (_) => const AiSettingsDialog(settings: AiChatSettings()),
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await surface(
      tester,
      (_) => const AiModelPickerDialog(
        selectedId: '',
        models: [
          AiModelInfo(
            id: 'organization/a-very-long-model-name-with-extended-context',
            name: '这是一个需要自动换行的很长很长的模型名称',
            contextWindow: 128000,
          ),
        ],
      ),
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'wide source selection previews inline without changing checkboxes',
    (tester) async {
      AiSubtitleTrack track(String id, String role) => AiSubtitleTrack(
        id: id,
        label: '$id 文稿',
        role: role,
        cues: [
          SubtitleItem(
            index: 0,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 5),
            text: '$id 内容',
          ),
        ],
      );
      await surface(
        tester,
        (_) => AiContextDialog(
          videoContext: AiVideoContext(
            videoId: 'video',
            title: '测试视频',
            tracks: [track('primary', 'primary'), track('other', 'other')],
          ),
          selectedTrackIds: const {'primary'},
          selectionIsAutomatic: true,
        ),
        size: const Size(1200, 900),
      );
      final sources = tester.getRect(
        find.byKey(const ValueKey('ai-context-sources')),
      );
      final preview = tester.getRect(find.byType(AiTranscriptView));
      expect(sources.right, lessThan(preview.left));
      await tester.tap(find.byKey(const ValueKey('ai-track-preview-other')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AiTranscriptView>(find.byType(AiTranscriptView)).track.id,
        'other',
      );
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .map((checkbox) => checkbox.value),
        [true, false],
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'wide settings use two columns while short keyboard layouts stay scrollable',
    (tester) async {
      await surface(
        tester,
        (_) => const AiSettingsDialog(settings: AiChatSettings()),
        size: const Size(1200, 900),
      );
      expect(find.text('单次生成上限'), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('ai-settings-advanced')),
      );
      expect(
        tester.getRect(find.text('单次生成上限')).left,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('ai-settings-url'))).right,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      await surface(
        tester,
        (_) => const AiSettingsDialog(settings: AiChatSettings()),
        size: const Size(320, 640),
        keyboard: 280,
        textScale: 1.4,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('ai-settings-close'))).bottom,
        lessThanOrEqualTo(360),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      await surface(
        tester,
        (_) => const AiModelPickerDialog(selectedId: '', models: []),
        size: const Size(800, 360),
        keyboard: 180,
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('each provider keeps its API key and model across switches', (
    tester,
  ) async {
    AiChatSettings? saved;
    final transport = _ModelsTransport();
    await surface(
      tester,
      (_) => AiSettingsDialog(
        transport: transport,
        settings: const AiChatSettings(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'deepseek-key',
          model: 'deepseek-flash',
        ),
      ),
      onResult: (value) => saved = value as AiChatSettings?,
    );
    await tapVisible(tester, find.text('DeepSeek'));
    await tapVisible(tester, find.text('OpenAI').last);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('ai-settings-key')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-settings-key')),
      'openai-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-settings-model')),
      'gpt-5.4',
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(transport.calls, isNotEmpty);
    expect(transport.calls.last.apiKey, 'openai-key');
    expect(transport.calls.last.baseUrl, 'https://api.openai.com/v1');

    await tapVisible(tester, find.text('OpenAI'));
    await tapVisible(tester, find.text('DeepSeek').last);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('ai-settings-key')))
          .controller!
          .text,
      'deepseek-key',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-settings-model')),
          )
          .controller!
          .text,
      'deepseek-flash',
    );

    await tapVisible(tester, find.text('DeepSeek'));
    await tapVisible(tester, find.text('OpenAI').last);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('ai-settings-key')))
          .controller!
          .text,
      'openai-key',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-settings-model')),
          )
          .controller!
          .text,
      'gpt-5.4',
    );

    await tapVisible(tester, find.text('API 服务'));
    await tapVisible(tester, find.text('桌面 · Codex CLI').last);
    await tapVisible(tester, find.text('桌面 · Codex CLI'));
    await tapVisible(tester, find.text('API 服务').last);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('ai-settings-key')))
          .controller!
          .text,
      'openai-key',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-settings-model')),
          )
          .controller!
          .text,
      'gpt-5.4',
    );
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    expect(saved!.apiKey, 'openai-key');
    expect(saved!.model, 'gpt-5.4');
    expect(saved!.apiProfiles['deepseek']!.apiKey, 'deepseek-key');
    expect(saved!.apiProfiles['deepseek']!.model, 'deepseek-flash');
    expect(saved!.apiProfiles['openai']!.apiKey, 'openai-key');
    expect(saved!.apiProfiles['openai']!.model, 'gpt-5.4');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'model picker orders newest models and shows purpose and context',
    (tester) async {
      await surface(
        tester,
        (_) => AiModelPickerDialog(
          selectedId: 'gpt-4o',
          models: [
            const AiModelInfo(id: 'text-embedding-3-large'),
            AiModelInfo(
              id: 'gpt-3.5-turbo',
              releasedAt: DateTime.utc(2023, 3, 1),
            ),
            AiModelInfo(
              id: 'gpt-5.4',
              description: '当前旗舰',
              releasedAt: DateTime.utc(2026, 3, 1),
            ),
            AiModelInfo(
              id: 'gpt-4o',
              contextWindow: 128000,
              releasedAt: DateTime.utc(2024, 5, 13),
            ),
          ],
        ),
        size: const Size(360, 720),
      );
      expect(find.text('最新'), findsWidgets);
      expect(find.text('较早'), findsWidgets);
      expect(find.text('128k 上下文'), findsOneWidget);
      expect(find.text('约 16.4k 上下文'), findsOneWidget);
      expect(find.text('当前旗舰'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('gpt-5.4')).dy,
        lessThan(tester.getTopLeft(find.text('gpt-3.5-turbo')).dy),
      );
      expect(
        tester.getTopLeft(find.text('gpt-3.5-turbo')).dy,
        lessThan(tester.getTopLeft(find.text('text-embedding-3-large')).dy),
      );
      await tester.tap(find.text('专用'));
      await tester.pumpAndSettle();
      expect(find.text('gpt-5.4'), findsNothing);
      expect(find.text('text-embedding-3-large'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
