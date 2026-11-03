import '../models/subtitle_model.dart';
import 'subtitle_language_identifier.dart';
import 'subtitle_translation_languages.dart';
import 'subtitle_translation_policy.dart';

typedef SmartTranslationBatch =
    Future<List<String>> Function(
      List<SubtitleItem> items,
      String source,
      String target,
      String scope,
      void Function(double) onProgress,
      void Function(int, String) onTranslated,
    );

class _Piece {
  _Piece(this.cue, this.text, {this.literal = false, this.detectionText});
  final int cue;
  final String text;
  final bool literal;
  final String? detectionText;
  String? language, target, output;
}

/// Provider-independent routing. Only complete cues are published, so a retry
/// can reuse completed cues without committing half of a mixed-language cue.
class SmartSubtitleTranslator {
  SmartSubtitleTranslator({SubtitleLanguageIdentifier? identifier})
    : identifier = identifier ?? SubtitleLanguageIdentifier.shared;
  final SubtitleLanguageIdentifier identifier;
  static final _protected = RegExp(
    r'<[^>]+>|\{\\[^}]+\}|\{\{[^}]+\}\}|%[sd]|https?://[^\s<>]+|www\.[^\s<>]+',
    caseSensitive: false,
  );
  static final _sentences = RegExp(
    r'[^\r\n.!?。！？;；]+[.!?。！？;；]*|[\r\n]+|[.!?。！？;；]+',
  );
  static final _letter = RegExp(r'[\p{L}\p{M}]', unicode: true);

