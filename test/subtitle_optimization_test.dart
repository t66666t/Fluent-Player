import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_optimization_background.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

class _Secrets implements AiChatSecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

const endpoint = AiSubtitleApiSettings(
  baseUrl: 'https://example.test/v1',
  model: 'opt-model',
);
const choice = SubtitleOptimizationChoice(
  endpoint: endpoint,
  background: '{"标题":"人工智能"}',
);
SubtitleItem cue(int id) => SubtitleItem(
  index: id,
  startTime: Duration(seconds: id),
  endTime: Duration(seconds: id + 1),
  text: '学习人工职能，第$id课。',
  timedSpans: [
    SubtitleTimedSpan(
      textStart: 0,
      textEnd: 2,
      startTime: Duration(seconds: id),
      endTime: Duration(seconds: id + 1),
    ),
  ],
);
Map sourceOf(List<Map<String, String>> messages) =>
    (jsonDecode(messages.firstWhere((m) => m['role'] == 'user')['content']!)
            as Map)['字幕']
        as Map;
String corrected(List<Map<String, String>> messages) => jsonEncode({
  for (final entry in sourceOf(messages).entries)
    '${entry.key}': (entry.value as String).replaceAll('人工职能', '人工智能'),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'optimization is opt-in and snapshots never contain credentials',
    () async {
      expect((await SubtitleOptimizationSettings.load()).enabled, isFalse);
      final snapshot = SubtitleOptimizationChoice(
        endpoint: endpoint.copyWith(apiKey: 'secret'),
        prompt: '轻度纠错',
      );
      final saved = jsonEncode(snapshot.toJson());
      expect(saved, isNot(contains('secret')));
      expect(
        SubtitleOptimizationChoice.fromJson(jsonDecode(saved) as Map).prompt,
        '轻度纠错',
      );
    },
  );
  test(
    'shared connections migrate legacy keys and support two models on one provider',
    () async {
      final secrets = _Secrets();
      final legacy = AiSubtitleApiSettingsStore(secretStorage: secrets);
      await legacy.save(endpoint.copyWith(apiKey: 'legacy-key'));
      final registry = SubtitleAiConnectionStore(secretStorage: secrets);
      final migrated = await registry.load();
      expect(migrated, hasLength(1));
      expect(
        (await registry.endpoint(migrated.single.id)).apiKey,
        'legacy-key',
      );
      await registry.save(
        SubtitleAiConnection(
          'second',
          'second',
          endpoint.copyWith(model: 'translate-model', apiKey: 'second-key'),
        ),
      );
      final second = await registry.endpoint('second');
      expect(second.connectionId, 'second');
      expect(
        (await registry.endpoint(migrated.single.id)).apiKey,
        'legacy-key',
      );
      expect((await legacy.load()).model, 'opt-model');
      await legacy.save(second);
      expect((await legacy.loadForSnapshot(endpoint)).apiKey, 'legacy-key');
      expect(
        (await legacy.loadForSnapshot(second.copyWith(apiKey: ''))).apiKey,
        'second-key',
      );
      final prefs = await SharedPreferences.getInstance();
      final metadata = prefs.getString(
        SubtitleAiConnectionStore.preferencesKey,
      )!;
      expect(metadata, isNot(contains('legacy-key')));
      expect(metadata, isNot(contains('second-key')));
      final frozen = second.copyWith(apiKey: '', profiles: const {});
      await registry.save(
        SubtitleAiConnection(
          'second',
          'second',
          second.copyWith(model: 'new-model'),
        ),
      );
      expect((await registry.resolve(frozen)).model, 'translate-model');
      await registry.save(
        SubtitleAiConnection(
          'second',
          'second',
          second.copyWith(baseUrl: 'https://other.test'),
        ),
      );
      await expectLater(registry.resolve(frozen), throwsStateError);
    },
  );
  test(
    'correction preserves cue identity/times and clears only invalidated word spans',
    () async {
      var requests = 0;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (settings, messages) async {
            requests++;
            expect(settings.model, 'opt-model');
            expect(settings.thinkingEnabled, isFalse);
            expect(settings.maxOutputTokens, lessThanOrEqualTo(1024));
            expect(
              messages.first['content'],
              contains(defaultSubtitleOptimizationPrompt),
            );
            expect(messages.last['content'], contains('人工智能'));
            return corrected(messages);
          },
        ),
      );
      final input = [
        cue(3),
        cue(8).copyWith(text: '原文正确', timedSpans: cue(8).timedSpans),
      ];
      final output = await optimizer.optimize(
        cues: input,
        choice: choice,
        endpoint: endpoint,
      );
      expect(requests, 1);
      expect(output.first.text, '学习人工智能，第3课。');
      expect(output.first.index, 3);
      expect(output.first.startTime, input.first.startTime);
      expect(output.first.endTime, input.first.endTime);
      expect(output.first.timedSpans, isEmpty);
      expect(output.last.timedSpans, input.last.timedSpans);
    },
  );
  test(
    'wrong/missing IDs never duplicate neighbouring subtitles; one retry then original',
    () async {
      var calls = 0;
      String? warning;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            calls++;
            expect(messages.where((m) => m['role'] == 'assistant'), isEmpty);
            return '{"1":"wrong"}';
          },
        ),
      );
      final input = [cue(1), cue(2)];
      final result = await optimizer.optimize(
        cues: input,
        choice: choice,
        endpoint: endpoint,
        onWarning: (s) => warning = s,
      );
      expect(calls, 2);
      expect(result.map((s) => s.text), input.map((s) => s.text));
      expect(warning, contains('保留原文'));
    },
  );
  test(
    'sparse corrections retain every omitted cue and its word timings',
    () async {
      var calls = 0;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            calls++;
            expect(messages.first['content'], contains('无需修改的条目不要输出'));
            return '{"修改":{"3":"学习人工智能，第3课。"}}';
          },
        ),
      );
      final input = [cue(3), cue(8)];
      final output = await optimizer.optimize(
        cues: input,
        choice: choice,
        endpoint: endpoint,
      );
      expect(calls, 1);
      expect(output.map((value) => value.index), [3, 8]);
      expect(output.first.text, '学习人工智能，第3课。');
      expect(output.first.timedSpans, isEmpty);
      expect(identical(output.last, input.last), isTrue);
    },
  );
  test(
    'a no-change batch needs one compact reply and preserves all cues',
    () async {
      var calls = 0;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, _) async {
            calls++;
            return '{"修改":{}}';
          },
        ),
      );
      final input = List.generate(
        20,
        (i) => cue(i + 1).copyWith(text: '  原文正确\n'),
      );
      final warnings = <String>[];
      final output = await optimizer.optimize(
        cues: input,
        choice: choice,
        endpoint: endpoint,
        onWarning: warnings.add,
      );
      expect(calls, 1);
      expect(warnings, isEmpty);
      for (var i = 0; i < input.length; i++) {
        expect(identical(output[i], input[i]), isTrue);
      }
    },
  );
  for (final invalid in [
    '{}',
    '{"修改":{"999":"不属于本批"}}',
    '{"修改":{"1":""}}',
    '{"修改":{},"解释":"完成"}',
    '{"修改":{"1":"Hello friend"}}',
  ]) {
    test(
      'malformed or unsafe sparse reply is retried and preserves source: $invalid',
      () async {
        var calls = 0;
        final warnings = <String>[];
        final optimizer = SubtitleOptimizer(
          client: AiSubtitleTranslator(
            complete: (_, _) async {
              calls++;
              return invalid;
            },
          ),
        );
        final input = [cue(1), cue(2)];
        final output = await optimizer.optimize(
          cues: input,
          choice: choice,
          endpoint: endpoint,
          onWarning: warnings.add,
        );
        expect(calls, 2);
        expect(warnings, hasLength(1));
        expect(
          output.map((value) => value.text),
          input.map((value) => value.text),
        );
      },
    );
  }
  test(
    'large input batches are bounded without line-by-line or reflection calls',
    () async {
      final sizes = <int>[];
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            sizes.add(sourceOf(messages).length);
            return corrected(messages);
          },
        ),
      );
      final output = await optimizer.optimize(
        cues: List.generate(41, (i) => cue(i + 1)),
        choice: choice,
        endpoint: endpoint,
      );
      expect(sizes, [20, 20, 1]);
      expect(output, hasLength(41));
    },
  );
  test(
    'accidental translation of a short cue is rejected and keeps its source language',
    () async {
      var calls = 0;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, _) async {
            calls++;
            return '{"1":"Hello friend"}';
          },
        ),
      );
      final output = await optimizer.optimize(
        cues: [cue(1).copyWith(text: '你好朋友')],
        choice: choice,
        endpoint: endpoint,
      );
      expect(output.single.text, '你好朋友');
      expect(calls, 2);
    },
  );
  test('background is bounded, stripped and stays advisory data', () {
    final background = subtitleOptimizationBackground(
      title: '标题',
      description:
          '<p>简介</p><script>bad()</script> https://example.test ${'很长' * 2000}',
      tags: ['AI', 'AI', '视频'],
    );
    expect(background, isNot(contains('script')));
    expect(background, isNot(contains('bad()')));
    expect(background, isNot(contains('https://')));
    expect(background.length, lessThan(1100));
    expect(jsonDecode(background)['标签'], 'AI、视频');
    expect(
      subtitleOptimizationBackgroundPreview(background),
      contains('标题：标题'),
    );
    expect(
      subtitleOptimizationBackgroundPreview(background),
      isNot(startsWith('{')),
    );
  });
  test(
    'background follows each queue item rather than current playback',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibiliOfflineDetails': jsonEncode({
          'BV-one': {
            't': '第一期',
            'd': '机器学习入门',
            'o': '作者一',
            'tags': ['AI'],
          },
          'BV-two': {'t': '第二期', 'd': '数据库入门', 'o': '作者二'},
        }),
      });
      VideoItem item(String id) => VideoItem(
        id: id,
        path: '$id.mp4',
        title: id,
        durationMs: 0,
        lastUpdated: 0,
        sourceRef: MediaSourceRef(
          value: id,
          kind: MediaSourceKind.bilibiliBv,
          bvid: id,
        ),
      );
      final first = await SubtitleOptimizationBackground.capture(
        item('BV-one'),
        'fallback',
      );
      final second = await SubtitleOptimizationBackground.capture(
        item('BV-two'),
        'fallback',
      );
      expect(first, contains('机器学习入门'));
      expect(first, contains('AI'));
      expect(second, contains('数据库入门'));
      expect(second, isNot(contains('机器学习入门')));
    },
  );
  test(
    'existing subtitle optimization reuses batches and keeps source bytes unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp('subtitle-file-opt-');
      final input = File('${root.path}/input.srt');
      final bytes = utf8.encode(
        encodeStreamingSrt(List.generate(41, (i) => cue(i + 1))),
      );
      await input.writeAsBytes(bytes);
      var calls = 0;
      final service = SubtitleTranslationService();
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            calls++;
            expect(service.activeOptimizationEnabled, isTrue);
            expect(service.activeTranslationEnabled, isFalse);
            return corrected(messages);
          },
        ),
      );
      Future<SubtitleTranslationResult> run() => service.processSubtitleFile(
        inputPath: input.path,
        optimization: choice,
        optimizationEndpoint: endpoint,
        optimizer: optimizer,
        translationEnabled: false,
        sourceLanguage: 'auto',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.ai,
        onProgress: (_) {},
        outputDirectory: root.path,
      );
      try {
        final first = await run();
        expect(calls, 3);
        expect(service.activeOptimizationEnabled, isNull);
        expect(service.activeTranslationEnabled, isNull);
        expect(first.outputPath, first.optimizedPath);
        expect(first.translationEnabled, isFalse);
        expect(await input.readAsBytes(), bytes);
        expect(await File(first.outputPath).readAsString(), contains('人工智能'));
        final second = await run();
        expect(calls, 3);
        expect(second.outputPath, first.outputPath);
        expect(
          root.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.srt'),
          ),
          hasLength(2),
        );
      } finally {
        service.dispose();
        await root.delete(recursive: true);
      }
    },
  );
  test('cancelled optimization does not fall back to new requests', () async {
    final cancel = Completer<void>(), pending = Completer<String>();
    var calls = 0;
    final optimizer = SubtitleOptimizer(
      client: AiSubtitleTranslator(
        complete: (_, _) {
          calls++;
          return pending.future;
        },
      ),
    );
    final output = optimizer.optimize(
      cues: [cue(1)],
      choice: choice,
      endpoint: endpoint,
      cancelSignal: cancel.future,
    );
    final assertion = expectLater(
      output,
      throwsA(isA<AiSubtitleTranslationCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    await assertion;
    pending.complete('{}');
    expect(calls, 1);
  });
  test(
    'long-text sub-batches checkpoint before a later request fails',
    () async {
      var calls = 0;
      final saved = <int>[];
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            if (++calls == 2) {
              throw const AiChatException('unavailable', statusCode: 503);
            }
            return corrected(messages);
          },
        ),
      );
      await expectLater(
        optimizer.optimize(
          cues: [
            cue(1).copyWith(text: '人工职能' * 600),
            cue(2).copyWith(text: '人工职能' * 600),
          ],
          choice: choice,
          endpoint: endpoint,
          onOptimized: (cues, _) async {
            saved.addAll(cues.map((cue) => cue.index));
          },
        ),
        throwsA(isA<AiChatException>()),
      );
      expect(saved, [1]);
      expect(calls, 2);
    },
  );
  test(
    'a cancelled budget waiter never sends a request or strands a permit',
    () async {
      final gates = <Completer<String>>[];
      final client = AiSubtitleTranslator(
        complete: (_, _) {
          final gate = Completer<String>();
          gates.add(gate);
          return gate.future;
        },
      );
      final settings = endpoint.toChatSettings();
      final active = [
        for (var i = 0; i < 5; i++) client.completeRequest(settings, const []),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(5));
      final cancel = Completer<void>();
      final queued = client.completeRequest(
        settings,
        const [],
        cancelSignal: cancel.future,
      );
      final assertion = expectLater(
        queued,
        throwsA(isA<AiSubtitleTranslationCancelled>()),
      );
      cancel.complete();
      await assertion;
      expect(gates, hasLength(5));
      for (final gate in gates) {
        gate.complete('ok');
      }
      await Future.wait(active);
      final next = client.completeRequest(settings, const []);
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(6));
      gates.last.complete('ok');
      expect(await next, 'ok');
    },
  );

  for (final optimize in [false, true]) {
    for (final translate in [false, true]) {
      test(
        'stream optimize=$optimize translate=$translate selects the right source',
        () async {
          final root = await Directory.systemTemp.createTemp('subtitle-opt-');
          final center = ModelCenterService();
          var optimizeCalls = 0;
          final seen = <String>[];
          final optimizer = SubtitleOptimizer(
            client: AiSubtitleTranslator(
              complete: (_, messages) async {
                optimizeCalls++;
                return corrected(messages);
              },
            ),
          );
          final translator = SubtitleTranslationService(
            aiTranslator: AiSubtitleTranslator(
              complete: (settings, messages) async {
                expect(settings.model, 'translate-model');
                final source =
                    jsonDecode(
                          messages.firstWhere(
                            (m) => m['role'] == 'user',
                          )['content']!,
                        )
                        as Map;
                seen.addAll(source.values.cast<String>());
                return jsonEncode({
                  for (final key in source.keys) '$key': 'translated $key',
                });
              },
            ),
          );
          final store = await StreamingSubtitleStore.create(
            File('${root.path}/stream.jsonl'),
            {
              'generationId': 'test',
              'primaryPath': '${root.path}/primary.srt',
              'secondaryPath': translate ? '${root.path}/translated.srt' : null,
            },
          );
          final stream = LocalTranscriptionStream(
            openStore: () async => store,
            choice: translate
                ? const TranscriptTranslateChoice(
                    enabled: true,
                    direction: TranscriptTranslateDirection.auto,
                    provider: SubtitleTranslateProvider.ai,
                    aiOptions: AiSubtitleTranslationSettings(threadNum: 1),
                    targetLanguage: 'en',
                  )
                : const TranscriptTranslateChoice.off(),
            center: center,
            translator: translator,
            endpoint: endpoint.copyWith(model: 'translate-model'),
            optimization: optimize
                ? choice
                : const SubtitleOptimizationChoice.off(),
            optimizationEndpoint: endpoint,
            optimizer: optimizer,
            cancelSignal: Completer<void>().future,
            checkCancelled: () {},
            onFailure: () {},
            onActivity: (_, _) {},
            onCommitted: (_, _, _) async {},
          );
          try {
            await stream.accept(
              StableAsrBatch(
                [cue(1), cue(2)],
                const Duration(seconds: 3),
                null,
              ),
            );
            await stream.drain();
            expect(store.primary.snapshot, hasLength(2));
            expect(store.secondary.snapshot, hasLength(translate ? 2 : 0));
            expect(optimizeCalls, optimize ? 1 : 0);
            expect(
              store.primary.snapshot.first.text,
              contains(optimize ? '人工智能' : '人工职能'),
            );
            if (translate) {
              expect(
                seen.every((s) => s.contains(optimize ? '人工智能' : '人工职能')),
                isTrue,
              );
            }
            // Replayed/overlapping stable ASR prefixes cannot issue duplicate calls.
            await stream.accept(
              StableAsrBatch(
                [cue(1), cue(2)],
                const Duration(seconds: 3),
                null,
              ),
            );
            await stream.drain();
            expect(store.primary.snapshot, hasLength(2));
            expect(optimizeCalls, optimize ? 1 : 0);
          } finally {
            await stream.close();
            translator.dispose();
            center.dispose();
            await root.delete(recursive: true);
          }
        },
      );
    }
  }

  test(
    'optimization survives translation failure and journal reopen without spending again',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'subtitle-opt-recovery-',
      );
      final center = ModelCenterService();
      var calls = 0, fail = true;
      final optimizer = SubtitleOptimizer(
        client: AiSubtitleTranslator(
          complete: (_, messages) async {
            calls++;
            return corrected(messages);
          },
        ),
      );
      final translator = SubtitleTranslationService(
        aiTranslator: AiSubtitleTranslator(
          complete: (_, messages) async {
            if (fail) throw const AiChatException('bad key', statusCode: 401);
            return '{"0":"translation"}';
          },
        ),
      );
      var store = await StreamingSubtitleStore.create(
        File('${root.path}/stream.jsonl'),
        {
          'generationId': 'test',
          'primaryPath': '${root.path}/primary.srt',
          'secondaryPath': '${root.path}/translation.srt',
        },
      );
      LocalTranscriptionStream stream() => LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          direction: TranscriptTranslateDirection.auto,
          provider: SubtitleTranslateProvider.ai,
          aiOptions: AiSubtitleTranslationSettings(threadNum: 1),
          targetLanguage: 'en',
        ),
        center: center,
        translator: translator,
        endpoint: endpoint,
        optimization: choice,
        optimizationEndpoint: endpoint,
        optimizer: optimizer,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onFailure: () {},
        onActivity: (_, _) {},
        onCommitted: (_, _, _) async {},
      );
      var consumer = stream();
      try {
        await consumer.accept(
          StableAsrBatch([cue(1)], const Duration(seconds: 2), null),
        );
        await expectLater(consumer.drain(), throwsA(isA<AiChatException>()));
        await consumer.close();
        expect(calls, 1);
        store = await StreamingSubtitleStore.open(store.journal);
        expect(store.pendingOptimizations[1], contains('人工智能'));
        fail = false;
        consumer = stream();
        await consumer.accept(
          StableAsrBatch([cue(1)], const Duration(seconds: 2), null),
        );
        await consumer.drain();
        expect(calls, 1);
        expect(store.primary.snapshot.single.text, contains('人工智能'));
        expect(store.pendingOptimizations, isEmpty);
      } finally {
        await consumer.close();
        translator.dispose();
        center.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
