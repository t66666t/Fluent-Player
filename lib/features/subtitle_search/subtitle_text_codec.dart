import 'dart:convert';

import 'package:enough_convert/enough_convert.dart' hide gbk;
import 'package:fast_gbk/fast_gbk.dart';

import 'subtitle_search_failures.dart';
import 'subtitle_shift_jis_table.dart';

/// Result of decoding subtitle bytes. [uncertain] means more than one legacy
/// encoding still looks plausible, so the caller must not import the text.
class SubtitleTextDecoding {
  const SubtitleTextDecoding({
    required this.text,
    required this.encoding,
    this.uncertain = false,
    this.candidates = const [],
    this.replacements = 0,
  });

  final String text;
  final String encoding;
  final bool uncertain;
  final List<String> candidates;
  final int replacements;
}

/// Subtitle-search codec. ASCII timing markers are not treated as proof: a
/// wrong legacy encoding still preserves `Dialogue:` and `-->`.
class SubtitleTextCodec {
  const SubtitleTextCodec();

  static const encodings = [
    'utf-8',
    'utf-16le',
    'utf-16be',
    'shift_jis',
    'euc-jp',
    'iso-2022-jp',
    'gbk',
    'big5',
  ];

  SubtitleTextDecoding decode(
    List<int> bytes, {
    String? encoding,
    String? fileName,
  }) {
    if (bytes.isEmpty) {
      throw const SubtitleFailure(
        stage: SubtitleFailureStage.decode,
        kind: SubtitleFailureKind.empty,
        message: '字幕内容是空的',
      );
    }
    if (encoding != null && encoding.isNotEmpty) {
      final forced = _decodeNamed(bytes, encoding);
      if (forced.replacements > _replacementBudget(forced.text)) {
        throw SubtitleFailure(
          stage: SubtitleFailureStage.decode,
          kind: SubtitleFailureKind.encodingUncertain,
          message: '用 $encoding 解码后仍有大量无法识别的字符',
          recovery: SubtitleRecovery.switchEncoding,
          detail: encoding,
        );
      }
      return forced;
    }
    final bom = _fromBom(bytes);
    if (bom != null) return bom;
    final utf8Text = _tryUtf8(bytes);
    if (utf8Text != null) {
      return SubtitleTextDecoding(text: utf8Text, encoding: 'utf-8');
    }
    final hint = _hint(fileName);
    final attempts = <SubtitleTextDecoding>[
      for (final name in encodings.skip(3))
        if (_decodeNamed(bytes, name) case final decoded)
          if (_plausible(decoded)) decoded,
    ];
    attempts.sort((a, b) {
      final hintScore =
          (b.encoding == hint ? 1 : 0) - (a.encoding == hint ? 1 : 0);
      if (hintScore != 0) return hintScore;
      return a.replacements.compareTo(b.replacements);
    });
    if (attempts.isEmpty) {
      throw const SubtitleFailure(
        stage: SubtitleFailureStage.decode,
        kind: SubtitleFailureKind.encodingUncertain,
        message: '无法确定字幕编码，可手动选择编码后重试，不必重新下载',
        recovery: SubtitleRecovery.switchEncoding,
      );
    }
    if (attempts.length > 1 &&
        attempts[0].text != attempts[1].text &&
        attempts[0].encoding != hint) {
      return SubtitleTextDecoding(
        text: attempts.first.text,
        encoding: attempts.first.encoding,
        uncertain: true,
        candidates: attempts.map((e) => e.encoding).toList(),
        replacements: attempts.first.replacements,
      );
    }
    return attempts.first;
  }

