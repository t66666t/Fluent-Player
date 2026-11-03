import 'dart:io';

import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

List<SubtitleItem> loadAlignmentLyrics(String language) =>
    SubtitleParser.parseSrt(
      File(
        'test/fixtures/subtitle_alignment/lyrics.$language.srt',
      ).readAsStringSync(),
    );

// Each entry is the English cue belonging to the corresponding Chinese OCR
// cue, using zero-based list positions (not the SRT cue number).
const expectedEnglishIndices = <int>[
  0,
  1,
  2,
  2,
  3,
  4,
  5,
  5,
  5,
  6,
  7,
  7,
  8,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
];
