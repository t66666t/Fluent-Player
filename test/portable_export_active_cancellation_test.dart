import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'active FluentPack cancellation closes real source and partial handles',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'portable-active-cancel-',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      final library = LibraryService()
        ..writeLibrarySnapshotOverrideForTesting = () async {};
      addTearDown(() async {
        library.resetLibraryForTesting();
        PathProviderPlatform.instance = previous;
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        final actual = await root.resolveSymbolicLinks();
        if (!p.isWithin(temp, actual) ||
            !p.basename(actual).startsWith('portable-active-cancel-')) {
          throw StateError(
            'Refusing cleanup outside the generated test directory',
          );
        }
        await root.delete(recursive: true);
      });
      final source = File(p.join(root.path, 'source.mp4'));
      final random = Random(9342);
      final block = Uint8List.fromList(
        List.generate(1024 * 1024, (_) => random.nextInt(256)),
      );
      final writer = await source.open(mode: FileMode.write);
      try {
        for (var i = 0; i < 64; i++) {
          await writer.writeFrom(block);
        }
        await writer.flush();
      } finally {
        await writer.close();
      }
      library.seedVideoForTesting(
        VideoItem(
          id: 'clip',
          path: source.path,
          title: 'Real cancellation',
          durationMs: 1000,
          lastUpdated: 1,
          parentId: 'pending',
          hasProbedChapters: true,
        ),
      );
      await library.moveItemToCollection('clip', null);
      final target = File(p.join(root.path, 'old.fluentpack'));
      await target.writeAsString('previous complete target');
      final partial = File('${target.path}.part');
      final service = PortableTransferService.forTesting();
      final task = await service.exportSelection(
        library: library,
        rootIds: ['clip'],
        outputPath: target.path,
        options: const PortableExportOptions(
          packageName: 'Cancellation audit',
          compression: PortableCompression.smallest,
          verifyChecksums: false,
          includeSidecars: false,
          includeDanmaku: false,
        ),
      );
      var cancelledInNativeWrite = false;
      final cancellationTime = Stopwatch();
      final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        if (cancelledInNativeWrite || !partial.existsSync()) return;
        final bytes = partial.lengthSync();
        if (bytes > 1024 * 1024 && bytes < 64 * 1024 * 1024) {
          cancelledInNativeWrite = true;
          cancellationTime.start();
          service.cancel(task.id);
        }
      });
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (task.isActive && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          cancelledInNativeWrite,
          isTrue,
          reason: 'Must cancel an actual mid-file writer',
        );
        expect(task.isActive, isFalse);
        expect(
          task.status,
          PortableTransferStatus.cancelled,
          reason: task.error,
        );
        expect(cancellationTime.elapsed, lessThan(const Duration(seconds: 8)));
        expect(await partial.exists(), isFalse);
        await partial.writeAsString('partial handle was released', flush: true);
        await partial.delete();
        final moved = await source.rename('${source.path}.checked');
        expect(await moved.length(), 64 * 1024 * 1024);
        await moved.rename(source.path);
        expect(await target.readAsString(), 'previous complete target');
      } finally {
        timer.cancel();
      }
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
