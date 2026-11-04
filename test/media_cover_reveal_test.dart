import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/cached_thumbnail_widget.dart';

void main() {
  test('cover reveal walks row by row, then stops waiting', () {
    expect(
      mediaCoverRevealDelay(index: 0, crossAxisCount: 3),
      Duration.zero,
    );
    expect(
      mediaCoverRevealDelay(index: 1, crossAxisCount: 3),
      const Duration(milliseconds: 36),
    );
    expect(
      mediaCoverRevealDelay(index: 3, crossAxisCount: 3),
      const Duration(milliseconds: 72),
    );
    expect(
      mediaCoverRevealDelay(index: 5, crossAxisCount: 3),
      const Duration(milliseconds: 72 + 72),
    );

    final lastStaggered = mediaCoverRevealDelay(index: 14, crossAxisCount: 3);
    final pastTheFold = mediaCoverRevealDelay(index: 15, crossAxisCount: 3);
    expect(lastStaggered, const Duration(milliseconds: 4 * 72 + 2 * 36));
    expect(pastTheFold, Duration.zero);
    expect(
      mediaCoverRevealDelay(index: -1, crossAxisCount: 3),
      Duration.zero,
    );
    expect(
      mediaCoverRevealDelay(index: 2, crossAxisCount: 0),
      const Duration(milliseconds: 2 * 72),
    );
  });
}
