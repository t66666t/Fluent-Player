import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/batch_import_files.dart';

void main() {
  late Directory root;

  setUp(
    () async => root = await Directory.systemTemp.createTemp('batch_files_'),
  );
  tearDown(() async => root.delete(recursive: true));

  Future<String> file(String name) async {
    final target = File(p.join(root.path, name));
    await target.parent.create(recursive: true);
    await target.writeAsString('fixture');
    return p.normalize(target.path);
  }

  test(
    'mixed input keeps each kind in input order and ignores other types',
    () async {
      final subtitle2 = await file('02.VTT');
      final media2 = await file('02.MP4');
      final media1 = await file('01.flac');
      final subtitle1 = await file('01.srt');
      final directory = await Directory(
        p.join(root.path, 'folder.mp4'),
      ).create();
      final files = await collectBatchImportFiles(
        [
          subtitle2,
          media2,
          await file('notes.txt'),
          media1,
          subtitle1,
          await file('cover.jpg'),
          directory.path,
          p.join(root.path, 'missing.mp4'),
          'https://example.org/movie.mp4',
          'content://documents/movie.mp4',
        ],
        extractSubtitleArchive: (_) async =>
            fail('No archive should be opened'),
      );
      expect(files.media, [media2, media1]);
      expect(files.subtitles, [subtitle2, subtitle1]);
      expect(files.ignored, 6);
    },
  );

  test(
    'file URIs, Unicode and duplicates normalize without changing order',
    () async {
      final media = await file('课程 一.MKV');
      final subtitle = await file('课程 一.ASS');
      final files = await collectBatchImportFiles(
        [
          Uri.file(media).toString(),
          media,
          subtitle,
          Uri.file(subtitle).toString(),
          await file('new.opus'),
        ],
        existingMedia: [media],
        extractSubtitleArchive: (_) async => [],
      );
      expect(files.media.map(p.basename), ['new.opus']);
      expect(files.subtitles, [subtitle]);
      expect(files.duplicates, 3);
      expect(files.ignored, 0);
    },
  );

  test(
    'archives expand in place, accept only subtitles and failures continue',
    () async {
      final before = await file('before.srt');
      final zip = await file('subs.zip');
      final after = await file('after.srt');
      final extracted = await file('extracted/inside.srt');
      final notSubtitle = await file('extracted/movie.mp4');
      final broken = await file('broken.zip');
      final files = await collectBatchImportFiles(
        [before, zip, after, broken, zip],
        extractSubtitleArchive: (path) async {
          if (path == broken) throw const FormatException('broken ZIP');
          return [extracted, notSubtitle];
        },
      );
      expect(files.subtitles, [before, extracted, after]);
      expect(files.media, isEmpty);
      expect(files.archives, [zip]);
      expect(files.ignored, 1);
      expect(files.failedArchives, 1);
      expect(files.duplicates, 1);
    },
  );

  test('large mixed selections classify without loading media bytes', () async {
    final paths = <String>[];
    for (var i = 0; i < 300; i++) {
      paths.add(await file('$i.mp4'));
      paths.add(await file('$i.srt'));
      paths.add(p.join(root.path, '$i.exe'));
    }
    final files = await collectBatchImportFiles(
      paths,
      extractSubtitleArchive: (_) async => [],
    );
    expect(files.media, hasLength(300));
    expect(files.subtitles, hasLength(300));
    expect(files.ignored, 300);
    expect(files.media.map(p.basename), [
      for (var i = 0; i < 300; i++) '$i.mp4',
    ]);
  });
}
