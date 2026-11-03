import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/media_cache/legacy_bilibili_cache_import.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';

StreamItem _quality(int id) => StreamItem(
  id: id,
  baseUrl: '',
  bandwidth: 1,
  codecs: 'avc',
  codecid: 7,
  qualityName: '${id}P',
  width: 640,
  height: 360,
);

BilibiliDownloadTask _task(List<BilibiliDownloadEpisode> episodes) =>
    BilibiliDownloadTask(
      videos: [
        BilibiliVideoItem(
          videoInfo: BilibiliVideoInfo(
            title: 'title',
            desc: '',
            pic: 'https://example.test/cover',
            bvid: 'BVone',
            aid: '1',
            ownerName: '',
            ownerMid: '',
            pubDate: 1,
            pages: [],
          ),
          episodes: episodes,
        ),
      ],
    );

BilibiliDownloadEpisode _episode(
  String bvid,
  int cid, {
  String? path,
  int quality = 360,
  List<String> imports = const [],
  DownloadStatus status = DownloadStatus.completed,
}) => BilibiliDownloadEpisode(
  bvid: bvid,
  page: BilibiliPage(cid: cid, page: 1, part: 'part', duration: 12),
  outputPath: path,
  selectedVideoQuality: _quality(quality),
  importedVideoIds: imports,
  status: status,
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('legacy-bili-');
  });
  tearDown(() => root.delete(recursive: true));

  Future<String> media(String name) async =>
      (await File(p.join(root.path, name)).writeAsBytes([1, 2, 3])).path;
  VideoItem item(
    String id,
    String path, {
    String bvid = 'BVone',
    int cid = 1,
  }) => VideoItem(
    id: id,
    path: path,
    title: id,
    durationMs: 12000,
    lastUpdated: 17,
    sourceRef: MediaSourceRef(
      value: bvid,
      kind: MediaSourceKind.bilibiliStream,
      bvid: bvid,
      cid: cid,
    ),
  );

  test(
    'first imported episode and first matching library card retain precedence',
    () async {
      final path = await media('one.mp4');
      final items = [item('first', path), item('second', path)];
      final tasks = [
        _task([
          _episode('BVone', 1, path: path, quality: 360, imports: ['first']),
          _episode('BVone', 1, path: path, quality: 720, imports: ['first']),
        ]),
      ];
      final variants = await legacyBilibiliCacheVariants(items, tasks).toList();
      expect(variants.map((v) => v.source.itemId), [
        'first',
        'second',
        'first',
        'first',
      ]);
      expect(variants.map((v) => v.quality.id), [
        '360',
        'legacy',
        '360',
        '720',
      ]);
      expect(variants.first.createdAt, 17);
      expect(variants.every((v) => !v.managed && v.bytes == 3), isTrue);
    },
  );

  test(
    'unimported completed files get the same synthetic source identity',
    () async {
      final path = await media('unimported.mp4');
      final variants = await legacyBilibiliCacheVariants([], [
        _task([_episode('BVnew', 22, path: path)]),
      ]).toList();
      final source = variants.single.source;
      expect(source.itemId, 'bilibili_cache_BVnew_22');
      expect(source.ref.bvid, 'BVnew');
      expect(source.ref.cid, 22);
      expect(source.legacyPath, path);
      expect(source.thumbnail, 'https://example.test/cover');
    },
  );

  test('remote, missing and incomplete files are not registered', () async {
    final incomplete = await media('incomplete.mp4');
    final variants = await legacyBilibiliCacheVariants(
      [
        item('remote', 'https://example.test/video.mp4'),
        item('missing', p.join(root.path, 'missing.mp4')),
      ],
      [
        _task([
          _episode('BVmissing', 2, path: p.join(root.path, 'missing.mp4')),
          _episode(
            'BVincomplete',
            3,
            path: incomplete,
            status: DownloadStatus.pending,
          ),
        ]),
      ],
    ).toList();
    expect(variants, isEmpty);
  });
}
