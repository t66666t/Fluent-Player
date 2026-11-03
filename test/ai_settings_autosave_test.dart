import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/ai_chat/ai_settings_dialog.dart';

class _Transport extends AiChatTransport {
  @override
  Future<List<AiModelInfo>> fetchModels(
    AiChatSettings settings, {
    AiChatCancellation? cancellation,
  }) async => const [AiModelInfo(id: 'old-model')];
}

void main() {
  Future<void> open(
    WidgetTester tester, {
    required Future<void> Function(AiChatSettings) onSave,
    AiChatSettings settings = const AiChatSettings(
      backend: AiBackend.codex,
      model: 'old-model',
    ),
    ValueChanged<AiChatSettings?>? onClosed,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showDialog<AiChatSettings>(
                  context: context,
                  builder: (_) => AiSettingsDialog(
                    settings: settings,
                    transport: _Transport(),
                    onSave: onSave,
                  ),
                );
                onClosed?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String key, String text) async {
    final field = find.byKey(ValueKey(key));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> saveAutomatically(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('text edits debounce and save without submitting the dialog', (
    tester,
  ) async {
    final writes = <AiChatSettings>[];
    await open(tester, onSave: (value) async => writes.add(value));
    expect(find.text('保存'), findsNothing);
    expect(find.text('取消'), findsNothing);
    expect(writes, isEmpty);
    await edit(tester, 'ai-settings-model', 'in-progress');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(
      find.byKey(const ValueKey('ai-settings-model')),
      'new-model',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(writes, isEmpty);
    await saveAutomatically(tester);
    expect(writes.single.model, 'new-model');
    expect(find.text('AI 设置'), findsOneWidget);
    expect(find.text('已自动保存'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
  });

  for (final dismissal in ['close button', 'barrier', 'back']) {
    testWidgets('$dismissal flushes pending changes before dismissing', (
      tester,
    ) async {
      final gate = Completer<void>();
      final writes = <AiChatSettings>[];
      AiChatSettings? closed;
      await open(
        tester,
        onSave: (value) {
          writes.add(value);
          return gate.future;
        },
        onClosed: (value) => closed = value,
      );
      await edit(tester, 'ai-settings-model', 'new-model');
      expect(writes, isEmpty);
      switch (dismissal) {
        case 'close button':
          await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
        case 'barrier':
          await tester.tapAt(const Offset(3, 3));
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pump();
      expect(writes.single.model, 'new-model');
      expect(find.byType(AiSettingsDialog), findsOneWidget);
      expect(closed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsDialog), findsNothing);
      expect(closed!.model, 'new-model');
      expect(writes, hasLength(1));
    });
  }

  testWidgets('edits during an async save are serialized and keep the latest', (
    tester,
  ) async {
    final gate = Completer<void>();
    final writes = <AiChatSettings>[];
    await open(
      tester,
      onSave: (value) {
        writes.add(value);
        return writes.length == 1 ? gate.future : Future<void>.value();
      },
    );
    await edit(tester, 'ai-settings-model', 'first-model');
    await saveAutomatically(tester);
    await edit(tester, 'ai-settings-model', 'latest-model');
    await saveAutomatically(tester);
    expect(writes.map((value) => value.model), ['first-model']);
    gate.complete();
    await tester.pumpAndSettle();
    expect(writes.map((value) => value.model), ['first-model', 'latest-model']);
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
    expect(writes, hasLength(2));
  });

  testWidgets(
    'invalid input preserves the last saved settings and can be fixed',
    (tester) async {
      final writes = <AiChatSettings>[];
      await open(
        tester,
        settings: const AiChatSettings(
          baseUrl: 'https://original.example/v1',
          model: 'old-model',
        ),
        onSave: (value) async => writes.add(value),
      );
      await edit(tester, 'ai-settings-url', 'https://');
      await saveAutomatically(tester);
      expect(writes, isEmpty);
      expect(find.text('输入有误，尚未保存。'), findsOneWidget);
      await edit(tester, 'ai-settings-url', 'https://updated.example/v1');
      await saveAutomatically(tester);
      expect(writes.single.baseUrl, 'https://updated.example/v1');
      expect(writes.single.model, 'old-model');
      expect(find.text('已自动保存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('changing only the API key still autosaves securely', (
    tester,
  ) async {
    final writes = <AiChatSettings>[];
    await open(
      tester,
      settings: const AiChatSettings(apiKey: 'original-key'),
      onSave: (value) async => writes.add(value),
    );
    await edit(tester, 'ai-settings-key', 'updated-key');
    await saveAutomatically(tester);
    expect(writes.single.apiKey, 'updated-key');
    expect(writes.single.apiProfiles['deepseek']!.apiKey, 'updated-key');
    expect(writes.single.toJson().toString(), isNot(contains('updated-key')));
    await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'invalid numbers are rejected even when their fallback is unchanged',
    (tester) async {
      final writes = <AiChatSettings>[];
      await open(tester, onSave: (value) async => writes.add(value));
      final advanced = find.byKey(const ValueKey('ai-settings-advanced'));
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final output = find.widgetWithText(TextFormField, '回答预算预留（CLI）');
      await tester.ensureVisible(output);
      await tester.enterText(output, 'invalid');
      await saveAutomatically(tester);
      expect(writes, isEmpty);
      expect(find.text('输入有误，尚未保存。'), findsOneWidget);
      await tester.enterText(output, '4096');
      await saveAutomatically(tester);
      expect(writes.single.maxOutputTokens, 4096);
      expect(find.text('已自动保存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'a failed close needs an explicit discard and keeps prior saves',
    (tester) async {
      final writes = <AiChatSettings>[];
      AiChatSettings? closed;
      var fail = false;
      await open(
        tester,
        onSave: (value) async {
          writes.add(value);
          if (fail) throw StateError('模拟存储失败');
        },
        onClosed: (value) => closed = value,
      );
      await edit(tester, 'ai-settings-model', 'saved-model');
      await saveAutomatically(tester);
      fail = true;
      await edit(tester, 'ai-settings-model', 'unsaved-model');
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsDialog), findsOneWidget);
      expect(find.text('自动保存失败，请重试。'), findsOneWidget);
      expect(find.text('放弃未保存更改并关闭'), findsOneWidget);
      expect(closed, isNull);
      await tester.tap(find.text('放弃未保存更改并关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsDialog), findsNothing);
      expect(closed!.model, 'saved-model');
      expect(writes.map((value) => value.model), [
        'saved-model',
        'unsaved-model',
      ]);
    },
  );

  testWidgets(
    'switches and the CLI default model autosave like text edits',
    (tester) async {
      final writes = <AiChatSettings>[];
      await open(
        tester,
        settings: const AiChatSettings(
          backend: AiBackend.codex,
          executablePath: 'custom-cli',
          model: 'old-model',
          fastSummaries: true,
        ),
        onSave: (value) async => writes.add(value),
      );
      await tester.ensureVisible(find.text('使用工具默认模型'));
      await tester.tap(find.text('使用工具默认模型'));
      await saveAutomatically(tester);
      expect(writes.single.model, isEmpty);
      expect(writes.single.cliProfiles['codex']!.model, isEmpty);
      final advanced = find.byKey(const ValueKey('ai-settings-advanced'));
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(SwitchListTile, '快速总结');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await saveAutomatically(tester);
      expect(writes.last.fastSummaries, isFalse);
      expect(writes.last.executablePath, 'custom-cli');
      await tester.tap(find.byKey(const ValueKey('ai-settings-close')));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
