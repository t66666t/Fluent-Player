import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_copy_format.dart';
import 'package:video_player_app/utils/subtitle_copy_formatter.dart';

void main() {
  const List<SubtitleCueCopyParts> cues = <SubtitleCueCopyParts>[
    SubtitleCueCopyParts(primary: 'main one', secondary: 'translated one'),
    SubtitleCueCopyParts(primary: 'second sentence', secondary: ''),
    SubtitleCueCopyParts(primary: 'third sentence', secondary: ''),
  ];

  const String joined =
      'main one translated one second sentence third sentence';

  test('default format matches space-joined display text', () {
    expect(SubtitleCopyFormatter.joinedDisplayText(cues), joined);
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: SubtitleCopyFormat.defaults,
      ),
      joined,
    );
  });

  test('cue newline keeps bilingual pair on one line', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: SubtitleCopyFormat.defaults.copyWith(
          cueJoin: SubtitleCopyCueJoin.newline,
        ),
      ),
      'main one translated one\nsecond sentence\nthird sentence',
    );
  });

  test('bilingual newline splits primary and secondary', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: const SubtitleCopyFormat(
          cueJoin: SubtitleCopyCueJoin.newline,
          spaceCount: 1,
          customSeparator: '',
          bilingualJoin: SubtitleCopyBilingualJoin.newline,
        ),
      ),
      'main one\ntranslated one\nsecond sentence\nthird sentence',
    );
  });

  test('extra spaces join cues without touching bilingual pairing', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: SubtitleCopyFormat.defaults.copyWith(spaceCount: 3),
      ),
      'main one translated one   second sentence   third sentence',
    );
  });

  test('custom separator unescapes \\n', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: const SubtitleCopyFormat(
          cueJoin: SubtitleCopyCueJoin.custom,
          spaceCount: 1,
          customSeparator: r' | \n',
          bilingualJoin: SubtitleCopyBilingualJoin.inline,
        ),
      ),
      'main one translated one | \nsecond sentence | \nthird sentence',
    );
  });

  test('blank line inserts an empty line between cues', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: joined,
        cues: cues,
        format: SubtitleCopyFormat.defaults.copyWith(
          cueJoin: SubtitleCopyCueJoin.blankLine,
        ),
      ),
      'main one translated one\n\nsecond sentence\n\nthird sentence',
    );
  });

  test('partial selection keeps first/last fragments', () {
    const String selected = 'one translated one second sent';
    expect(
      SubtitleCopyFormatter.format(
        selectedText: selected,
        cues: cues,
        format: SubtitleCopyFormat.defaults,
      ),
      selected,
    );
    expect(
      SubtitleCopyFormatter.format(
        selectedText: selected,
        cues: cues,
        format: const SubtitleCopyFormat(
          cueJoin: SubtitleCopyCueJoin.newline,
          spaceCount: 1,
          customSeparator: '',
          bilingualJoin: SubtitleCopyBilingualJoin.newline,
        ),
      ),
      'one\ntranslated one\nsecond sent',
    );
  });

  test('monolingual cues ignore bilingual newline', () {
    const List<SubtitleCueCopyParts> primaryOnly = <SubtitleCueCopyParts>[
      SubtitleCueCopyParts(primary: 'hello', secondary: ''),
      SubtitleCueCopyParts(primary: 'world', secondary: ''),
    ];
    expect(
      SubtitleCopyFormatter.format(
        selectedText: 'hello world',
        cues: primaryOnly,
        format: const SubtitleCopyFormat(
          cueJoin: SubtitleCopyCueJoin.newline,
          spaceCount: 1,
          customSeparator: '',
          bilingualJoin: SubtitleCopyBilingualJoin.newline,
        ),
      ),
      'hello\nworld',
    );
  });

  test('unknown selected text falls back to the raw selection', () {
    expect(
      SubtitleCopyFormatter.format(
        selectedText: 'not in transcript',
        cues: cues,
        format: SubtitleCopyFormat.defaults.copyWith(
          cueJoin: SubtitleCopyCueJoin.newline,
        ),
      ),
      'not in transcript',
    );
  });

  test('json roundtrip preserves a custom format', () {
    const SubtitleCopyFormat original = SubtitleCopyFormat(
      cueJoin: SubtitleCopyCueJoin.custom,
      spaceCount: 4,
      customSeparator: r' / \n',
      bilingualJoin: SubtitleCopyBilingualJoin.newline,
    );
    expect(
      SubtitleCopyFormat.fromJsonString(original.toJsonString()),
      original,
    );
  });

  test('corrupt json falls back to space-join defaults', () {
    expect(SubtitleCopyFormat.fromJsonString('{'), SubtitleCopyFormat.defaults);
    expect(SubtitleCopyFormat.fromJsonString(''), SubtitleCopyFormat.defaults);
  });
}