  Future<List<String>> translate({
    required List<SubtitleItem> items,
    required SmartTranslationPolicy policy,
    required SmartTranslationBatch translateBatch,
    required void Function(double) onProgress,
    void Function(int, String)? onTranslated,
    void Function(String?)? onActivity,
    void Function()? checkCancelled,
    Future<void>? cancelSignal,
    String precedingContext = '',
    List<SubtitleTranslationLanguage>? supportedSourceLanguages,
  }) async {
    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    void check() {
      if (cancelled) throw StateError('智能互译已停止');
      checkCancelled?.call();
    }

    check();
    await identifier.load();
    check();
    final plans = <List<_Piece>>[];
    final groups = <String, List<_Piece>>{};
    var uncertain = 0;
    final unsupported = <String, int>{};
    final supported = supportedSourceLanguages
        ?.map((l) => subtitleLanguageFamily(l.code))
        .toSet();
    for (var i = 0; i < items.length; i++) {
      check();
      final context = [
        if (i == 0) precedingContext,
        if (i > 0) items[i - 1].text,
        items[i].text,
        if (i + 1 < items.length) items[i + 1].text,
      ].join('\n');
      final pieces = _pieces(i, items[i].text);
      plans.add(pieces);
      for (final piece in pieces) {
        if (piece.literal || !_letter.hasMatch(piece.text)) {
          piece.output = piece.text;
          continue;
        }
        final detectionText = piece.detectionText ?? piece.text;
        final guess = identifier.identify(detectionText, context: context);
        piece.language = guess.confident ? guess.language : 'auto';
        final possibleTargets = guess.confident
            ? <String>{}
            : identifier
                  .possibleLanguages(detectionText)
                  .map(policy.targetFor)
                  .toSet();
        final directionKnown = possibleTargets.length == 1;
        if (!guess.confident && !directionKnown && policy.keepUncertain) {
          piece.output = piece.text;
          uncertain++;
          continue;
        }
        final target = !guess.confident && directionKnown
            ? possibleTargets.single
            : policy.targetFor(piece.language!);
        if (target == keepOriginal ||
            (target == piece.language && !target.startsWith('zh-'))) {
          piece.output = piece.text;
          continue;
        }
        if (guess.confident &&
            supported != null &&
            !supported.contains(subtitleLanguageFamily(guess.language))) {
          // Short ASR fragments can fool text language identification. Keep
          // their exact text instead of failing every later cue or silently
          // forcing a possibly unrelated supported source language.
          piece.output = piece.text;
          unsupported.update(guess.language, (n) => n + 1, ifAbsent: () => 1);
          continue;
        }
        piece.target = target;
      }
      final routed = pieces.where((piece) => piece.target != null).toList();
      final targets = routed.map((piece) => piece.target!).toSet();
      // Plain ASR cues often contain several sentences. Keep a single row
      // when their direction agrees, avoiding repeated JSON IDs and prompts.
      // Protected tokens and intentionally preserved fragments stay separate.
      if (routed.length > 1 &&
          targets.length == 1 &&
          pieces.every(
            (piece) =>
                piece.target != null ||
                piece.literal && piece.text.trim().isEmpty,
          )) {
        final sources = routed.map((piece) => piece.language!).toSet();
        final combined = _Piece(i, pieces.map((piece) => piece.text).join())
          ..target = targets.single
          ..language = sources.length == 1 ? sources.single : 'auto';
        plans[i] = [combined];
        groups.putIfAbsent(combined.target!, () => []).add(combined);
      } else {
        for (final piece in routed) {
          groups.putIfAbsent(piece.target!, () => []).add(piece);
        }
      }
    }
    final published = <int>{};
    void publishReady(int index) {
      if (published.contains(index) ||
          plans[index].any((piece) => piece.output == null)) {
        return;
      }
      check();
      published.add(index);
      onTranslated?.call(
        index,
        plans[index].map((piece) => piece.output!).join(),
      );
    }

    for (var i = 0; i < items.length; i++) {
      publishReady(i);
    }
    final total = groups.values.fold<int>(0, (n, group) => n + group.length);
    var completed = 0;
    onProgress(total == 0 ? 1 : 0);
    for (final entry in groups.entries) {
      check();
      final target = entry.key, group = entry.value;
      final sources = group.map((piece) => piece.language!).toSet();
      final source = sources.length == 1 && !sources.single.startsWith('zh-')
          ? sources.single
          : 'auto';
      final targetLabel = subtitleLanguageLabel(target);
      onActivity?.call('智能互译 · 正在译为$targetLabel');
      void accept(int index, String text) {
        check();
        if (index < 0 || index >= group.length || text.trim().isEmpty) return;
        group[index].output = text;
        publishReady(group[index].cue);
      }

      final scope = '${policy.fingerprint}:$target';
      final output = await translateBatch(
        [
          for (final (index, piece) in group.indexed)
            items[piece.cue].copyWith(index: index + 1, text: piece.text),
        ],
        source,
        target,
        scope,
        (value) {
          check();
          onProgress((completed + value.clamp(0, 1) * group.length) / total);
        },
        accept,
      );
      check();
      if (output.length != group.length) throw StateError('智能互译返回的片段数量不匹配');
      for (var i = 0; i < output.length; i++) {
        if (output[i].trim().isEmpty) throw StateError('智能互译有片段未完成');
        accept(i, output[i]);
      }
      completed += group.length;
    }
    check();
    final notes = <String>[
      if (uncertain > 0) '$uncertain 个短片段语言不确定，已按设置保留原文',
      if (unsupported.isNotEmpty)
        '${unsupported.values.fold<int>(0, (n, count) => n + count)} 个片段检测为'
            '${unsupported.keys.map(subtitleLanguageLabel).join('、')}，'
            '当前模型不支持，已保留原文，其余字幕正常翻译',
    ];
    onProgress(1);
    if (notes.isNotEmpty) {
      onActivity?.call('智能互译完成 · ${notes.join('；')}');
    }
    return [
      for (final plan in plans) plan.map((piece) => piece.output!).join(),
    ];
  }

  List<_Piece> _pieces(int cue, String text) {
    final result = <_Piece>[];
    void plain(String value) {
      for (final match in _sentences.allMatches(value)) {
        final sentence = match[0]!;
        final leading = RegExp(r'^\s*').stringMatch(sentence)!;
        final trailing = RegExp(r'\s*$').stringMatch(sentence)!;
        if (sentence.trim().isEmpty) {
          result.add(_Piece(cue, sentence, literal: true));
          continue;
        }
        if (leading.isNotEmpty) result.add(_Piece(cue, leading, literal: true));
        result.addAll(_scriptPieces(cue, sentence.trim()));
        if (trailing.isNotEmpty) {
          result.add(_Piece(cue, trailing, literal: true));
        }
      }
    }

    var at = 0;
    for (final match in _protected.allMatches(text)) {
      plain(text.substring(at, match.start));
      result.add(_Piece(cue, match[0]!, literal: true));
      at = match.end;
    }
    plain(text.substring(at));
    return result;
  }

