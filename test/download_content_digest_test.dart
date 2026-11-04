import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/download_content_digest.dart';

void main() {
  test(
    'a retained prefix and streamed suffix have the same SHA-256 seal',
    () async {
      final digest = DownloadContentDigest();
      await digest.addStream(Stream.value(utf8.encode('a')));
      final output = <int>[];
      await for (final bytes in digest.bind(
        Stream.fromIterable([utf8.encode('b'), utf8.encode('c')]),
      )) {
        output.addAll(bytes);
      }
      expect(utf8.decode(output), 'bc');
      expect(
        digest.finish(3),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    },
  );

  test('a digest cannot seal an incomplete or overwritten output', () {
    final digest = DownloadContentDigest()..add([1, 2, 3]);
    expect(() => digest.finish(2), throwsFormatException);
    expect(() => digest.finish(4), throwsFormatException);
  });

  test(
    'cancellation stops prefix reads instead of sealing truncated data',
    () async {
      final digest = DownloadContentDigest();
      var checked = 0;
      await expectLater(
        digest.addStream(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          checkCancelled: () {
            if (++checked == 2) throw StateError('paused');
          },
        ),
        throwsStateError,
      );
      expect(digest.bytes, 2);
      expect(() => digest.finish(4), throwsFormatException);
    },
  );
}
