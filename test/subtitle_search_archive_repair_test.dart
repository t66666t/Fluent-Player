import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_archive_service.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_batch_matcher.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_release_info.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_failures.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_text_codec.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_unrar.dart';

import 'subtitle_search_service_test.dart' show cueText;

void main() {
  test('internal playback ids are not offered as search words', () {
    expect(subtitleVisibleLabel('podcast:pe_abc123'), isEmpty);
    expect(subtitleVisibleLabel('葬送的芙莉莲'), '葬送的芙莉莲');
  });

  test('Part 2 is a cour, not a season or an episode', () {
    final info = SubtitleReleaseInfo.parse('Show Part 2.mkv');
    expect(info.part, 2);
    expect(info.season, isNull);
    expect(info.episode, isNull);
    final withEpisode = SubtitleReleaseInfo.parse('Show Part 2 - 03.mkv');
    expect(withEpisode.part, 2);
    expect(withEpisode.episode, 3);
    expect(withEpisode.season, isNull);
  });

  test(
    'CP932 and EUC-JP decode hiragana without treating ASCII markers as proof',
    () {
      final codec = const SubtitleTextCodec();
      final sjis = codec.decode([0x82, 0xA0], encoding: 'shift_jis');
      expect(sjis.text, 'あ');
      final euc = codec.decode([0xA4, 0xA2], encoding: 'euc-jp');
      expect(euc.text, 'あ');
      expect(
        () => codec.decode(
          utf8.encode('Dialogue: only ascii\n'),
          encoding: 'shift_jis',
        ),
        returnsNormally,
      );
    },
  );

  test('HTML, 7z and a stored RAR5 are not described as a fake zip', () {
    final html = const SubtitlePackageDecoder().decode(
      Uint8List.fromList(utf8.encode('<html>blocked</html>')),
      name: 'file.srt',
    );
    expect(html.failure?.kind, SubtitleFailureKind.htmlOrJson);
    expect(html.manifest.container, ArchiveContainerKind.html);

    final seven = Uint8List.fromList([
      0x37,
      0x7a,
      0xbc,
      0xaf,
      0x27,
      0x1c,
      0,
      0,
    ]);
    final sevenZip = const SubtitlePackageDecoder().decode(
      seven,
      name: 'pack.zip',
    );
    expect(sevenZip.failure?.kind, SubtitleFailureKind.unsupported);
    expect(sevenZip.failure?.message, contains('7z'));

    final rar = _storeRar5('01.srt', utf8.encode(cueText));
    expect(identifyContainer(rar), ArchiveContainerKind.rar5);
    final decoded = const SubtitlePackageDecoder().decode(
      rar,
      name: 'pack.zip',
    );
    expect(decoded.failure, isNull, reason: decoded.failure?.message);
    expect(decoded.documents.single.cues.single.text, 'こんにちは。');
    expect(decoded.manifest.container, ArchiveContainerKind.rar5);
    expect(decoded.manifest.backend, isNot(contains('zip')));
  });

  test('two editions are not auto-selected just because one scores higher', () {
    final rows = const SubtitleBatchMatcher().match(
      anchorTitle: 'Show - 01.mkv',
      targets: const [
        SubtitleBatchTarget(id: '1', title: 'Show - 01', path: '01.mkv'),
      ],
      candidates: [
        _candidate('简日/Show - 01.jpsc.ass'),
        _candidate('繁日/Show - 01.jptc.ass'),
      ],
    );
    expect(rows.single.confident, isFalse);
    expect(rows.single.reason, contains('多个版本'));
  });

  test(
    'bundled UnRAR tool is available when the in-process DLL cannot start',
    () {
      expect(
        SubtitleUnrar.tryLoad() != null || SubtitleUnrar.locateTool() != null,
        isTrue,
      );
    },
  );
}

SubtitleBatchCandidate _candidate(String name) => SubtitleBatchCandidate(
  hit: const SubtitleSearchHit(
    source: SubtitleSearchSource.subhd,
    id: 'pack',
    title: 'Show',
    catalogId: '1',
    catalogEvidence: SubtitleCatalogEvidence.linked,
  ),
  file: SubtitleSearchFile(id: name, name: name),
);

Uint8List _storeRar5(String name, List<int> data) {
  List<int> vint(int value) {
    final out = <int>[];
    var rest = value;
    while (true) {
      var bite = rest & 0x7f;
      rest >>= 7;
      if (rest != 0) bite |= 0x80;
      out.add(bite);
      if (rest == 0) break;
    }
    return out;
  }

  int crc32(List<int> input) {
    var crc = 0xffffffff;
    for (final bite in input) {
      crc ^= bite;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  List<int> u32(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  List<int> block(List<int> fromType) {
    final covered = [...vint(fromType.length), ...fromType];
    return [...u32(crc32(covered)), ...covered];
  }

  final encodedName = utf8.encode(name);
  final file = block([
    ...vint(2),
    ...vint(0x0002),
    ...vint(data.length),
    ...vint(0x0004),
    ...vint(data.length),
    ...vint(0),
    ...u32(crc32(data)),
    ...vint(0),
    ...vint(0),
    ...vint(encodedName.length),
    ...encodedName,
  ]);
  return Uint8List.fromList([
    0x52,
    0x61,
    0x72,
    0x21,
    0x1a,
    0x07,
    0x01,
    0x00,
    ...block([...vint(1), ...vint(0), ...vint(0)]),
    ...file,
    ...data,
    ...block([...vint(5), ...vint(0), ...vint(0)]),
  ]);
}
