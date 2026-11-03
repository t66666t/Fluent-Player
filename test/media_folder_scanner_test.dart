import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/utils/media_folder_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('media_scanner_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> touch(String relPath) async {
    final file = File(p.join(tempDir.path, relPath));
    await file.create(recursive: true);
    return file;
  }

  /// 将扫描结果转换为相对于临时目录的路径，便于跨平台断言。
  Future<List<String>> scanRelative(String relPath) async {
    final paths = await scanMediaFolderOrdered(p.join(tempDir.path, relPath));
    return paths.map((path) => p.relative(path, from: tempDir.path)).toList();
  }

  test('文件夹优先：每层先递归子文件夹，再处理当前层媒体文件', () async {
    await touch('b.mp4');
    await touch('a.mp4');
    await touch('z.mp4');
    await touch('folderB/b1.mp4');
    await touch('folderB/b2.mp4');
    await touch('folderA/a2.mp4');
    await touch('folderA/a1.mp4');

    final result = await scanRelative('');

    expect(result, [
      p.joinAll(['folderA', 'a1.mp4']),
      p.joinAll(['folderA', 'a2.mp4']),
      p.joinAll(['folderB', 'b1.mp4']),
      p.joinAll(['folderB', 'b2.mp4']),
      'a.mp4',
      'b.mp4',
      'z.mp4',
    ]);
  });

  test('每层文件名自然排序：数字感知且忽略大小写', () async {
    await touch('10.mp4');
    await touch('2.mp4');
    await touch('sub/20.mp4');
    await touch('sub/3.mp4');
    await touch('sub/1.mp4');
    await touch('sub/B.mp4');
    await touch('sub/a.mp4');

    final result = await scanRelative('');

    expect(result, [
      p.joinAll(['sub', '1.mp4']),
      p.joinAll(['sub', '3.mp4']),
      p.joinAll(['sub', '20.mp4']),
      p.joinAll(['sub', 'a.mp4']),
      p.joinAll(['sub', 'B.mp4']),
      '2.mp4',
      '10.mp4',
    ]);
  });

  test('多级嵌套：按深度优先展开子文件夹', () async {
    await touch('top.mp4');
    await touch('l1/l2/deep.mp4');
    await touch('l1/l2/l3/very_deep.mp4');
    await touch('l1/mid.mp4');

    final result = await scanRelative('');

    expect(result, [
      p.joinAll(['l1', 'l2', 'l3', 'very_deep.mp4']),
      p.joinAll(['l1', 'l2', 'deep.mp4']),
      p.joinAll(['l1', 'mid.mp4']),
      'top.mp4',
    ]);
  });

  test('非媒体文件被过滤：仅保留可识别的视频/音频', () async {
    await touch('movie.mp4');
    await touch('notes.txt');
    await touch('cover.jpg');
    await touch('sub.srt');
    await touch('audio.mp3');
    await touch('subfolder/clip.mkv');
    await touch('subfolder/data.bin');
    await touch('subfolder/song.flac');

    final result = await scanRelative('');

    expect(result, [
      p.joinAll(['subfolder', 'clip.mkv']),
      p.joinAll(['subfolder', 'song.flac']),
      'audio.mp3',
      'movie.mp4',
    ]);
  });

  test('无媒体文件时返回空列表', () async {
    await touch('notes.txt');
    await touch('readme.md');
    await touch('sub/data.bin');

    final result = await scanRelative('');

    expect(result, isEmpty);
  });

  test('目录不存在时抛出 FileSystemException', () async {
    final missing = p.join(tempDir.path, 'does_not_exist');

    await expectLater(
      scanMediaFolderOrdered(missing),
      throwsA(isA<FileSystemException>()),
    );
  });
}
