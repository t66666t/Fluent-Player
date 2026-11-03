import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/utils/local_filesystem_path.dart';

void main() {
  test('strips file:// URIs from Linux drag-drop paths', () {
    expect(
      normalizeLocalFilesystemPath(
        'file:///workspace/Video-master-test/videos/en/en_dialogue_practice.mp4',
      ),
      p.normalize(
        Uri.parse(
          'file:///workspace/Video-master-test/videos/en/en_dialogue_practice.mp4',
        ).toFilePath(),
      ),
    );
  });

  test('percent-decodes file:// URIs with spaces', () {
    expect(
      normalizeLocalFilesystemPath('file:///home/user/My%20Videos/a.mp4'),
      p.normalize(
        Uri.parse('file:///home/user/My%20Videos/a.mp4').toFilePath(),
      ),
    );
  });

  test('rejects empty and keeps network schemes', () {
    expect(normalizeLocalFilesystemPath('  '), isNull);
    expect(normalizeLocalFilesystemPath(null), isNull);
    expect(
      normalizeLocalFilesystemPath('https://example.com/a.mp4'),
      'https://example.com/a.mp4',
    );
    expect(
      normalizeLocalFilesystemPath('bilibili://stream/BV1'),
      'bilibili://stream/BV1',
    );
  });

  test('normalizes plain absolute paths', () {
    expect(
      normalizeLocalFilesystemPath(
        '/workspace/Video-master-test/videos/zh/zh_dialogue_practice.mp4',
      ),
      p.normalize(
        '/workspace/Video-master-test/videos/zh/zh_dialogue_practice.mp4',
      ),
    );
  });
}
