import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/portable_transfer/sync_media_origin.dart';
import 'package:video_player_app/models/media_source_ref.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync_media_origin_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a local download keeps a Bilibili origin from becoming online', () async {
    final file = File(p.join(root.path, 'episode.mp4'));
    await file.writeAsBytes([1, 2, 3, 4]);
    final origin = await classifySyncMediaOrigin(
      path: 'bilibili://stream/BV1?cid=7',
      playbackPath: file.path,
      sourceKind: MediaSourceKind.bilibiliStream,
    );
    expect(origin.placement, SyncMediaPlacement.localFile);
    expect(origin.localPath, file.path);
  });

  test('a missing local path is unavailable instead of a silent skip', () async {
    final origin = await classifySyncMediaOrigin(
      path: p.join(root.path, 'gone.mp4'),
      sourceKind: MediaSourceKind.bilibiliStream,
    );
    expect(origin.placement, SyncMediaPlacement.unavailable);
    expect(origin.reason, 'missing-file');
  });

  test('content URIs stay explicit and file URIs normalize', () async {
    final content = await classifySyncMediaOrigin(path: 'content://media/1');
    expect(content.placement, SyncMediaPlacement.localContentUri);
    final file = File(p.join(root.path, 'clip.mp4'));
    await file.writeAsBytes([5]);
    final uri = await classifySyncMediaOrigin(path: file.uri.toString());
    expect(uri.placement, SyncMediaPlacement.localFile);
    expect(p.equals(uri.localPath!, file.path), isTrue);
  });

  test('an untouched online card stays a reference', () async {
    final origin = await classifySyncMediaOrigin(
      path: 'bilibili://stream/BV1?cid=7',
      sourceKind: MediaSourceKind.bilibiliStream,
    );
    expect(origin.placement, SyncMediaPlacement.onlineReference);
  });
}
