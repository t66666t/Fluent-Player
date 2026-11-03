import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/lyrics/lyric_media_metadata.dart';

void main() {
  test(
    'reads case-insensitive artist/title tags with audio-stream fallback',
    () {
      final metadata = LyricMediaMetadata.fromProbeJson({
        'format': {
          'tags': {'TITLE': ' Song ', 'ARTIST': 'Artist', 'author': 'Uploader'},
        },
        'streams': [
          {
            'codec_type': 'audio',
            'tags': {'album': 'Album', 'artist': 'Stream Artist'},
          },
        ],
      });
      expect(metadata.title, 'Song');
      expect(metadata.artist, 'Artist');
      expect(metadata.album, 'Album');
    },
  );

  test(
    'author is used when artist is missing; malformed tags remain optional',
    () {
      expect(
        LyricMediaMetadata.fromProbeJson({
          'format': {
            'tags': {'AUTHOR': 'Author'},
          },
        }).artist,
        'Author',
      );
      expect(
        LyricMediaMetadata.fromProbeJson({
          'format': {
            'tags': {'artist': null},
          },
        }).artist,
        '',
      );
      expect(LyricMediaMetadata.fromProbeJson(null).title, '');
    },
  );

  test(
    'filename comes from the local file even if the library title was changed',
    () {
      expect(
        LyricMediaMetadata.filename(
          'Original Song.mp3',
          'Renamed Library Title',
        ),
        'Original Song',
      );
      expect(
        LyricMediaMetadata.filename(
          'https://example.com/video/42',
          'Online Title',
        ),
        'Online Title',
      );
    },
  );

  test(
    'missing local files and remote media safely fall back without probing',
    () async {
      expect(
        (await LyricMediaMetadataProbe.probe(
          'missing-lyrics-test-file.mp3',
        )).artist,
        '',
      );
      expect(
        (await LyricMediaMetadataProbe.probe(
          'https://example.com/song.mp3',
        )).artist,
        '',
      );
    },
  );
}
