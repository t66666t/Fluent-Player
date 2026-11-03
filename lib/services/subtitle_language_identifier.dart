import 'dart:convert';

import 'package:flutter/services.dart';

import 'subtitle_translation_policy.dart';

class SubtitleLanguageGuess {
  const SubtitleLanguageGuess(this.language, this.confident);
  final String language;
  final bool confident;
}

/// Small bundled n-gram profiles; no network or native runtime is required.
/// Profiles derive from wooorm/franc (MIT), with notices beside the asset.
class SubtitleLanguageIdentifier {
  static final shared = SubtitleLanguageIdentifier();
  Future<void>? _loading;
  final _scripts = <String, RegExp>{};
  final _profiles = <String, Map<String, String>>{};
  final _ranks = <String, Map<String, Map<String, int>>>{};
  final _cache = <String, SubtitleLanguageGuess>{};
  static final _letters = RegExp(r'\p{L}', unicode: true);
  static final _kana = RegExp(r'[\u3040-\u30ff]');
  static final _hangul = RegExp(r'[\uac00-\ud7af\u1100-\u11ff]');

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final data =
        jsonDecode(
              await rootBundle.loadString('assets/language_id/profiles.json'),
            )
            as Map;
    for (final entry in (data['scripts'] as Map).entries) {
      _scripts[entry.key as String] = RegExp(entry.value as String);
    }
    for (final entry in (data['profiles'] as Map).entries) {
      _profiles[entry.key as String] = Map<String, String>.from(
        entry.value as Map,
      );
    }
  }

  String? scriptOf(String text) {
    if (_kana.hasMatch(text)) return 'jpn';
    if (_hangul.hasMatch(text)) return 'kor';
    String? best;
    var count = 0;
    for (final entry in _scripts.entries) {
      final found = entry.value.allMatches(text).length;
      if (found > count) {
        best = entry.key;
        count = found;
      }
    }
    return best;
  }

  Iterable<String> possibleLanguages(String text) {
    final script = scriptOf(text);
    // A short all-Han phrase can be either Chinese or Japanese.
    return script == 'cmn'
        ? const ['zh-CN', 'ja']
        : _profiles[script]?.keys ?? const [];
  }

  static const _words = <String, String>{
    'en':
        'hello welcome please thanks thank goodbye everyone everybody good morning evening night today tomorrow yesterday this that these those the and are you your yours my our their have has not don’t dont do does how what where when why who which would could should will can is it we they she he to from with of for on in yes no okay sorry sit down take bags let lets go love learning learn',
    'fr':
        'bonjour salut merci bonsoir bienvenue veuillez français française aujourd’hui demain hier nous vous votre notre sont avec dans pour mais aussi toujours jamais comment pourquoi très êtes ceci cette monde tout',
    'de':
        'hallo guten morgen danke bitte willkommen tschüss deutsch heute morgen gestern wir sie ihr ihre sind ist nicht und der die das ein eine mit für warum wie geht guten',
    'es':
        'hola gracias bienvenido bienvenida buenos buenas español española mañana ayer nosotros ustedes usted vosotros están estoy eres una uno unos unas los las del por para pero qué cómo porque',
    'pt':
        'olá obrigado obrigada bem-vindo português portuguesa amanhã ontem você vocês nós não uma uns umas aos pelas pelo muito também estão tudo',
    'it':
        'ciao grazie buongiorno buonasera italiano italiana domani ieri noi voi sono siamo questo questa quello della degli per favore perché',
    'nl':
        'hallo dank dankje alsjeblieft welkom nederlands vandaag morgen gisteren wij jullie zijn niet het een deze dat voor hoe',
  };
  late final _lexicon = {
    for (final entry in _words.entries)
      entry.key: entry.value.split(' ').toSet(),
  };
  String? phraseHint(String word) {
    final value = word.toLowerCase();
    final languages = _lexicon.entries
        .where((entry) => entry.value.contains(value))
        .map((entry) => entry.key)
        .toList();
    return languages.length == 1 ? languages.single : null;
  }

  SubtitleLanguageGuess identify(String text, {String context = ''}) {
    final value = text.replaceAll(RegExp(r'https?://\S+|www\.\S+'), '').trim();
    final script = scriptOf(value);
    if (script == null || !_letters.hasMatch(value)) {
      return const SubtitleLanguageGuess('auto', false);
    }
    if (script == 'cmn') {
      final bare = value.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
      if (const {'東京', '大阪', '京都', '日本語', '本当', '私', '大丈夫'}.contains(bare) &&
          _kana.hasMatch(context)) {
        return const SubtitleLanguageGuess('ja', true);
      }
      if (const {
            '世界',
            '昨日',
            '明日',
            '今日',
            '学校',
            '先生',
            '学生',
            '時間',
            '感謝',
            '未来',
            '希望',
            '自由',
            '安全',
            '平和',
            '警察',
            '病院',
            '図書館',
            '電車',
            '電話',
            '旅行',
            '仕事',
            '生活',
            '家族',
            '友達',
            '元気',
            '駅',
            '雨',
            '雪',
            '水',
            '火',
            '山',
            '川',
            '空',
            '風',
            '春',
            '夏',
            '秋',
            '冬',
            '車',
          }.contains(bare) &&
          _kana.hasMatch(context)) {
        return const SubtitleLanguageGuess('auto', false);
      }
      return const SubtitleLanguageGuess('zh-CN', true);
    }
    if (script == 'jpn') return const SubtitleLanguageGuess('ja', true);
    if (script == 'kor') return const SubtitleLanguageGuess('ko', true);
    final guess = _cache[value] ?? _classify(value, script);
    if (_cache.length >= 512) _cache.clear();
    _cache[value] = guess;
    if (!guess.confident && context.isNotEmpty && scriptOf(context) == script) {
      final contextual = _classify('$context $value', script);
      // Context resolves a short phrase, but cannot overturn clear evidence.
      if (contextual.confident &&
          (value.runes.length < 15 ||
              subtitleLanguageFamily(contextual.language) ==
                  subtitleLanguageFamily(guess.language))) {
        return contextual;
      }
    }
    return guess;
  }

  SubtitleLanguageGuess _classify(String value, String script) {
    final models = _profiles[script]!;
    if (models.length == 1) {
      return SubtitleLanguageGuess(models.keys.single, true);
    }
    final sample = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{M}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (script == 'Latin') {
      final words = sample.split(' ');
      final scores = <String, double>{};
      for (final entry in _lexicon.entries) {
        scores[entry.key] = words.fold<double>(
          0,
          (n, word) =>
              n +
              (entry.value.contains(word)
                  ? 1 /
                        _lexicon.values
                            .where((set) => set.contains(word))
                            .length
                  : 0),
        );
      }
      final ranked = scores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (ranked.first.value >= 1 &&
          ranked.first.value - ranked[1].value >= .8) {
        return SubtitleLanguageGuess(ranked.first.key, true);
      }
    }
    final padded = ' $sample ';
    final chars = padded.runes.take(1024).toList();
    if (chars.length < 5) return const SubtitleLanguageGuess('auto', false);
    final counts = <String, int>{};
    for (var i = 0; i + 2 < chars.length; i++) {
      final gram = String.fromCharCodes(chars.sublist(i, i + 3));
      counts.update(gram, (n) => n + 1, ifAbsent: () => 1);
    }
    final grams = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount == 0 ? a.compareTo(b) : byCount;
      });
    final ranks = _ranks.putIfAbsent(
      script,
      () => {
        for (final entry in models.entries)
          entry.key: {
            for (final (index, gram) in entry.value.split('|').indexed)
              gram: index,
          },
      },
    );
    final scores = <({String code, int distance, int matched})>[];
    for (final entry in ranks.entries) {
      var distance = 0, matched = 0;
      for (var i = 0; i < grams.length && i < 200; i++) {
        final rank = entry.value[grams[i]];
        distance += rank == null ? 300 : (rank - i).abs();
        if (rank != null) matched++;
      }
      scores.add((code: entry.key, distance: distance, matched: matched));
    }
    scores.sort((a, b) => a.distance.compareTo(b.distance));
    final best = scores.first, count = grams.length.clamp(1, 200);
    final margin = (scores[1].distance - best.distance) / (count * 300);
    return SubtitleLanguageGuess(
      best.code,
      sample.runes.length >= 8 && best.matched / count >= .2 && margin >= .012,
    );
  }
}
