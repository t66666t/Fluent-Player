import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/thumbnail_seek.dart';

void main() {
  test('thumbnailSeekSeconds uses 15 percent floored at five seconds', () {
    expect(thumbnailSeekSeconds(durationMs: null), 5.0);
    expect(thumbnailSeekSeconds(durationMs: 0), 5.0);
    expect(thumbnailSeekSeconds(durationMs: 800), 0.0);
    expect(thumbnailSeekSeconds(durationMs: 20 * 1000), 5.0);
    expect(thumbnailSeekSeconds(durationMs: 100 * 1000), closeTo(15.0, 0.01));
    expect(thumbnailSeekSeconds(durationMs: 6 * 1000), closeTo(5.0, 0.01));
  });
}
