import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_transport.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

const endpoint = AiSubtitleApiSettings(
  baseUrl: 'https://pipeline.example/v1',
  apiKey: 'same-account',
  model: 'proofreader',
);
const optimization = SubtitleOptimizationChoice(endpoint: endpoint);

List<SubtitleItem> cues(int first, int count) => [
  for (var i = first; i < first + count; i++)
    SubtitleItem(
      index: i,
      startTime: Duration(seconds: i),
      endTime: Duration(seconds: i + 1),
      text: '第$i条，打开设制页面。',
    ),
];

Future<void> until(bool Function() ready) async {
  await (() async {
    while (!ready()) {
      await Future<void>.delayed(Duration.zero);
    }
  })().timeout(const Duration(seconds: 5));
}

class _Pipeline {
  final center = ModelCenterService();
  final cancelled = Completer<void>();
  final optimizeGates = <int, Completer<void>>{};
  final translateGates = <int, Completer<void>>{};
  final optimized = <int>[];
  final translated = <int>[];
  final optimizationContexts = <int, String>{};
  final failOptimization = <int>{};
  final failTranslation = <int>{};
  final commits = <List<int>>[];
  var failures = 0;
  late Directory directory;
  late StreamingSubtitleStore store;
  late LocalTranscriptionStream stream;
  late final client = AiSubtitleTranslator(complete: complete);
  late final optimizer = SubtitleOptimizer(client: client);
  late final translator = SubtitleTranslationService(aiTranslator: client);

  Future<void> open() async {
    directory = await Directory.systemTemp.createTemp('subtitle-pipeline-');
    store = await StreamingSubtitleStore.create(
      File('${directory.path}/journal.jsonl'),
      {
        'generationId': 'pipeline',
        'primaryPath': '${directory.path}/primary.srt',
        'secondaryPath': '${directory.path}/translation.srt',
      },
    );
    stream = createStream();
  }

  LocalTranscriptionStream createStream({
    SubtitleTranslateProvider provider = SubtitleTranslateProvider.ai,
    SubtitleTranslationService? translationService,
    bool translate = true,
  }) => LocalTranscriptionStream(
    openStore: () async => store,
    choice: TranscriptTranslateChoice(
      enabled: translate,
      direction: TranscriptTranslateDirection.auto,
      provider: provider,
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en',
      aiOptions: const AiSubtitleTranslationSettings(
        batchSize: 20,
        threadNum: 1,
      ),
    ),
    endpoint: endpoint.copyWith(model: 'translator'),
    optimization: optimization,
    optimizationEndpoint: endpoint,
    optimizer: optimizer,
    center: center,
    translator: translationService ?? translator,
    cancelSignal: cancelled.future,
    checkCancelled: () {
      if (cancelled.isCompleted) throw AiSubtitleTranslationCancelled();
    },
    onCommitted: (_, primary, secondary) async {
      if (translate) {
        expect(primary.map((c) => c.index), secondary.map((c) => c.index));
      } else {
        expect(secondary, isEmpty);
      }
      commits.add(primary.map((c) => c.index).toList());
    },
    onActivity: (_, _) {},
    onFailure: () => failures++,
  );

  Future<String> complete(
    AiChatSettings settings,
    List<Map<String, String>> messages,
  ) async {
    final body =
        jsonDecode(messages.firstWhere((m) => m['role'] == 'user')['content']!)
            as Map;
    final isOptimization = settings.model == 'proofreader';
    final source = isOptimization ? body['字幕'] as Map : body;
    final first = int.parse(
      RegExp(r'第(\d+)条').firstMatch(source.values.first as String)!.group(1)!,
    );
    if (isOptimization) {
      optimized.add(first);
      optimizationContexts[first] = body['前文（不输出）'] as String? ?? '';
      await optimizeGates[first]?.future;
      if (failOptimization.contains(first)) {
        throw const AiChatException('optimization failed', statusCode: 401);
      }
      return jsonEncode({
        '修改': {
          for (final e in source.entries)
            e.key: (e.value as String).replaceAll('设制', '设置'),
        },
      });
    }
    translated.add(first);
    expect(
      source.values.every((text) => (text as String).contains('设置')),
      isTrue,
    );
    await translateGates[first]?.future;
    if (failTranslation.contains(first)) {
      throw const AiChatException('translation failed', statusCode: 401);
    }
    return jsonEncode({
      for (final e in source.entries) e.key: 'Translation ${e.value}',
    });
  }

