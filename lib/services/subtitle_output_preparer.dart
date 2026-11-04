import 'dart:async';
import 'dart:isolate';

import '../models/subtitle_model.dart';
import '../models/subtitle_punctuation.dart';
import '../utils/subtitle_parser.dart';
import 'subtitle_word_timing_store.dart';

class PreparedTranscriptOutput {
  const PreparedTranscriptOutput(
    this.srt,
    this.translationInput,
    this.wordTiming,
  );
  final String srt;
  final String? translationInput, wordTiming;
}

/// Batches used by the local stream stay synchronous. Whole online results,
/// SRT encoding and companion hashing share one worker turn. Workers perform
/// no writes or callbacks; owners check cancellation before publishing results.
class SubtitleOutputPreparer {
  const SubtitleOutputPreparer();

  Future<PreparedTranscriptOutput> transcript(
    List<SubtitleItem> cues,
    SubtitlePunctuation punctuation, {
    bool keepTranslationInput = false,
  }) => _large(cues)
      ? _transcriptInWorker(cues, punctuation, keepTranslationInput)
      : Future.value(_transcript(cues, punctuation, keepTranslationInput));

  Future<String> translation(
    List<SubtitleItem> cues,
    List<String> translations,
    SubtitlePunctuation punctuation, {
    String lineEnding = '\n',
  }) {
    if (cues.length != translations.length) throw StateError('译文数量不匹配');
    return _large(cues, translations)
        ? _translationInWorker(cues, translations, punctuation, lineEnding)
        : Future.value(
            _translation(cues, translations, punctuation, lineEnding),
          );
  }

  Future<List<SubtitleItem>> parse(String content) => content.length >= 4096
      ? _parseInWorker(content)
      : Future.value(SubtitleParser.parse(content));

  /// Playback parsing removes presentation tags. Translation keeps the
  /// supported inline tags literal until the routing layer reassembles them.
  Future<List<SubtitleItem>> parseTranslation(String content) => parse(
    content.replaceAllMapped(
      RegExp(r'</?(?:i|b|u|font)(?:\s[^>]*)?>', caseSensitive: false),
      (match) => match[0]!.replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
    ),
  );
}

bool _large(List<SubtitleItem> cues, [List<String>? text]) {
  if (cues.length >= 32) return true;
  var characters = 0, spans = 0;
  for (var i = 0; i < cues.length; i++) {
    characters += text == null ? cues[i].text.length : text[i].length;
    if (text == null) {
      spans += cues[i].timedSpans.length;
      final info = cues[i].asrInfo;
      characters +=
          info.language.length +
          info.speaker.length +
          info.reviewReason.length +
          info.alternateText.length +
          info.backend.length +
          info.weights.length;
      if (characters >= 4096 || info.notes.length >= 64) return true;
      for (final note in info.notes) {
        characters += note.length;
        if (characters >= 4096) return true;
      }
      characters +=
          cues[i].lyricTranslation.length + cues[i].lyricRomanization.length;
      spans +=
          cues[i].lyricTranslationSpans.length +
          cues[i].lyricRomanizationSpans.length;
    }
    if (characters >= 4096 || spans >= 128) return true;
  }
  return false;
}

// Rich cue graphs are copied in small acknowledged batches. Spawning a closure
// over the entire list can itself monopolize the caller before work starts.
Future<PreparedTranscriptOutput> _transcriptInWorker(
  List<SubtitleItem> cues,
  SubtitlePunctuation punctuation,
  bool keepInput,
) => _inWorker<PreparedTranscriptOutput>(
  cues,
  null,
  punctuation,
  keepInput,
  '\n',
);
Future<String> _translationInWorker(
  List<SubtitleItem> cues,
  List<String> translations,
  SubtitlePunctuation punctuation,
  String eol,
) => _inWorker<String>(cues, translations, punctuation, false, eol);
Future<List<SubtitleItem>> _parseInWorker(String content) =>
    Isolate.run(() => SubtitleParser.parse(content));

PreparedTranscriptOutput _transcript(
  List<SubtitleItem> cues,
  SubtitlePunctuation punctuation,
  bool keepInput,
) => (_TranscriptBuilder(punctuation, keepInput)..add(cues)).finish();

class _TranscriptBuilder {
  _TranscriptBuilder(this.punctuation, bool keepInput)
    : raw = keepInput ? StringBuffer() : null;
  final SubtitlePunctuation punctuation;
  final out = StringBuffer();
  final StringBuffer? raw;
  final metadata = <SubtitleItem>[];
  int count = 0;
  void add(List<SubtitleItem> cues) {
    for (final cue in cues) {
      count++;
      final result = applySubtitlePunctuation(cue, punctuation);
      final header = _header(count, cue, '\n');
      out
        ..write(header)
        ..write(result.text)
        ..write('\n\n');
      final rawBuffer = raw;
      if (rawBuffer != null) {
        rawBuffer
          ..write(header)
          ..write(cue.text)
          ..write('\n\n');
      }
      if (result.timedSpans.isNotEmpty ||
          result.isStructuredLyric ||
          result.asrInfo.hasData) {
        metadata.add(
          result.index == count ? result : result.copyWith(index: count),
        );
      }
    }
  }

