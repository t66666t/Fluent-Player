import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/imported_media_title.dart';

void main() {
  group('resolveImportedMediaTitle', () {
    test('preserves an authoritative title containing a forward slash', () {
      const title =
          '【中英/注释】跌宕起伏后的欢快谢幕！See Me Now·Kanye West·My Beautiful Dark Twisted Fantasy';

      expect(
        resolveImportedMediaTitle(
          sourcePath: r'C:\downloads\downloaded.mp4',
          originalTitle: title,
        ),
        title,
      );
    });

    test('preserves path-like and surrounding characters in metadata', () {
      const title = r'  A/B\C: D?.mp4  ';

      expect(
        resolveImportedMediaTitle(
          sourcePath: r'C:\downloads\fallback.mp4',
          originalTitle: title,
        ),
        title,
      );
    });

    test(
      'cleans app-generated prefixes only when falling back to a file name',
      () {
        expect(
          resolveImportedMediaTitle(
            sourcePath:
                r'C:\downloads\123e4567-e89b-12d3-a456-426614174000_Movie.mp4',
          ),
          'Movie.mp4',
        );
      },
    );
  });
}
