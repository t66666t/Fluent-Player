import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

void main() {
  test('uses an audio item thumbnail as system media artwork', () async {
    final directory = await Directory.systemTemp.createTemp(
      'system_media_artwork_test_',
    );
    addTearDown(() => directory.delete(recursive: true));

    final artwork = File('${directory.path}${Platform.pathSeparator}cover.jpg');
    await artwork.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
    final item = VideoItem(
      id: 'audio-with-cover',
      path: '${directory.path}${Platform.pathSeparator}song.mp3',
      title: 'Song',
      thumbnailPath: artwork.path,
      durationMs: 1000,
      lastUpdated: 1,
      type: MediaType.audio,
    );

    expect(await resolveExistingMediaArtworkUri(item), artwork.uri);
  });

  test('ignores a missing thumbnail before placeholder fallback', () async {
    final item = VideoItem(
      id: 'audio-without-cover',
      path: 'song.mp3',
      title: 'Song',
      thumbnailPath: 'missing-cover.jpg',
      durationMs: 1000,
      lastUpdated: 1,
      type: MediaType.audio,
    );

    expect(await resolveExistingMediaArtworkUri(item), isNull);
  });
}
