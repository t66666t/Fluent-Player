import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_usage_widgets.dart';

void main() {
  Future<void> mount(WidgetTester tester, AiChatMessage message) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AiResponseUsage(message: message)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> details(WidgetTester tester) async {
    await tester.tap(find.byType(TextButton).first);
    await tester.pumpAndSettle();
  }

  testWidgets('Codex zero cached input is a CLI count, not a DeepSeek rate', (
    tester,
  ) async {
    await mount(
      tester,
      AiChatMessage(
        id: 'c',
        role: 'assistant',
        content: '回答',
        usage: {
          'input_tokens': 100,
          'cached_input_tokens': 0,
          'output_tokens': 20,
        },
        responseInfo: {'backend': 'codex', 'model': 'model'},
      ),
    );
    expect(find.text('120 token'), findsOneWidget);
    await details(tester);
    expect(find.text('统计来源：Codex CLI'), findsOneWidget);
    expect(find.text('已复用输入：0 token'), findsOneWidget);
    expect(find.textContaining('缓存命中率'), findsNothing);
    expect(find.textContaining('缓存输入占比'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('semantic selection usage is included once in the total', (
    tester,
  ) async {
    await mount(
      tester,
      AiChatMessage(
        id: 'plan',
        role: 'assistant',
        content: '回答',
        usage: {
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'total_tokens': 120,
        },
        responseInfo: {
          'backend': 'api',
          'planning_usage': {
            'prompt_tokens': 40,
            'completion_tokens': 20,
            'total_tokens': 60,
          },
        },
      ),
    );
    expect(find.text('180 token'), findsOneWidget);
    await details(tester);
    expect(find.text('理解问题与选择资料：60 token'), findsOneWidget);
    expect(find.text('本次回答合计：120 token'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'automatic continuation totals are counted once and missing calls stay partial',
    (tester) async {
      for (final reported in [1, 2]) {
        await mount(
          tester,
          AiChatMessage(
            id: 'continued-$reported',
            role: 'assistant',
            content: '完整回答',
            usage: {
              'prompt_tokens': 600,
              'completion_tokens': 8392,
              'total_tokens': 8992,
            },
            responseInfo: {
              'backend': 'api',
              'generation_usage': {'calls': 2, 'reported_calls': reported},
              'planning_usage': {
                'prompt_tokens': 40,
                'completion_tokens': 20,
                'total_tokens': 60,
              },
            },
          ),
        );
        expect(
          find.text('${reported == 2 ? '' : '已知 '}9,052 token'),
          findsOneWidget,
        );
        await details(tester);
        expect(find.text('本次回答合计：8,992 token'), findsOneWidget);
        expect(find.text('含自动续写：2 次生成，$reported 次返回完整用量'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'compression and failed overflow usage are included once and remain partial when missing',
    (tester) async {
      for (final reported in [0, 1]) {
        await mount(
          tester,
          AiChatMessage(
            id: 'compressed',
            role: 'assistant',
            content: '回答',
            usage: {
              'prompt_tokens': 200,
              'completion_tokens': 20,
              'total_tokens': 220,
            },
            responseInfo: {
              'compaction': {
                'calls': 1,
                'message': '已压缩',
                'usage': {
                  'prompt_tokens': 100,
                  'completion_tokens': 40,
                  'total_tokens': 140,
                  'reported_calls': 1,
                },
              },
              'overflow_recovery': {
                'calls': 1,
                'usage': {'total_tokens': 100, 'reported_calls': reported},
              },
              'overflow_attempt_usage': {
                'calls': 1,
                'total_tokens': 50,
                'reported_calls': 1,
              },
            },
          ),
        );
        expect(
          find.text('${reported == 1 ? '' : '已知 '}510 token'),
          findsOneWidget,
        );
        await details(tester);
        expect(find.text('本次回答合计：220 token'), findsOneWidget);
        expect(find.text('已压缩'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('DeepSeek distinguishes zero hit from an omitted cache field', (
    tester,
  ) async {
    final info = {'backend': 'api', 'provider_host': 'api.deepseek.com'};
    await mount(
      tester,
      AiChatMessage(
        id: 'd',
        role: 'assistant',
        content: '回答',
        usage: {
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'prompt_cache_hit_tokens': 0,
          'prompt_cache_miss_tokens': 100,
        },
        responseInfo: info,
      ),
    );
    expect(find.textContaining('本次未命中缓存'), findsOneWidget);
    await details(tester);
    expect(find.text('缓存命中率：0%'), findsOneWidget);
    expect(find.text('未命中输入：100 token'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(
      tester,
      AiChatMessage(
        id: 'd2',
        role: 'assistant',
        content: '回答',
        usage: {'prompt_tokens': 100, 'completion_tokens': 20},
        responseInfo: info,
      ),
    );
    await details(tester);
    expect(find.textContaining('本次接口未返回缓存统计'), findsOneWidget);
    expect(find.text('缓存命中率：0%'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'small DeepSeek hits and model-specific optional counters render accurately',
    (tester) async {
      await mount(
        tester,
        AiChatMessage(
          id: 's',
          role: 'assistant',
          content: '回答',
          usage: {
            'prompt_tokens': 1000,
            'completion_tokens': 20,
            'prompt_cache_hit_tokens': 2,
            'completion_tokens_details': {'reasoning_tokens': 0},
          },
          responseInfo: {
            'backend': 'api',
            'provider_host': 'api.deepseek.com',
            'supports_thinking': false,
          },
        ),
      );
      expect(find.textContaining('缓存 0.2%'), findsOneWidget);
      await details(tester);
      expect(find.textContaining('其中思考'), findsNothing);
      expect(find.text('本次回答输出：20 token'), findsOneWidget);
      expect(find.text('缓存命中率：0.2%'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('custom API does not display absent provider-specific counters', (
    tester,
  ) async {
    await mount(
      tester,
      AiChatMessage(
        id: 'u',
        role: 'assistant',
        content: '回答',
        usage: {'prompt_tokens': 100, 'completion_tokens': 20},
        responseInfo: {'backend': 'api', 'provider_host': 'custom.example'},
      ),
    );
    await details(tester);
    expect(find.textContaining('缓存命中率'), findsNothing);
    expect(find.textContaining('缓存写入：'), findsNothing);
    expect(find.textContaining('其中思考：'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
