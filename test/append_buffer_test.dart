import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/append_buffer.dart';

void main() {
  test('ordinary mutable prefixes are still copied', () {
    final prefix = [1, 2, 3];
    final buffer = AppendBuffer<int>.fromPrefix(prefix, 2)..addAll([4]);
    prefix[0] = 90;
    expect(buffer.snapshot, [1, 2, 4]);
  });

  for (final count in [0, 1, 127, 128, 129, 257]) {
    test(
      'borrowed immutable prefix $count survives branch and partial-page appends',
      () {
        final prefix = List<int>.unmodifiable(List.generate(count, (i) => i));
        var source = (AppendBuffer<int>.fromPrefix(
          prefix,
          count,
          shareImmutablePrefix: true,
        )..addAll(List.generate(130, (i) => count + i))).snapshot;
        final original = source;
        for (var i = 0; i < 40; i++) {
          final next = AppendBuffer<int>.fromPrefix(source, source.length)
            ..addAll([count + 130 + i]);
          source = next.snapshot;
        }
        expect(source, List.generate(count + 170, (i) => i));
        expect(original, List.generate(count + 130, (i) => i));
        for (final cut in [0, count ~/ 2, count, count + 1, count + 129]) {
          final branch = AppendBuffer<int>.fromPrefix(source, cut)
            ..addAll([-1]);
          expect(branch.snapshot, [...List.generate(cut, (i) => i), -1]);
        }
        expect(() => source[0] = 12, throwsUnsupportedError);
      },
    );
  }
}