  Future<void> process({
    bool oneInput = false,
    bool native = false,
    int count = 60,
  }) async {
    if (oneInput) {
      await stream.accept(
        StableAsrBatch(
          cues(1, count),
          const Duration(seconds: 100),
          null,
          nativePipeline: native,
          retainConsumerModels: native,
        ),
      );
    } else {
      for (var first = 1; first <= count; first += 20) {
        final size = (count - first + 1).clamp(1, 20);
        await stream.accept(
          StableAsrBatch(
            cues(first, size),
            Duration(seconds: first + size),
            null,
          ),
        );
      }
    }
    await stream.drain();
  }

  void release() {
    for (final gate in [...optimizeGates.values, ...translateGates.values]) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> close() async {
    release();
    await stream.close();
    translator.dispose();
    center.dispose();
    await directory.delete(recursive: true);
  }
}

class _LocalTranslator extends SubtitleTranslationService {
  final starts = <int>[];
  final sessions = <LocalTranslationSession?>[];
  final reservations = <InferenceReservation?>[];
  final gates = {1: Completer<void>(), 21: Completer<void>()};
  var active = 0;

  @override
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) async {
    expect(provider, SubtitleTranslateProvider.local);
    expect(
      active++,
      0,
      reason: 'Native translation calls must stay serialized.',
    );
    starts.add(items.first.index);
    sessions.add(localSession);
    reservations.add(reservation);
    try {
      await reservation!.owner.run(() async {}, reservation: reservation);
      await gates[items.first.index]!.future;
      return [for (final cue in items) 'Translation ${cue.index}'];
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Pipeline pipeline;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pipeline = _Pipeline();
    await pipeline.open();
  });
  tearDown(() => pipeline.close());

  for (final native in [false, true]) {
    test(
      'optimization alone publishes each block of a large input; native=$native',
      () async {
        pipeline.store = await StreamingSubtitleStore.create(
          File('${pipeline.directory.path}/optimization-only.jsonl'),
          {
            'generationId': 'optimization-only',
            'primaryPath': '${pipeline.directory.path}/optimized.srt',
          },
        );
        pipeline.stream = pipeline.createStream(
          provider: SubtitleTranslateProvider.bing,
          translate: false,
        );
        pipeline.optimizeGates[21] = Completer<void>();
        final work = pipeline.process(
          oneInput: true,
          native: native,
          count: 40,
        );
        try {
          await until(() => pipeline.optimized.contains(21));
          await until(() => pipeline.commits.isNotEmpty);
          expect(pipeline.commits.single, List.generate(20, (i) => i + 1));
          expect(pipeline.store.primary.snapshot, hasLength(20));
          expect(pipeline.store.through, const Duration(seconds: 21));
          expect(
            await File(pipeline.store.primaryPath).readAsString(),
            contains('打开设置页面'),
          );
          expect(pipeline.translated, isEmpty);

          pipeline.release();
          await work;
          expect(pipeline.commits.map((batch) => batch.first), [1, 21]);
          expect(pipeline.store.primary.snapshot, hasLength(40));
          expect(pipeline.store.through, const Duration(seconds: 100));
        } finally {
          pipeline.release();
          await work;
        }
      },
    );
  }

  test('optimization alone resumes after a later block fails', () async {
    pipeline.store = await StreamingSubtitleStore.create(
      File('${pipeline.directory.path}/optimization-resume.jsonl'),
      {
        'generationId': 'optimization-resume',
        'primaryPath': '${pipeline.directory.path}/optimized-resume.srt',
      },
    );
    pipeline.stream = pipeline.createStream(
      provider: SubtitleTranslateProvider.bing,
      translate: false,
    );
    pipeline.failOptimization.add(21);
    await expectLater(
      pipeline.process(oneInput: true, count: 40),
      throwsA(isA<AiChatException>()),
    );
    await pipeline.stream.close();
    pipeline.store = await StreamingSubtitleStore.open(pipeline.store.journal);
    expect(pipeline.store.primary.snapshot, hasLength(20));
    expect(pipeline.store.primary.snapshot.first.text, contains('设置'));

    pipeline.failOptimization.clear();
    pipeline.stream = pipeline.createStream(
      provider: SubtitleTranslateProvider.bing,
      translate: false,
    );
    await pipeline.process(oneInput: true, count: 40);
    expect(pipeline.optimized, [1, 21, 21]);
    expect(pipeline.commits.map((batch) => batch.first), [1, 21]);
    expect(
      pipeline.store.primary.snapshot.map((cue) => cue.index),
      List.generate(40, (index) => index + 1),
    );
  });

