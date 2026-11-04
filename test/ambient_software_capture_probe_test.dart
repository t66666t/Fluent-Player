import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/ambient_frame_thumbnail.dart';

void main() {
  test(
    'explicit software capture confirms yes and restores the exact original',
    () async {
      var option = 'no';
      final writes = <String>[];
      final result = await probeAmbientSoftwareCapture(
        readOption: () async => option,
        writeOption: (value) async {
          writes.add(value);
          option = value;
        },
        captureRawByteLength: () async {
          expect(option, 'yes');
          return 8294400;
        },
        isCurrent: () => true,
      );
      expect(writes, ['yes', 'no']);
      expect(option, 'no');
      expect(result['screenshotSwBefore'], 'no');
      expect(result['screenshotSwDuring'], 'yes');
      expect(result['screenshotSwRestored'], 'no');
      expect(result['rawByteLength'], 8294400);
      expect(result['rawElapsedMs'], isNonNegative);
    },
  );

  test(
    'unknown original values do not modify the option or capture a frame',
    () async {
      for (final original in ['', 'unknown', 'auto']) {
        final result = await probeAmbientSoftwareCapture(
          readOption: () async => original,
          writeOption: (_) async =>
              fail('Unknown options must remain untouched'),
          captureRawByteLength: () async =>
              fail('An unknown software mode is not probed'),
          isCurrent: () => true,
        );
        expect(result['screenshotSwBefore'], original);
        expect(result['softwareCaptureSkipped'], 'unknown_original_option');
        expect(result['rawAttempted'], isFalse);
        expect(result['screenshotSwRestoreAttempted'], isFalse);
      }
    },
  );

  test(
    'a failed screenshot still restores the original software option',
    () async {
      var option = 'no';
      final result = await probeAmbientSoftwareCapture(
        readOption: () async => option,
        writeOption: (value) async => option = value,
        captureRawByteLength: () async =>
            throw StateError('raw capture failed'),
        isCurrent: () => true,
      );
      expect(option, 'no');
      expect(result['rawAttempted'], isTrue);
      expect(result['screenshotSwRestored'], 'no');
      expect(result['softwareCaptureError'], contains('raw capture failed'));
    },
  );

  test(
    'a retiring session never receives a restore or any further reads',
    () async {
      var current = true;
      var option = 'no';
      var reads = 0;
      final writes = <String>[];
      final result = await probeAmbientSoftwareCapture(
        readOption: () async {
          expect(current, isTrue);
          reads++;
          return option;
        },
        writeOption: (value) async {
          expect(current, isTrue);
          writes.add(value);
          option = value;
        },
        captureRawByteLength: () async {
          current = false;
          return 8294400;
        },
        isCurrent: () => current,
      );
      expect(writes, ['yes']);
      expect(reads, 2);
      expect(result['screenshotSwRestoreAttempted'], isFalse);
    },
  );

  test('an already enabled option needs no setter or restoration', () async {
    final result = await probeAmbientSoftwareCapture(
      readOption: () async => 'yes',
      writeOption: (_) async => fail('An already enabled option is unchanged'),
      captureRawByteLength: () async => 1234,
      isCurrent: () => true,
    );
    expect(result['rawByteLength'], 1234);
    expect(result['screenshotSwRestoreAttempted'], isFalse);
  });
}