  PreparedTranscriptOutput finish() {
    final srt = out.toString();
    return PreparedTranscriptOutput(
      srt,
      raw?.toString(),
      metadata.isEmpty ? null : SubtitleWordTimingStore.encode(srt, metadata),
    );
  }
}

String _translation(
  List<SubtitleItem> cues,
  List<String> translations,
  SubtitlePunctuation punctuation,
  String eol,
) => (_TranslationBuilder(punctuation, eol)..add(cues, translations)).finish();

class _TranslationBuilder {
  _TranslationBuilder(this.punctuation, this.eol);
  final SubtitlePunctuation punctuation;
  final String eol;
  final out = StringBuffer();
  int count = 0;
  void add(List<SubtitleItem> cues, List<String> translations) {
    for (var i = 0; i < cues.length; i++) {
      final text = applySubtitlePunctuationText(
        translations[i],
        punctuation,
      ).trim();
      out
        ..write(_header(++count, cues[i], eol))
        ..write(text)
        ..write('$eol$eol');
    }
  }

  String finish() => out.toString();
}

typedef _OutputBatch = (List<SubtitleItem>, List<String>?);
typedef _OutputRequest = (SendPort, SubtitlePunctuation, bool, bool, String);

void _outputWorker(_OutputRequest request) {
  final (reply, punctuation, translation, keepInput, eol) = request;
  final input = ReceivePort();
  final original = translation
      ? null
      : _TranscriptBuilder(punctuation, keepInput);
  final translated = translation ? _TranslationBuilder(punctuation, eol) : null;
  input.listen((message) {
    if (message == null) {
      final result = original?.finish() ?? translated!.finish();
      Isolate.exit(reply, [result]);
    }
    final batch = message as _OutputBatch;
    if (original != null) {
      original.add(batch.$1);
    } else {
      translated!.add(batch.$1, batch.$2!);
    }
    reply.send(0);
  });
  reply.send(input.sendPort);
}

Future<T> _inWorker<T>(
  List<SubtitleItem> cues,
  List<String>? text,
  SubtitlePunctuation punctuation,
  bool keepInput,
  String eol,
) async {
  final receiver = ReceivePort();
  final ready = Completer<SendPort>(), result = Completer<T>();
  Completer<void>? acknowledged;
  Isolate? worker;
  // Both futures may receive the same native worker failure; handle the one
  // not currently awaited as well, without hiding the error from the caller.
  ready.future.ignore();
  result.future.ignore();
  void failed(Object error) {
    if (!ready.isCompleted) ready.completeError(error);
    if (!result.isCompleted) result.completeError(error);
    if (acknowledged?.isCompleted == false) acknowledged!.completeError(error);
  }

  receiver.listen((message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message is int) {
      acknowledged!.complete();
    } else if (message is List && message.length == 1) {
      result.complete(message.single as T);
    } else if (message is List && message.length == 2) {
      failed(RemoteError('${message[0]}', '${message[1]}'));
    } else if (!result.isCompleted) {
      failed(StateError('字幕输出工作线程提前退出'));
    }
  });
  try {
    worker = await Isolate.spawn(
      _outputWorker,
      (receiver.sendPort, punctuation, text != null, keepInput, eol),
      onError: receiver.sendPort,
      onExit: receiver.sendPort,
    );
    final port = await ready.future;
    for (var from = 0; from < cues.length; from += 128) {
      final end = (from + 128).clamp(0, cues.length);
      acknowledged = Completer<void>();
      acknowledged.future.ignore();
      port.send((cues.sublist(from, end), text?.sublist(from, end)));
      await acknowledged.future;
    }
    port.send(null);
    return await result.future;
  } finally {
    receiver.close();
    worker?.kill(priority: Isolate.immediate);
  }
}

String _header(int index, SubtitleItem cue, String eol) =>
    '$index$eol${_time(cue.startTime)} --> ${_time(cue.endTime)}$eol';

String _time(Duration duration) =>
    '${duration.inHours.toString().padLeft(2, '0')}:'
    '${(duration.inMinutes % 60).toString().padLeft(2, '0')}:'
    '${(duration.inSeconds % 60).toString().padLeft(2, '0')},'
    '${(duration.inMilliseconds % 1000).toString().padLeft(3, '0')}';
