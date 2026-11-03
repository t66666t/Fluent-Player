import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/zip_export_plan.dart';
import 'package:video_player_app/features/portable_transfer/zip_media_exporter.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late LibraryService library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zip-cancel-audit-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    library = LibraryService()
      ..writeLibrarySnapshotOverrideForTesting = () async {};
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = previousPaths;
    final actual = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!p.isWithin(temp, actual) ||
        !p.basename(actual).startsWith('zip-cancel-audit-')) {
      throw StateError('Refusing cleanup outside the generated test directory');
    }
    await root.delete(recursive: true);
  });

  Future<File> seed({bool needsProbe = false, bool large = false}) async {
    final input = File(p.join(root.path, 'source.mp4'));
    final cover = needsProbe
        ? await File(
            p.join(root.path, 'cover.jpg'),
          ).writeAsString('probe fixture')
        : null;
    if (large) {
      final random = Random(6842);
      final block = Uint8List.fromList(
        List.generate(1024 * 1024, (_) => random.nextInt(256)),
      );
      final handle = await input.open(mode: FileMode.write);
      try {
        for (var i = 0; i < 64; i++) {
          await handle.writeFrom(block);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
    } else {
      await input.writeAsString('source bytes remain unchanged');
    }
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: input.path,
        title: 'Clip',
        durationMs: 1000,
        lastUpdated: 1,
        parentId: 'pending',
        hasProbedChapters: !needsProbe,
        thumbnailPath: cover?.path,
      ),
    );
    await library.moveItemToCollection('clip', null);
    return input;
  }

  const options = PortableExportOptions(
    packageName: 'Cancel audit',
    format: PortableExportFormat.zip,
    compression: PortableCompression.smallest,
    includeSidecars: false,
    includeDanmaku: false,
    zipEmbedSubtitles: false,
    zipExternalSubtitles: false,
  );

  test('cancel during probe never starts a ZIP pack worker', () async {
    final source = await seed(needsProbe: true);
    final target = File(p.join(root.path, 'old.zip'));
    await target.writeAsString('previous complete target');
    final probeEntered = Completer<void>();
    final probe = Completer<ZipSourceFacts>();
    var cancelled = false;
    var started = false;
    final exporter = ZipMediaExporter.forTesting(
      probeFacts: (_) {
        probeEntered.complete();
        return probe.future;
      },
      onPackStarted: () => started = true,
    );
    final running = exporter.run(
      library: library,
      rootIds: ['clip'],
      partialPath: '${target.path}.part',
      options: options,
      taskId: 'probe-cancel',
      isCancelled: () => cancelled,
      onProgress: (_, _, _, _) {},
    );
    final settles = expectLater(
      running,
      throwsA(isA<PortableExportCancelled>()),
    );
    await probeEntered.future;
    cancelled = true;
    ZipExportRuntime.cancel('probe-cancel');
    probe.complete(const ZipSourceFacts());
    await settles.timeout(const Duration(seconds: 5));
    expect(started, isFalse);
    expect(await File('${target.path}.part').exists(), isFalse);
    expect(await target.readAsString(), 'previous complete target');
    expect(await source.readAsString(), 'source bytes remain unchanged');
  });

  test(
    'native ZIP compression cancellation closes files before returning',
    () async {
      final source = await seed(large: true);
      final sourceLength = await source.length();
      final target = File(p.join(root.path, 'old.zip'));
      await target.writeAsString('previous complete target');
      final partial = File('${target.path}.part');
      var cancelled = false;
      var cancelledWhileWriting = false;
      final watch = Stopwatch()..start();
      final running = ZipMediaExporter().run(
        library: library,
        rootIds: ['clip'],
        partialPath: partial.path,
        options: options,
        taskId: 'compression-cancel',
        isCancelled: () => cancelled,
        onProgress: (_, subtitle, bytes, total) {
          if (!cancelled &&
              subtitle.startsWith('正在打包') &&
              bytes > 0 &&
              bytes < total) {
            cancelled = true;
            cancelledWhileWriting = true;
            watch.reset();
            ZipExportRuntime.cancel('compression-cancel');
          }
        },
      );
      await expectLater(
        running,
        throwsA(isA<PortableExportCancelled>()),
      ).timeout(const Duration(seconds: 20));
      expect(
        cancelledWhileWriting,
        isTrue,
        reason: 'Fixture must cancel an active native writer',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      expect(await partial.exists(), isFalse);
      // These real renames/deletes fail on Windows if either worker descriptor
      // is still open. No IOOverrides or archive fake participates in this test.
      await partial.writeAsString('reusable after cancellation', flush: true);
      await partial.rename('${partial.path}.checked');
      await File('${partial.path}.checked').delete();
      final movedSource = await source.rename('${source.path}.checked');
      expect(await movedSource.length(), sourceLength);
      await movedSource.rename(source.path);
      expect(await target.readAsString(), 'previous complete target');
      expect(
        await Directory(
          p.join(root.path, zipExportScratchDirectoryName),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'cancel after encoder creation closes an idle worker before cleanup',
    () async {
      final source = await seed();
      final target = File(p.join(root.path, 'old.zip'));
      await target.writeAsString('previous complete target');
      final partial = File('${target.path}.part');
      var cancelled = false;
      await expectLater(
        ZipMediaExporter().run(
          library: library,
          rootIds: ['clip'],
          partialPath: partial.path,
          options: options,
          taskId: 'idle-pack-cancel',
          isCancelled: () => cancelled,
          onProgress: (_, subtitle, bytes, _) {
            if (!cancelled && subtitle.startsWith('正在打包') && bytes == 0) {
              cancelled = true;
              ZipExportRuntime.cancel('idle-pack-cancel');
            }
          },
        ),
        throwsA(isA<PortableExportCancelled>()),
      ).timeout(const Duration(seconds: 8));
      expect(cancelled, isTrue);
      expect(await partial.exists(), isFalse);
      expect(await source.readAsString(), 'source bytes remain unchanged');
      expect(await target.readAsString(), 'previous complete target');
    },
  );

  test(
    'a native pack error closes output and preserves the prior target',
    () async {
      final source = await seed();
      final target = File(p.join(root.path, 'old.zip'));
      await target.writeAsString('previous complete target');
      final partial = File('${target.path}.part');
      var removedBeforeAdd = false;
      await expectLater(
        ZipMediaExporter().run(
          library: library,
          rootIds: ['clip'],
          partialPath: partial.path,
          options: options,
          taskId: 'pack-error',
          isCancelled: () => false,
          onProgress: (_, subtitle, bytes, _) {
            if (!removedBeforeAdd &&
                subtitle.startsWith('正在打包') &&
                bytes == 0) {
              source.deleteSync();
              removedBeforeAdd = true;
            }
          },
        ),
        throwsStateError,
      ).timeout(const Duration(seconds: 8));
      expect(removedBeforeAdd, isTrue);
      expect(await target.readAsString(), 'previous complete target');
      expect(await partial.exists(), isFalse);
      await partial.writeAsString('output handle released', flush: true);
      await partial.delete();
    },
  );

  test(
    'an old output owner blocks another task and ignores stale unbinds',
    () async {
      await seed();
      final partial = File(p.join(root.path, 'held.zip.part'));
      await partial.writeAsString('old writer output must remain untouched');
      final owner = ZipExportHandle();
      final other = ZipExportHandle();
      ZipExportRuntime.bind('old-owner', owner, partial.path);
      try {
        await expectLater(
          ZipMediaExporter().run(
            library: library,
            rootIds: ['clip'],
            partialPath: partial.path,
            options: options,
            taskId: 'different-task',
            isCancelled: () => false,
            onProgress: (_, _, _, _) {},
          ),
          throwsStateError,
        );
        expect(
          await partial.readAsString(),
          'old writer output must remain untouched',
        );
        ZipExportRuntime.unbind('old-owner', other);
        expect(ZipExportRuntime.isOutputBusy(partial.path), isTrue);
      } finally {
        ZipExportRuntime.unbind('old-owner', owner);
      }
      expect(ZipExportRuntime.isOutputBusy(partial.path), isFalse);
    },
  );

  test(
    'a delayed worker retains its marker and output until actual exit',
    () async {
      final source = await seed();
      final target = File(p.join(root.path, 'old.zip'));
      await target.writeAsString('previous complete target');
      final partial = File('${target.path}.part');
      var cancelled = false;
      Timer? cancelTimer;
      final elapsed = Stopwatch()..start();
      try {
        await expectLater(
          ZipMediaExporter.forTesting(
            workerDelayBeforeAdd: const Duration(seconds: 6),
          ).run(
            library: library,
            rootIds: ['clip'],
            partialPath: partial.path,
            options: options,
            taskId: 'delayed-worker',
            isCancelled: () => cancelled,
            onProgress: (_, subtitle, bytes, _) {
              if (cancelTimer == null &&
                  subtitle.startsWith('正在打包') &&
                  bytes == 0) {
                cancelTimer = Timer(const Duration(milliseconds: 50), () {
                  cancelled = true;
                  ZipExportRuntime.cancel('delayed-worker');
                });
              }
            },
          ),
          throwsStateError,
        ).timeout(const Duration(seconds: 8));
        expect(cancelled, isTrue);
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 6)));
        expect(ZipExportRuntime.isOutputBusy(partial.path), isTrue);
        final marker = File(
          p.join(
            root.path,
            zipExportScratchDirectoryName,
            'delayed-worker',
            '.zip-cancel',
          ),
        );
        expect(await marker.exists(), isTrue);
        expect(await partial.exists(), isTrue);
        await expectLater(
          ZipMediaExporter().run(
            library: library,
            rootIds: ['clip'],
            partialPath: partial.path,
            options: options,
            taskId: 'new-owner',
            isCancelled: () => false,
            onProgress: (_, _, _, _) {},
          ),
          throwsStateError,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (ZipExportRuntime.isOutputBusy(partial.path) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(ZipExportRuntime.isOutputBusy(partial.path), isFalse);
        expect(await marker.exists(), isFalse);
        expect(await partial.exists(), isFalse);
        expect(await target.readAsString(), 'previous complete target');
        expect(await source.readAsString(), 'source bytes remain unchanged');
      } finally {
        cancelTimer?.cancel();
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
