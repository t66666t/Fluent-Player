import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/translation_inference.dart';

class _Engine implements TranslationInference {
  _Engine(this.backend, this.gpuLayers);
  @override
  final String backend;
  @override
  final int gpuLayers;
  bool disposed = false;
  Map<String, Object?>? generation;
  @override
  Future<TranslationGeneration> generate(
    String prompt, {
    String? grammar,
    bool structured = false,
    bool reusePromptPrefix = true,
    void Function(String)? onDelta,
  }) async {
    generation = {
      'prompt': prompt,
      'grammar': grammar,
      'structured': structured,
      'reusePromptPrefix': reusePromptPrefix,
    };
    onDelta?.call('你好');
    return const TranslationGeneration(
      text: '你好',
      promptTokens: 8,
      generatedTokens: 2,
    );
  }

  @override
  void cancel() {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  late Directory temporary;
  late String model;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('translation-protocol-');
    model = (await File(
      '${temporary.path}/model.gguf',
    ).writeAsString('fixture')).path;
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Map<String, Object> command() => {
    'op': 'load',
    'model': model,
    'backend': 'vulkan',
    'threads': 2,
    'gpuLayers': 32,
  };

  for (final backend in ['CPU', 'CUDA']) {
    test(
      'a $backend result cannot be reported as the selected Vulkan route',
      () async {
        final engine = _Engine(backend, 32);
        final server = TranslationWorkerServer(load: (_, _) async => engine);
        await expectLater(
          server.request(command(), platform: 'windows', onDelta: (_) {}),
          throwsStateError,
        );
        expect(engine.disposed, isTrue);
        await server.close();
      },
    );
  }
  test(
    'private server preserves structured requests, token streaming and final metadata',
    () async {
      final engine = _Engine('Vulkan', 32);
      final server = TranslationWorkerServer(load: (_, _) async => engine);
      final loaded = await server.request(
        command(),
        platform: 'windows',
        onDelta: (_) {},
      );
      expect(loaded['gpuLayers'], 32);
      await expectLater(
        server.request(command(), platform: 'windows', onDelta: (_) {}),
        throwsStateError,
      );
      final deltas = <String>[];
      final result = await server.request({
        'op': 'generate',
        'prompt': 'Hello',
        'grammar': 'root ::= "你好"',
        'structured': true,
        'reusePromptPrefix': false,
      }, onDelta: deltas.add);
      expect(engine.generation, {
        'prompt': 'Hello',
        'grammar': 'root ::= "你好"',
        'structured': true,
        'reusePromptPrefix': false,
      });
      expect(deltas, ['你好']);
      expect(result['text'], '你好');
      expect(result['promptTokens'], 8);
      expect(result['generatedTokens'], 2);
      await server.close();
      expect(engine.disposed, isTrue);
    },
  );
}