  SubtitleTextDecoding? _fromBom(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return SubtitleTextDecoding(
        text: utf8.decode(bytes.sublist(3)),
        encoding: 'utf-8',
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return SubtitleTextDecoding(
        text: _utf16(bytes.sublist(2), little: true),
        encoding: 'utf-16le',
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return SubtitleTextDecoding(
        text: _utf16(bytes.sublist(2), little: false),
        encoding: 'utf-16be',
      );
    }
    return null;
  }

  String? _tryUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  SubtitleTextDecoding _decodeNamed(List<int> bytes, String encoding) {
    switch (encoding) {
      case 'utf-8':
        final text = _tryUtf8(bytes);
        if (text == null) {
          throw const SubtitleFailure(
            stage: SubtitleFailureStage.decode,
            kind: SubtitleFailureKind.encodingUncertain,
            message: '这段内容不是严格的 UTF-8',
            recovery: SubtitleRecovery.switchEncoding,
          );
        }
        return SubtitleTextDecoding(text: text, encoding: encoding);
      case 'utf-16le':
        return SubtitleTextDecoding(
          text: _utf16(bytes, little: true),
          encoding: encoding,
        );
      case 'utf-16be':
        return SubtitleTextDecoding(
          text: _utf16(bytes, little: false),
          encoding: encoding,
        );
      case 'shift_jis':
        return _count('shift_jis', decodeCp932(bytes));
      case 'euc-jp':
        return _count('euc-jp', decodeCp932(eucJpToCp932(bytes)));
      case 'iso-2022-jp':
        return _count('iso-2022-jp', decodeCp932(iso2022JpToCp932(bytes)));
      case 'gbk':
        try {
          return _count('gbk', _marked(gbk.decode(bytes)));
        } on FormatException {
          return const SubtitleTextDecoding(
            text: '',
            encoding: 'gbk',
            replacements: 1 << 20,
          );
        }
      case 'big5':
        try {
          return _count(
            'big5',
            _marked(const Big5Codec(allowInvalid: false).decode(bytes)),
          );
        } on FormatException {
          return const SubtitleTextDecoding(
            text: '',
            encoding: 'big5',
            replacements: 1 << 20,
          );
        }
      default:
        throw SubtitleFailure(
          stage: SubtitleFailureStage.decode,
          kind: SubtitleFailureKind.encodingUncertain,
          message: '不支持编码 $encoding',
          recovery: SubtitleRecovery.switchEncoding,
        );
    }
  }

  ({String text, int replacements}) _marked(String text) => (
    text: text,
    replacements: '\uFFFD'.allMatches(text).length,
  );

  SubtitleTextDecoding _count(String encoding, ({String text, int replacements}) value) {
    return SubtitleTextDecoding(
      text: value.text,
      encoding: encoding,
      replacements: value.replacements,
    );
  }

  bool _plausible(SubtitleTextDecoding decoded) {
    if (decoded.text.isEmpty ||
        decoded.replacements > _replacementBudget(decoded.text)) {
      return false;
    }
    return RegExp(
      r'Dialogue:|WEBVTT|-->',
    ).hasMatch(decoded.text);
  }

  int _replacementBudget(String text) => text.length < 200 ? 2 : text.length ~/ 80;

  String? _hint(String? fileName) {
    final lower = (fileName ?? '').toLowerCase();
    if (lower.contains('shift') || lower.contains('cp932') || lower.contains('sjis')) {
      return 'shift_jis';
    }
    if (lower.contains('euc')) return 'euc-jp';
    if (lower.contains('iso-2022') || lower.contains('iso2022')) return 'iso-2022-jp';
    if (lower.contains('big5') || lower.contains('.cht')) return 'big5';
    if (lower.contains('gbk') || lower.contains('.chs') || lower.contains('.gb')) {
      return 'gbk';
    }
    return null;
  }

  String _utf16(List<int> bytes, {required bool little}) {
    final data = bytes.length.isOdd ? bytes.sublist(0, bytes.length - 1) : bytes;
    final units = <int>[];
    for (var i = 0; i + 1 < data.length; i += 2) {
      units.add(little ? data[i] | (data[i + 1] << 8) : data[i + 1] | (data[i] << 8));
    }
    return String.fromCharCodes(units);
  }
}

/// CP932 / Shift_JIS. Half-width katakana is the single-byte range A1–DF.
({String text, int replacements}) decodeCp932(List<int> bytes) {
  final out = StringBuffer();
  var replacements = 0;
  for (var i = 0; i < bytes.length; i++) {
    final lead = bytes[i];
    if (lead < 0x80) {
      out.writeCharCode(lead);
      continue;
    }
    if (lead >= 0xA1 && lead <= 0xDF) {
      out.writeCharCode(0xFF61 + lead - 0xA1);
      continue;
    }
    final page = shiftJisDoubleByte[lead];
    if (page == null || i + 1 >= bytes.length) {
      replacements++;
      out.write('\uFFFD');
      continue;
    }
    final trail = bytes[++i];
    final index = trail < 0x40 || trail > 0xFC || trail == 0x7F
        ? -1
        : (trail < 0x7F ? trail - 0x40 : trail - 0x41);
    final code = index < 0 || index >= page.length ? 0xFFFD : page.codeUnitAt(index);
    if (code == 0xFFFD) replacements++;
    out.writeCharCode(code);
  }
  return (text: out.toString(), replacements: replacements);
}

/// EUC-JP bytes rewritten as CP932 so one table serves both encodings.
List<int> eucJpToCp932(List<int> bytes) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    final lead = bytes[i];
    if (lead < 0x80) {
      out.add(lead);
      continue;
    }
    if (lead == 0x8E && i + 1 < bytes.length) {
      out.add(bytes[++i]);
      continue;
    }
    if (lead == 0x8F) {
      i += 2;
      out.add(0x3F);
      continue;
    }
    if (i + 1 >= bytes.length) break;
    final pair = jisToCp932(lead & 0x7F, bytes[++i] & 0x7F);
    if (pair == null) {
      out.add(0x3F);
    } else {
      out..add(pair.$1)..add(pair.$2);
    }
  }
  return out;
}

List<int> iso2022JpToCp932(List<int> bytes) {
  final out = <int>[];
  var mode = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x1B && i + 2 < bytes.length) {
      final a = bytes[i + 1];
      final b = bytes[i + 2];
      if (a == 0x28 && (b == 0x42 || b == 0x4A)) {
        mode = 0;
        i += 2;
        continue;
      }
      if (a == 0x28 && b == 0x49) {
        mode = 2;
        i += 2;
        continue;
      }
      if (a == 0x24 && (b == 0x42 || b == 0x40)) {
        mode = 1;
        i += 2;
        continue;
      }
    }
    final value = bytes[i];
    if (mode == 0 || value < 0x21) {
      out.add(value);
      continue;
    }
    if (mode == 2) {
      out.add(value >= 0x21 && value <= 0x5F ? value + 0x80 : 0x3F);
      continue;
    }
    if (i + 1 >= bytes.length) break;
    final pair = jisToCp932(value, bytes[++i]);
    if (pair == null) {
      out.add(0x3F);
    } else {
      out..add(pair.$1)..add(pair.$2);
    }
  }
  return out;
}

(int, int)? jisToCp932(int row, int cell) {
  if (row < 0x21 || row > 0x7E || cell < 0x21 || cell > 0x7E) return null;
  final lead = ((row + 1) >> 1) + (row < 0x5E ? 0x70 : 0xB0);
  var trail = row.isOdd ? cell + 0x1F : cell + 0x7E;
  if (row.isOdd && cell >= 0x60) trail++;
  return (lead, trail);
}