  List<_Piece> _scriptPieces(int cue, String text) {
    final runs = <({int start, String script})>[];
    final japanese = RegExp(r'[\u3040-\u30ff]').hasMatch(text);
    var offset = 0;
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (_letter.hasMatch(char)) {
        var script = (rune >= 0x3400 && rune <= 0x9fff)
            ? 'cmn'
            : (rune >= 0x3040 && rune <= 0x30ff)
            ? 'jpn'
            : (rune >= 0xac00 && rune <= 0xd7af)
            ? 'kor'
            : (rune <= 0x024f)
            ? 'Latin'
            : identifier.scriptOf(char) ?? 'unknown';
        if (japanese && script == 'cmn') script = 'jpn';
        if (runs.isEmpty || runs.last.script != script) {
          runs.add((start: offset, script: script));
        }
      }
      offset += char.length;
    }
    if (runs.length <= 1) {
      return runs.isNotEmpty && runs.single.script == 'Latin'
          ? _latinPieces(cue, text)
          : [_Piece(cue, text)];
    }
    final hasCjk = runs.any(
      (run) => ['cmn', 'jpn', 'kor'].contains(run.script),
    );
    final latin = <String>[
      for (var i = 0; i < runs.length; i++)
        if (runs[i].script == 'Latin')
          text
              .substring(
                runs[i].start,
                i + 1 < runs.length ? runs[i + 1].start : text.length,
              )
              .trim(),
    ];
    // Embedded brands, acronyms and names belong to their surrounding clause.
    // A real phrase (or a recognized greeting) still becomes its own segment.
    if (hasCjk &&
        runs.every(
          (run) => ['cmn', 'jpn', 'kor', 'Latin'].contains(run.script),
        ) &&
        latin.isNotEmpty &&
        latin.every(
          (word) =>
              !RegExp(r'\s').hasMatch(word) &&
              (RegExp(r'[a-z][A-Z]|^[A-Z]{2,}').hasMatch(word) ||
                  !identifier.identify(word).confident),
        )) {
      return [
        _Piece(
          cue,
          text,
          detectionText: text.replaceAll(
            RegExp(r'[A-Za-z][A-Za-z0-9_.-]*'),
            ' ',
          ),
        ),
      ];
    }
    return [
      if (runs.first.start > 0)
        _Piece(cue, text.substring(0, runs.first.start), literal: true),
      for (var i = 0; i < runs.length; i++)
        ...(runs[i].script == 'Latin' ? _latinPieces : _trimmedPiece)(
          cue,
          text.substring(
            runs[i].start,
            i + 1 < runs.length ? runs[i + 1].start : text.length,
          ),
        ),
    ];
  }

  List<_Piece> _latinPieces(int cue, String text) {
    final blocks = <({int start, String language, int anchors})>[];
    for (final word in RegExp(r'\p{L}+', unicode: true).allMatches(text)) {
      final language = identifier.phraseHint(word[0]!);
      if (language == null) continue;
      if (blocks.isEmpty || blocks.last.language != language) {
        blocks.add((start: word.start, language: language, anchors: 1));
      } else {
        final last = blocks.removeLast();
        blocks.add((
          start: last.start,
          language: language,
          anchors: last.anchors + 1,
        ));
      }
    }
    // Shared-script boundaries need several independent words of evidence.
    // An isolated foreign loanword must not fragment an otherwise normal clause.
    if (blocks.length < 2 || blocks.any((block) => block.anchors < 2)) {
      return _trimmedPiece(cue, text);
    }
    return [
      for (var i = 0; i < blocks.length; i++)
        ..._trimmedPiece(
          cue,
          text.substring(
            i == 0 ? 0 : blocks[i].start,
            i + 1 < blocks.length ? blocks[i + 1].start : text.length,
          ),
        ),
    ];
  }

  List<_Piece> _trimmedPiece(int cue, String text) {
    final lead = RegExp(r'^\s*').stringMatch(text)!;
    final tail = RegExp(r'\s*$').stringMatch(text)!;
    if (text.trim().isEmpty) return [_Piece(cue, text, literal: true)];
    return [
      if (lead.isNotEmpty) _Piece(cue, lead, literal: true),
      _Piece(cue, text.trim()),
      if (tail.isNotEmpty) _Piece(cue, tail, literal: true),
    ];
  }
}
