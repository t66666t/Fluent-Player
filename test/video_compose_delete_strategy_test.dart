import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/video_compose/video_compose_artifact_cleaner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('VideoComposeManager 删除策略', () {
    test('构建编号模式仅匹配同标题同编号', () {
      final cleaner = VideoComposeArtifactCleaner();
      final pattern = cleaner.buildComposeOutputPattern(
        '/tmp/my_title_compose_123456.mp4',
      );
      expect(pattern, isNotNull);
      expect(pattern!.hasMatch('my_title_compose_123456.mp4'), isTrue);
      expect(pattern.hasMatch('my_title_compose_123456.mov'), isTrue);
      expect(pattern.hasMatch('my_title_compose_654321.mp4'), isFalse);
      expect(pattern.hasMatch('other_title_compose_123456.mp4'), isFalse);
    });

    test('普通文件删除后应不存在', () async {
      final cleaner = VideoComposeArtifactCleaner();
      final tempDir = await Directory.systemTemp.createTemp('compose_delete_');
      final file = File('${tempDir.path}${Platform.pathSeparator}a.mp4');
      await file.writeAsString('123456');
      expect(await file.exists(), isTrue);

      final ok = await cleaner.deleteFileWithRetry(file.path);
      expect(ok, isTrue);
      expect(await file.exists(), isFalse);
      await tempDir.delete(recursive: true);
    });

    test('移动端编号删除应只删除对应编号文件', () async {
      final cleaner = VideoComposeArtifactCleaner();
      final tempDir = await Directory.systemTemp.createTemp(
        'compose_mobile_delete_',
      );
      final target = File(
        '${tempDir.path}${Platform.pathSeparator}demo_compose_10001.mp4',
      );
      final sameIdVariant = File(
        '${tempDir.path}${Platform.pathSeparator}demo_compose_10001.mov',
      );
      final otherId = File(
        '${tempDir.path}${Platform.pathSeparator}demo_compose_20002.mp4',
      );
      await target.writeAsString('a');
      await sameIdVariant.writeAsString('b');
      await otherId.writeAsString('c');

      final ok = await cleaner.deleteMobileComposeOutputs(target.path);
      expect(ok, isTrue);
      expect(await target.exists(), isFalse);
      expect(await sameIdVariant.exists(), isFalse);
      expect(await otherId.exists(), isTrue);
      await tempDir.delete(recursive: true);
    });

    test('自定义输出目录中的中文和空格路径可以精确删除', () async {
      final cleaner = VideoComposeArtifactCleaner();
      final tempDir = await Directory.systemTemp.createTemp(
        'compose_custom_output_',
      );
      final customDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}用户目录 含空格',
      );
      await customDir.create(recursive: true);
      final target = File(
        '${customDir.path}${Platform.pathSeparator}测试视频_compose_30003.mp4',
      );
      final unrelated = File(
        '${customDir.path}${Platform.pathSeparator}测试视频_compose_40004.mp4',
      );
      await target.writeAsString('target');
      await unrelated.writeAsString('keep');

      final ok = await cleaner.cleanupTaskArtifacts(
        'custom-task',
        deleteOutput: true,
        outputPath: target.path,
      );

      expect(ok, isTrue);
      expect(await target.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      await tempDir.delete(recursive: true);
    });
  });
}
