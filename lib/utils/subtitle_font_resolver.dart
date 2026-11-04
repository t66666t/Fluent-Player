import 'package:characters/characters.dart';
import '../models/subtitle_font.dart';
import '../models/subtitle_style.dart';

class SubtitleFontRun {
  final String text;
  final SubtitleFontChoice font;
  const SubtitleFontRun(this.text, this.font);
}

String normalizeSubtitleLanguage(String? value) {
  final tag = (value ?? '').toLowerCase().replaceAll('_', '-');
  return switch (tag) {
    'jpn' => 'ja',
    'zho' || 'chi' => 'zh',
    'eng' => 'en',
    'kor' => 'ko',
    'fra' || 'fre' => 'fr',
    'deu' || 'ger' => 'de',
    'spa' => 'es',
    'rus' => 'ru',
    'ara' => 'ar',
    'und' || 'auto' => '',
    _ => tag,
  };
}

/// Whole script runs preserve graphemes and contextual shaping. Track language
/// disambiguates shared Han/Latin scripts; kana also supplies local Han context.
List<SubtitleFontRun> resolveSubtitleFontRuns(
  String text,
  SubtitleTextStyle style, {
  String? language,
}) {
  final overrides = {
    for (final e in style.resolvedLanguageFonts.entries)
      normalizeSubtitleLanguage(e.key): e.value,
  };
  final hint = normalizeSubtitleLanguage(language);
  final base = hint.split('-').first;
  final kana = RegExp(r'[\u3040-\u30ff\uff66-\uff9f]').hasMatch(text);
  final hangul = RegExp(
    r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]',
  ).hasMatch(text);
  final hanLanguage = base == 'ja' || base == 'ko' || base == 'zh'
      ? base
      : kana
      ? 'ja'
      : hangul
      ? 'ko'
      : 'zh';
  SubtitleFontChoice choose(String script) {
    final matchingHint = switch (script) {
      'han' => ['zh', 'ja', 'ko'].contains(base),
      'latin' => ![
        'zh',
        'ja',
        'ko',
        'ar',
        'fa',
        'ur',
        'ru',
        'uk',
        'th',
        'hi',
        'el',
        'he',
      ].contains(base),
      'ru' => [
        'ru',
        'uk',
        'bg',
        'sr',
        'be',
        'mk',
        'kk',
        'ky',
        'tt',
        'mn',
      ].contains(base),
      'ar' => ['ar', 'fa', 'ur', 'ps', 'ku'].contains(base),
      'hi' => ['hi', 'mr', 'ne', 'sa'].contains(base),
      _ => script == base,
    };
    if (hint.isNotEmpty && matchingHint) {
      if (overrides[hint] != null) return overrides[hint]!;
      if (overrides[base] != null) return overrides[base]!;
      return style.defaultFont;
    }
    final key = switch (script) {
      'han' => hanLanguage,
      'latin' => 'en',
      _ => script,
    };
    return overrides[key] ?? style.defaultFont;
  }

  String? scriptOf(String grapheme) {
    for (final r in grapheme.runes) {
      if ((r >= 0x3400 && r <= 0x9fff) || (r >= 0x20000 && r <= 0x323af)) {
        return 'han';
      }
      if ((r >= 0x3040 && r <= 0x30ff) || (r >= 0xff66 && r <= 0xff9f)) {
        return 'ja';
      }
      if ((r >= 0x1100 && r <= 0x11ff) ||
          (r >= 0xac00 && r <= 0xd7af) ||
          (r >= 0x3130 && r <= 0x318f)) {
        return 'ko';
      }
      if (r >= 0x0400 && r <= 0x052f) return 'ru';
      if ((r >= 0x0600 && r <= 0x06ff) || (r >= 0x0750 && r <= 0x077f)) {
        return 'ar';
      }
      if (r >= 0x0e00 && r <= 0x0e7f) return 'th';
      if (r >= 0x0900 && r <= 0x097f) return 'hi';
      if (r >= 0x0370 && r <= 0x03ff) return 'el';
      if ((r >= 0x41 && r <= 0x5a) ||
          (r >= 0x61 && r <= 0x7a) ||
          (r >= 0x00c0 && r <= 0x024f) ||
          (r >= 0x1e00 && r <= 0x1eff)) {
        return 'latin';
      }
      // Legacy CJK punctuation keeps its previous font in old settings.
      if ((r >= 0x3000 && r <= 0x303f) || (r >= 0xff00 && r <= 0xff65)) {
        return 'han';
      }
    }
    return null;
  }

  final characters = text.characters.toList();
  final scripts = characters.map(scriptOf).toList();
  final runs = <SubtitleFontRun>[];
  SubtitleFontChoice? previous;
  var buffer = StringBuffer();
  for (var i = 0; i < characters.length; i++) {
    var script = scripts[i];
    if (script == null) {
      // Unknown writing systems use the default; spaces and combining marks
      // inherit neighbours to avoid breaking joined text and ligatures.
      final neutral = RegExp(
        r'^[\s\d\p{P}\p{M}]+$',
        unicode: true,
      ).hasMatch(characters[i]);
      if (neutral) {
        script = i > 0 ? scripts[i - 1] : null;
        script ??= scripts.skip(i + 1).whereType<String>().firstOrNull;
      }
    }
    final font = script == null
        ? (overrides[hint] ?? overrides[base] ?? style.defaultFont)
        : choose(script);
    if (previous != null && previous != font) {
      runs.add(SubtitleFontRun(buffer.toString(), previous));
      buffer = StringBuffer();
    }
    buffer.write(characters[i]);
    previous = font;
    if (script != null) scripts[i] = script;
  }
  if (buffer.isNotEmpty) {
    runs.add(SubtitleFontRun(buffer.toString(), previous!));
  }
  return runs;
}
