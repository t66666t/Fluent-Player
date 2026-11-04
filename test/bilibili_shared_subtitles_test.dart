import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_shared_subtitles.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  const bvid = 'BV1xx411c7mD';

  VideoItem online(String id, int cid) {
    return VideoItem(
      id: id,
      path: 'bilibili://stream/$bvid?cid=$cid',
      title: id,
      durationMs: 1000,
      lastUpdated: 0,
      sourceRef: MediaSourceRef(
        value: bvid,
        kind: MediaSourceKind.bilibiliStream,
        bvid: bvid,
        cid: cid,
      ),
    );
  }

  VideoItem localFile(String id) {
    return VideoItem(
      id: id,
      path: r'D:\videos\same.mp4',
      title: id,
      durationMs: 1000,
      lastUpdated: 0,
    );
  }

  test('only the same online part shares a subtitle folder', () async {
    final root = await Directory.systemTemp.createTemp('bili_shared_subs_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = BilibiliSharedSubtitles(dataRootOverride: root);
    final libraryCard = online('library-card', 101);
    final watchCard = online('watch-card', 101);
    final otherPart = online('other-part', 202);
    final fileCard = localFile('file-card');

    expect(bilibiliOnlinePartKey(libraryCard), bilibiliOnlinePartKey(watchCard));
    expect(bilibiliOnlinePartKey(otherPart), isNot(bilibiliOnlinePartKey(libraryCard)));
    expect(BilibiliSharedSubtitles.folderNameOf(fileCard), isNull);
    expect(bilibiliOnlinePartKey(fileCard), isNull);

    final path = await store.allocate(libraryCard, 'ai.srt');
    await File(path).writeAsString('1\n00:00:00,000 --> 00:00:01,000\n你好\n');

    expect(p.basename(path), 'ai.srt');
    expect(
      (await store.list(watchCard)).map((file) => p.basename(file.path)),
      <String>['ai.srt'],
    );
    expect(await store.list(otherPart), isEmpty);
    expect(await store.containsPath(path, watchCard), isTrue);
    expect(await store.isSharedPath(path), isTrue);
  });

  test('local cards that share a file are not one Bilibili part', () {
    final library = LibraryService()..resetLibraryForTesting();
    addTearDown(library.resetLibraryForTesting);
    library.seedVideoForTesting(online('library-card', 101));
    library.seedVideoForTesting(online('watch-card', 101));
    library.seedVideoForTesting(online('other-part', 202));
    library.seedVideoForTesting(localFile('file-a'));
    library.seedVideoForTesting(localFile('file-b'));

    expect(
      library.cardsOfSameBilibiliPart('library-card').map((item) => item.id),
      containsAll(<String>['library-card', 'watch-card']),
    );
    expect(
      library.cardsOfSameBilibiliPart('library-card').map((item) => item.id),
      isNot(contains('other-part')),
    );
    expect(
      library.cardsOfSameBilibiliPart('library-card').map((item) => item.id),
      isNot(contains('file-a')),
    );
    expect(library.cardsOfSameBilibiliPart('file-a'), isEmpty);
    expect(library.cardsOfSameBilibiliPart('file-b'), isEmpty);
  });
}