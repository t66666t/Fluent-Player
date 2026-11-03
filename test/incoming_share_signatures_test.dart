import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/incoming_share_signatures.dart';

void main() {
  test('builds a stable signature for fluentpack shares', () {
    expect(
      IncomingShareSignatures.fromItems([
        {
          'kind': 'fluentpack',
          'uri': 'content://downloads/backup.fluentpack',
          'displayName': 'backup.fluentpack',
        },
      ]),
      'fluentpack:content://downloads/backup.fluentpack',
    );
  });

  test('string fluentpack paths are not signed as media', () {
    expect(
      IncomingShareSignatures.fromItems([r'D:\packs\library.fluentpack']),
      r'fluentpack:d:\packs\library.fluentpack',
    );
  });

  test('absorbs duplicate deliveries inside the short window', () {
    final recent = <String, DateTime>{};
    const signature = 'archive:content://downloads/zip';
    final now = DateTime(2026, 9, 16, 12);

    expect(
      IncomingShareSignatures.accept(
        signature,
        recent,
        now: now,
      ),
      isTrue,
    );
    expect(
      IncomingShareSignatures.accept(
        signature,
        recent,
        now: now.add(const Duration(milliseconds: 400)),
      ),
      isFalse,
    );
  });

  test('allows sharing the same archive again after the window', () {
    final recent = <String, DateTime>{};
    const signature = 'archive:content://downloads/zip';
    final now = DateTime(2026, 9, 16, 12);

    IncomingShareSignatures.accept(signature, recent, now: now);
    expect(
      IncomingShareSignatures.accept(
        signature,
        recent,
        now: now.add(const Duration(seconds: 4)),
      ),
      isTrue,
    );
  });

  test('system shares can present UI when the host route is buried', () {
    expect(
      canPresentIncomingImportUi(
        requireCurrentRoute: false,
        routeIsCurrent: false,
      ),
      isTrue,
    );
    expect(
      canPresentIncomingImportUi(
        requireCurrentRoute: true,
        routeIsCurrent: false,
      ),
      isFalse,
    );
  });

  test('home screen does not open a second share channel', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(home, isNot(contains('com.example.video_player_app/share_intent')));
    expect(home, isNot(contains('_setupIncomingMediaHandling')));
    final listener = File(
      'lib/widgets/incoming_share_listener.dart',
    ).readAsStringSync();
    expect(listener, contains('com.example.video_player_app/share_intent'));
  });
}
