import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/bing_subtitle_translator.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

class _BingAdapter implements HttpClientAdapter {
  int sessions = 0, posts = 0, active = 0, peak = 0;
  final forms = <Map<String, String>>[];
  Future<ResponseBody> Function(Map<String, String>, int)? respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      sessions++;
      return ResponseBody.fromString(
        'IG:"test-session" <div data-iid="translator">'
        'var params_AbusePreventionHelper = [123456,"test-token",3600000];',
        200,
        headers: {
          'content-type': ['text/html'],
        },
      );
    }
    final form = options.data is String
        ? Uri.splitQueryString(options.data as String)
        : (options.data as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
    forms.add(form);
    posts++;
    active++;
    if (active > peak) peak = active;
    try {
      return await Future.any([
        respond?.call(form, posts) ?? Future.value(reply(form)),
        if (cancelFuture != null)
          cancelFuture.then<ResponseBody>(
            (_) => throw DioException.requestCancelled(
              requestOptions: options,
              reason: 'stopped',
            ),
          ),
      ]);
    } finally {
      active--;
    }
  }

  static ResponseBody json(
    Object value, {
    int status = 200,
    Map<String, List<String>>? headers,
  }) => ResponseBody.fromString(
    jsonEncode(value),
    status,
    headers: {
      'content-type': ['application/json'],
      ...?headers,
    },
  );
  static ResponseBody translated(String value) => json([
    {
      'translations': [
        {'text': value, 'to': 'zh-Hans'},
      ],
    },
  ]);
  static ResponseBody reply(Map<String, String> form) {
    final text = form['text']!;
    final markers = RegExp(r'\[(\d{4})\] ([^\n]*)').allMatches(text).toList();
    return translated(
      markers.isEmpty
          ? '译 $text'
          : markers.map((m) => '[${m[1]}] 译 ${m[2]}').join('\n'),
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<List<String>> translate(
  BingSubtitleTranslator client,
  List<String> texts, {
  CancelToken? cancel,
  void Function(int, String)? onTranslated,
}) => client.translate(
  texts: texts,
  sourceLanguage: 'en',
  targetLanguage: 'zh-Hans',
  onProgress: (_) {},
  onTranslated: onTranslated,
  cancelToken: cancel,
);

SubtitleItem cue(int id, String text) => SubtitleItem(
  index: id,
  text: text,
  startTime: Duration(seconds: id * 3),
  endTime: Duration(seconds: id * 3 + 2),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _BingAdapter adapter;
  late Dio dio;
  setUp(() {
    adapter = _BingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });
  tearDown(() => dio.close(force: true));

  for (final status in [408, 500, 502, 503, 504]) {
    test('temporary HTTP $status retries without losing the cue', () async {
      final waits = <Duration>[];
      adapter.respond = (form, sequence) async => sequence == 1
          ? _BingAdapter.json({'error': 'temporary'}, status: status)
          : _BingAdapter.reply(form);
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
        delay: (value) async => waits.add(value),
      );
      final published = <int>[];

      expect(
        await translate(client, [
          'first',
        ], onTranslated: (i, _) => published.add(i)),
        ['译 first'],
      );
      expect(adapter.posts, 2);
      expect(adapter.sessions, 1);
      expect(waits, [const Duration(seconds: 1)]);
      expect(published, [0]);
      expect(adapter.active, 0);
    });
  }

  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
  ]) {
    test('temporary $type recovers within the same translation call', () async {
      adapter.respond = (form, sequence) async {
        if (sequence == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/ttranslatev3'),
            type: type,
          );
        }
        return _BingAdapter.reply(form);
      };
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
        delay: (_) async {},
      );
      expect(await translate(client, ['first']), ['译 first']);
      expect(adapter.posts, 2);
      expect(adapter.active, 0);
    });
  }

  test('persistent server failure has a bounded retry budget', () async {
    final waits = <Duration>[];
    adapter.respond = (_, _) async =>
        _BingAdapter.json({'error': 'unavailable'}, status: 503);
    final client = BingSubtitleTranslator(
      dio: dio,
      requestInterval: Duration.zero,
      delay: (value) async => waits.add(value),
    );
    await expectLater(
      translate(client, ['first']),
      throwsA(isA<BingTranslationException>()),
    );
    expect(adapter.posts, 3);
    expect(waits, [const Duration(seconds: 1), const Duration(seconds: 3)]);
    expect(adapter.active, 0);
  });

  test(
    '503 Retry-After keeps the shared server cooldown without replay',
    () async {
      final now = DateTime.utc(2026, 10, 31);
      adapter.respond = (_, _) async => _BingAdapter.json(
        {'error': 'unavailable'},
        status: 503,
        headers: {
          'retry-after': ['120'],
        },
      );
      final client = BingSubtitleTranslator(
        dio: dio,
        now: () => now,
        requestInterval: Duration.zero,
      );
      final blocked = isA<BingTranslationException>().having(
        (e) => e.retryAt,
        'retryAt',
        now.add(const Duration(minutes: 2)),
      );
      await expectLater(translate(client, ['first']), throwsA(blocked));
      await expectLater(translate(client, ['second']), throwsA(blocked));
      expect(adapter.posts, 1);
    },
  );

  test('invalid requests do not enter the transient retry loop', () async {
    adapter.respond = (_, _) async =>
        _BingAdapter.json({'error': 'invalid request'}, status: 400);
    final client = BingSubtitleTranslator(
      dio: dio,
      requestInterval: Duration.zero,
      delay: (_) async => fail('permanent failures must not be retried'),
    );
    await expectLater(
      translate(client, ['first']),
      throwsA(isA<BingTranslationException>()),
    );
    expect(adapter.posts, 1);
  });

  test('cancelling during retry delay prevents further requests', () async {
    final waiting = Completer<void>(), release = Completer<void>();
    adapter.respond = (form, sequence) async => sequence == 1
        ? _BingAdapter.json({'error': 'unavailable'}, status: 503)
        : _BingAdapter.reply(form);
    final client = BingSubtitleTranslator(
      dio: dio,
      concurrency: 1,
      requestInterval: Duration.zero,
      delay: (_) async {
        waiting.complete();
        await release.future;
      },
    );
    final cancellation = CancelToken();
    final task = expectLater(
      translate(client, ['first'], cancel: cancellation),
      throwsA(isA<DioException>()),
    );
    try {
      await waiting.future.timeout(const Duration(seconds: 2));
      cancellation.cancel('user stopped');
      await task.timeout(const Duration(seconds: 2));
      expect(adapter.posts, 1);
      // Backoff must not hold the shared request slot or cancel other callers.
      expect(await translate(client, ['second']), ['译 second']);
      expect(adapter.posts, 2);
    } finally {
      cancellation.cancel();
      release.complete();
      await task;
    }
  });

  test(
    'out-of-order batches preserve IDs, deduplicate text and share cache',
    () async {
      final gate = Completer<void>();
      adapter.respond = (form, seq) async {
        if (seq == 1) await gate.future;
        return _BingAdapter.reply(form);
      };
      final client = BingSubtitleTranslator(
        dio: dio,
        batchSize: 2,
        requestInterval: Duration.zero,
      );
      final callbacks = <int>[];
      final pending = translate(client, [
        'first',
        'second',
        'third',
        'fourth',
        'first',
      ], onTranslated: (i, _) => callbacks.add(i));
      while (!callbacks.contains(2)) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(callbacks, isNot(contains(0)));
      gate.complete();
      expect(await pending, [
        '译 first',
        '译 second',
        '译 third',
        '译 fourth',
        '译 first',
      ]);
      expect(adapter.posts, 2);
      expect(adapter.sessions, 1);
      expect(await translate(client, ['fourth', 'first']), [
        '译 fourth',
        '译 first',
      ]);
      expect(adapter.posts, 2);
      expect(callbacks.toSet(), {0, 1, 2, 3, 4});
    },
  );

  test(
    'missing markers split the batch without accepting merged text',
    () async {
      adapter.respond = (form, seq) async => form['text']!.contains('[0001]')
          ? _BingAdapter.translated('merged paragraph')
          : _BingAdapter.reply(form);
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
      );
      expect(await translate(client, ['one', 'two', 'three', 'four']), [
        '译 one',
        '译 two',
        '译 three',
        '译 four',
      ]);
      expect(adapter.posts, 7);
    },
  );

  test(
    'English passthrough is reviewed separately from Chinese content',
    () async {
      adapter.respond = (form, seq) async {
        if (seq == 1) {
          return _BingAdapter.translated('[0000] understand [0001] 已是中文');
        }
        return _BingAdapter.reply(form);
      };
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
      );
      expect(await translate(client, ['understand', '原文中文']), [
        '译 understand',
        '已是中文',
      ]);
      expect(adapter.posts, 2);
    },
  );

  test(
    '429 honors a long Retry-After across subsequent calls without replay',
    () async {
      var now = DateTime.utc(2026, 10, 21);
      adapter.respond = (_, _) async => _BingAdapter.json(
        {'StatusCode': 429},
        status: 429,
        headers: {
          'retry-after': ['7200'],
        },
      );
      final client = BingSubtitleTranslator(
        dio: dio,
        now: () => now,
        concurrency: 1,
        requestInterval: Duration.zero,
      );
      final blocked = isA<BingTranslationException>().having(
        (e) => e.retryAt,
        'retryAt',
        now.add(const Duration(hours: 2)),
      );
      await expectLater(translate(client, ['first']), throwsA(blocked));
      now = now.add(const Duration(minutes: 30));
      await expectLater(
        translate(client, ['second']),
        throwsA(isA<BingTranslationException>()),
      );
      expect(adapter.posts, 1);
      expect(adapter.sessions, 1);
    },
  );

  test(
    'HTTP 200 captcha pauses the shared client instead of refreshing tokens',
    () async {
      adapter.respond = (_, _) async =>
          _BingAdapter.json({'ShowCaptcha': true});
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
      );
      await expectLater(
        translate(client, ['first']),
        throwsA(isA<BingTranslationException>()),
      );
      await expectLater(
        translate(client, ['second']),
        throwsA(isA<BingTranslationException>()),
      );
      expect(adapter.posts, 1);
      expect(adapter.sessions, 1);
    },
  );

  test(
    'concurrent callers share the same four-request limit; cancellation releases slots',
    () async {
      final gate = Completer<void>();
      adapter.respond = (form, _) async {
        await gate.future;
        return _BingAdapter.reply(form);
      };
      final client = BingSubtitleTranslator(
        dio: dio,
        batchSize: 1,
        requestInterval: Duration.zero,
      );
      final stop = CancelToken();
      var callbacks = 0;
      final first = translate(
        client,
        List.generate(8, (i) => 'first$i'),
        cancel: stop,
        onTranslated: (_, _) => callbacks++,
      );
      final rejected = expectLater(first, throwsA(isA<DioException>()));
      while (adapter.active < 4) {
        await Future<void>.delayed(Duration.zero);
      }
      final second = translate(client, ['separate caller']);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.peak, 4);
      stop.cancel();
      await rejected;
      gate.complete();
      expect(await second, ['译 separate caller']);
      expect(callbacks, 0);
      expect(adapter.peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'long Unicode cues are split without truncating text or leaving markers',
    () async {
      final text = '${'word ' * 450}😀 end';
      final client = BingSubtitleTranslator(
        dio: dio,
        requestInterval: Duration.zero,
      );
      final output = (await translate(client, [text])).single;
      expect(output, contains('😀 end'));
      expect(output.split('word').length, text.split('word').length);
      expect(output, isNot(contains('[0000]')));
      expect(adapter.forms.every((f) => f['text']!.length <= 900), isTrue);
    },
  );

  test(
    'native ASR can prepare its next block while Bing is pending and commits stay ordered',
    () async {
      final gate = Completer<void>(), started = Completer<void>();
      final secondStarted = Completer<void>();
      adapter.respond = (form, seq) async {
        if (seq == 1) {
          started.complete();
          await gate.future;
        }
        if (seq == 2) secondStarted.complete();
        return _BingAdapter.reply(form);
      };
      final service = SubtitleTranslationService(
        dio: dio,
        bingTranslator: BingSubtitleTranslator(
          dio: dio,
          requestInterval: Duration.zero,
        ),
      );
      final folder = await Directory.systemTemp.createTemp(
        'bing-native-stream-',
      );
      final store = await StreamingSubtitleStore.create(
        File('${folder.path}/journal.jsonl'),
        {
          'generationId': 'test',
          'primaryPath': '${folder.path}/source.srt',
          'secondaryPath': '${folder.path}/translated.srt',
        },
      );
      final committed = <int>[];
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          provider: SubtitleTranslateProvider.bing,
          direction: TranscriptTranslateDirection.toChinese,
          aiOptions: AiSubtitleTranslationSettings.defaults,
        ),
        center: ModelCenterService(),
        translator: service,
        recognitionLanguage: 'en',
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, primary, _) async =>
            committed.addAll(primary.map((c) => c.index)),
        onActivity: (_, _) {},
        onFailure: () {},
      );
      try {
        await stream
            .accept(
              StableAsrBatch(
                [cue(1, 'first')],
                const Duration(seconds: 30),
                null,
                nativePipeline: true,
              ),
            )
            .timeout(const Duration(seconds: 1));
        await started.future;
        var secondAccepted = false;
        final second = stream
            .accept(
              StableAsrBatch(
                [cue(1, 'first'), cue(2, 'second')],
                const Duration(seconds: 60),
                null,
                nativePipeline: true,
              ),
            )
            .then((_) => secondAccepted = true);
        await secondStarted.future.timeout(const Duration(seconds: 1));
        expect(secondAccepted, isFalse);
        expect(adapter.posts, 2);
        expect(adapter.forms.last['text'], 'second');
        expect(committed, isEmpty);
        gate.complete();
        await second;
        await stream.drain();
        expect(committed, [1, 2]);
        expect(adapter.sessions, 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await stream.close();
        await store.drained;
        await folder.delete(recursive: true);
      }
    },
  );

  for (final cancel in [false, true]) {
    test(
      cancel
          ? 'cancelling parallel Bing blocks prevents late publication'
          : 'a later Bing preparation failure preserves the earlier ordered commit',
      () async {
        final gate = Completer<void>(), secondStarted = Completer<void>();
        final cancellation = Completer<void>();
        adapter.respond = (form, seq) async {
          if (form['text'] == 'second') {
            secondStarted.complete();
            if (!cancel) throw StateError('second block connection failed');
          }
          await gate.future;
          return _BingAdapter.reply(form);
        };
        final folder = await Directory.systemTemp.createTemp(
          'bing-parallel-stop-',
        );
        final store = await StreamingSubtitleStore.create(
          File('${folder.path}/journal.jsonl'),
          {
            'generationId': 'test',
            'primaryPath': '${folder.path}/source.srt',
            'secondaryPath': '${folder.path}/translated.srt',
          },
        );
        var failures = 0;
        final stream = LocalTranscriptionStream(
          openStore: () async => store,
          choice: const TranscriptTranslateChoice(
            enabled: true,
            provider: SubtitleTranslateProvider.bing,
            direction: TranscriptTranslateDirection.toChinese,
            aiOptions: AiSubtitleTranslationSettings.defaults,
          ),
          center: ModelCenterService(),
          translator: SubtitleTranslationService(
            dio: dio,
            bingTranslator: BingSubtitleTranslator(
              dio: dio,
              requestInterval: Duration.zero,
            ),
          ),
          recognitionLanguage: 'en',
          cancelSignal: cancellation.future,
          checkCancelled: () {
            if (cancellation.isCompleted) throw StateError('stopped');
          },
          onCommitted: (_, _, _) async {},
          onActivity: (_, _) {},
          onFailure: () {
            failures++;
          },
        );
        try {
          await stream.accept(
            StableAsrBatch(
              [cue(1, 'first')],
              const Duration(seconds: 30),
              null,
              nativePipeline: true,
            ),
          );
          final accepted = stream
              .accept(
                StableAsrBatch(
                  [cue(2, 'second')],
                  const Duration(seconds: 60),
                  null,
                  nativePipeline: true,
                ),
              )
              .then<void>((_) {}, onError: (Object _) {});
          await secondStarted.future.timeout(const Duration(seconds: 2));
          expect(store.primary.snapshot, isEmpty);
          expect(failures, 0);
          final drained = expectLater(
            stream.drain().timeout(const Duration(seconds: 2)),
            throwsA(isA<DioException>()),
          );
          if (cancel) {
            cancellation.complete();
          } else {
            gate.complete();
          }
          await accepted;
          await drained;
          expect(store.primary.snapshot.map((c) => c.index), cancel ? [] : [1]);
          expect(
            store.secondary.snapshot.map((c) => c.index),
            cancel ? [] : [1],
          );
          expect(failures, 1);
          expect(adapter.active, 0);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await stream.close();
          await store.drained;
          await folder.delete(recursive: true);
        }
      },
    );
  }

  test(
    'local ASR pipeline uses Bing, journals successful rows and resumes missing rows',
    () async {
      var now = DateTime.utc(2026, 10, 21);
      final client = BingSubtitleTranslator(
        dio: dio,
        concurrency: 1,
        batchSize: 1,
        now: () => now,
        requestInterval: Duration.zero,
      );
      final service = SubtitleTranslationService(
        dio: dio,
        bingTranslator: client,
      );
      final folder = await Directory.systemTemp.createTemp('bing-streaming-');
      final store = await StreamingSubtitleStore.create(
        File('${folder.path}/journal.jsonl'),
        {
          'generationId': 'test',
          'primaryPath': '${folder.path}/source.srt',
          'secondaryPath': '${folder.path}/translated.srt',
        },
      );
      adapter.respond = (form, seq) async => seq == 2
          ? _BingAdapter.json({'StatusCode': 429}, status: 429)
          : _BingAdapter.reply(form);
      LocalTranscriptionStream open() => LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          provider: SubtitleTranslateProvider.bing,
          direction: TranscriptTranslateDirection.toChinese,
          aiOptions: AiSubtitleTranslationSettings.defaults,
        ),
        center: ModelCenterService(),
        translator: service,
        recognitionLanguage: 'en',
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, _, _) async {},
        onActivity: (_, _) {},
        onFailure: () {},
      );
      final batch = StableAsrBatch(
        [cue(1, 'first'), cue(2, 'second')],
        const Duration(seconds: 30),
        null,
      );
      var stream = open();
      try {
        await stream.accept(batch);
        await expectLater(
          stream.drain(),
          throwsA(isA<BingTranslationException>()),
        );
        await stream.close();
        expect(store.primary.snapshot, isEmpty);
        expect(store.pendingTranslations, {1: '译 first'});
        final before = adapter.posts;
        now = now.add(const Duration(minutes: 2));
        adapter.respond = (form, _) async => _BingAdapter.reply(form);
        stream = open();
        await stream.accept(batch);
        await stream.drain();
        expect(store.primary.snapshot.map((c) => c.index), [1, 2]);
        expect(store.secondary.snapshot.map((c) => c.text), [
          '译 first',
          '译 second',
        ]);
        expect(adapter.posts - before, 1);
        expect(adapter.sessions, 1);
      } finally {
        await stream.close();
        await store.drained;
        await folder.delete(recursive: true);
      }
    },
  );
}
