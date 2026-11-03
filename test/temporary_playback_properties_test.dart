import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/temporary_playback_properties.dart';

void main() {
  for (final fail in [false, true]) {
    test(
      'temporary join restores options after ${fail ? 'failure' : 'success'}',
      () async {
        final native = {'cache-pause': 'yes', 'hr-seek': 'default'};
        final operation =
            TemporaryPlaybackProperties(
              read: (key) async => native[key]!,
              write: (key, value) async => native[key] = value,
              isCurrent: () => true,
              latestPolicy: () => {},
            ).run({'cache-pause': 'no', 'hr-seek': 'yes'}, () async {
              expect(native['cache-pause'], 'no');
              if (fail) throw StateError('decoder failed');
              return 7;
            });
        if (fail) {
          await expectLater(operation, throwsStateError);
        } else {
          expect(await operation, 7);
        }
        expect(native, {'cache-pause': 'yes', 'hr-seek': 'default'});
      },
    );
  }

  test('a newer user seek policy survives join cleanup', () async {
    final native = {'hr-seek': 'default', 'cache-pause': 'yes'};
    final latest = <String, String>{};
    await TemporaryPlaybackProperties(
      read: (key) async => native[key]!,
      write: (key, value) async => native[key] = value,
      isCurrent: () => true,
      latestPolicy: () => latest,
    ).run({'hr-seek': 'yes', 'cache-pause': 'no'}, () async {
      latest['hr-seek'] = 'no';
    });
    expect(native, {'hr-seek': 'no', 'cache-pause': 'yes'});
  });
}