  test(
    'the next optimization overlaps translation, with bounded lookahead and corrected context',
    () async {
      pipeline.optimizeGates[21] = Completer<void>();
      pipeline.optimizeGates[41] = Completer<void>();
      pipeline.translateGates[1] = Completer<void>();
      pipeline.translateGates[21] = Completer<void>();
      final work = pipeline.process();
      try {
        await until(
          () =>
              pipeline.translated.contains(1) &&
              pipeline.optimized.contains(21),
        );
        expect(pipeline.store.primary.snapshot, isEmpty);
        expect(pipeline.optimizationContexts[21], contains('第20条，打开设置页面。'));
        pipeline.optimizeGates[21]!.complete();
        await until(() => pipeline.store.pendingOptimizations.length == 40);
        expect(
          pipeline.optimized,
          [1, 21],
          reason: 'A slow translation must bound optimization lookahead.',
        );
        expect(pipeline.translated, [1]);
        pipeline.translateGates[1]!.complete();
        await until(
          () =>
              pipeline.translated.contains(21) &&
              pipeline.optimized.contains(41),
        );
        expect(pipeline.store.primary.snapshot, hasLength(20));
        expect(pipeline.commits.single, List.generate(20, (i) => i + 1));
        pipeline.release();
        await work;
        expect(pipeline.commits.map((c) => c.first), [1, 21, 41]);
        expect(
          pipeline.store.primary.snapshot.map((c) => c.index),
          List.generate(60, (i) => i + 1),
        );
        expect(
          pipeline.store.secondary.snapshot.map((c) => c.startTime),
          cues(1, 60).map((c) => c.startTime),
        );
        expect(pipeline.failures, 0);
      } finally {
        pipeline.release();
        await work;
      }
    },
  );

  for (final native in [false, true]) {
    test(
      'large stable inputs hand off the first block before all optimization finishes; native=$native',
      () async {
        pipeline.optimizeGates[21] = Completer<void>();
        pipeline.translateGates[1] = Completer<void>();
        final work = pipeline.process(
          oneInput: true,
          native: native,
          count: 40,
        );
        try {
          await until(
            () =>
                pipeline.translated.contains(1) &&
                pipeline.optimized.contains(21),
          );
          expect(pipeline.store.pendingOptimizations, hasLength(20));
          pipeline.translateGates[1]!.complete();
          await until(() => pipeline.store.primary.snapshot.length == 20);
          expect(pipeline.store.through, const Duration(seconds: 21));
          pipeline.release();
          await work;
          expect(pipeline.store.through, const Duration(seconds: 100));
          expect(pipeline.store.secondary.snapshot, hasLength(40));
        } finally {
          pipeline.release();
          await work;
        }
      },
    );
  }

  test(
    'local translation keeps its borrowed reservation until both stages finish',
    () async {
      final local = _LocalTranslator();
      addTearDown(local.dispose);
      pipeline.stream = pipeline.createStream(
        provider: SubtitleTranslateProvider.local,
        translationService: local,
      );
      pipeline.optimizeGates[21] = Completer<void>();
      final scheduler = InferenceScheduler();
      var accepted = false;
      final work = scheduler.run(() async {
        await pipeline.stream.accept(
          StableAsrBatch(
            cues(1, 40),
            const Duration(seconds: 100),
            scheduler.currentReservation,
            retainConsumerModels: true,
          ),
        );
        accepted = true;
        await pipeline.stream.drain();
      });
      try {
        await until(
          () => local.starts.contains(1) && pipeline.optimized.contains(21),
        );
        expect(accepted, isFalse);
        expect(scheduler.busy, isTrue);
        local.gates[1]!.complete();
        pipeline.optimizeGates[21]!.complete();
        await until(() => local.starts.contains(21));
        expect(accepted, isFalse);
        expect(local.sessions.first, isNotNull);
        expect(local.sessions.last, same(local.sessions.first));
        expect(local.reservations.last, same(local.reservations.first));
        local.gates[21]!.complete();
        await work;
        expect(accepted, isTrue);
        expect(scheduler.busy, isFalse);
        expect(pipeline.store.secondary.snapshot, hasLength(40));
      } finally {
        pipeline.release();
        for (final gate in local.gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await work;
      }
    },
  );

  test(
    'a later optimization failure still publishes the earlier successful translation',
    () async {
      pipeline.translateGates[1] = Completer<void>();
      pipeline.failOptimization.add(21);
      final work = pipeline.process();
      final failed = expectLater(work, throwsA(isA<AiChatException>()));
      await until(
        () =>
            pipeline.optimized.contains(21) && pipeline.translated.contains(1),
      );
      expect(pipeline.failures, 0);
      expect(pipeline.store.primary.snapshot, isEmpty);
      pipeline.release();
      await failed;
      expect(pipeline.store.primary.snapshot, hasLength(20));
      expect(pipeline.translated, [1]);
      expect(pipeline.optimized, [1, 21]);
      expect(pipeline.failures, 1);
    },
  );

  test(
    'translation failure retains ahead-of-translation optimization checkpoints for resume',
    () async {
      pipeline.translateGates[1] = Completer<void>();
      pipeline.failTranslation.add(1);
      final work = pipeline.process(count: 40);
      final failed = expectLater(work, throwsA(isA<AiChatException>()));
      await until(() => pipeline.store.pendingOptimizations.length == 40);
      pipeline.release();
      await failed;
      await pipeline.stream.close();
      expect(pipeline.store.primary.snapshot, isEmpty);
      expect(pipeline.translated, [1]);
      pipeline.store = await StreamingSubtitleStore.open(
        pipeline.store.journal,
      );
      expect(pipeline.store.pendingOptimizations, hasLength(40));
      pipeline.failTranslation.clear();
      pipeline.stream = pipeline.createStream();
      await pipeline.process(count: 40);
      expect(
        pipeline.optimized,
        [1, 21],
        reason: 'Resume must not spend tokens optimizing saved blocks again.',
      );
      expect(pipeline.store.primary.snapshot, hasLength(40));
      expect(pipeline.store.secondary.snapshot, hasLength(40));
    },
  );

  test(
    'cancellation drains both stages without late publication or new requests',
    () async {
      pipeline.optimizeGates[21] = Completer<void>();
      pipeline.translateGates[1] = Completer<void>();
      final work = pipeline.process();
      final stopped = expectLater(
        work,
        throwsA(isA<AiSubtitleTranslationCancelled>()),
      );
      await until(
        () =>
            pipeline.translated.contains(1) && pipeline.optimized.contains(21),
      );
      pipeline.cancelled.complete();
      await stopped;
      await pipeline.stream.close();
      expect(pipeline.store.primary.snapshot, isEmpty);
      expect(pipeline.store.pendingOptimizations, hasLength(20));
      final journalBytes = await pipeline.store.journal.length();
      pipeline.release();
      await Future<void>.delayed(Duration.zero);
      expect(await pipeline.store.journal.length(), journalBytes);
      expect(pipeline.optimized, [1, 21]);
      expect(pipeline.translated, [1]);
      expect(pipeline.commits, isEmpty);
    },
  );

  test(
    'manual subtitle processing uses the same pipeline and preserves source bytes',
    () async {
      final source = File('${pipeline.directory.path}/source.srt');
      final original = encodeStreamingSrt(cues(1, 41));
      await source.writeAsString(original);
      pipeline.translateGates[1] = Completer<void>();
      final published = <int>[];
      final work = pipeline.translator.processSubtitleFile(
        inputPath: source.path,
        optimization: optimization,
        optimizationEndpoint: endpoint,
        optimizer: pipeline.optimizer,
        translationEnabled: true,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        provider: SubtitleTranslateProvider.ai,
        aiEndpoint: endpoint.copyWith(model: 'translator'),
        aiOptions: const AiSubtitleTranslationSettings(
          batchSize: 20,
          threadNum: 1,
        ),
        onProgress: (_) {},
        onBatchCommitted: (value) async => published.add(value.totalCount),
      );
      try {
        await until(
          () =>
              pipeline.translated.contains(1) &&
              pipeline.optimized.contains(21),
        );
        expect(published, isEmpty);
        pipeline.release();
        final result = await work;
        expect(result.totalCount, 41);
        expect(published, [20, 40, 41]);
        expect(await source.readAsString(), original);
      } finally {
        pipeline.release();
        await work;
      }
    },
  );
}
