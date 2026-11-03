import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final format in PortableExportFormat.values) {
    test(
      '$format: failed publication preserves an existing same-name export',
      () async {
        final root = await Directory.systemTemp.createTemp('portable-publish-');
        final originalProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        final library = LibraryService()
          ..writeLibrarySnapshotOverrideForTesting = () async {};
        addTearDown(() async {
          library.resetLibraryForTesting();
          PathProviderPlatform.instance = originalProvider;
          await root.delete(recursive: true);
        });
        final input = File(p.join(root.path, 'source.mp4'));
        await input.writeAsString('unchanged source media bytes');
        library.seedVideoForTesting(
          VideoItem(
            id: 'clip',
            path: input.path,
            title: 'Media',
            durationMs: 1000,
            lastUpdated: 1,
            parentId: 'pending',
            hasProbedChapters: true,
          ),
        );
        await library.moveItemToCollection('clip', null);
        final output = File(
          p.join(
            root.path,
            format == PortableExportFormat.zip ? 'out.zip' : 'out.fluentpack',
          ),
        );
        const oldContent = 'previous complete export that must survive';
        await output.writeAsString(oldContent, flush: true);
        final partialPath = '${output.path}.part';
        var renameAttempted = false;
        final service = PortableTransferService.forTesting();

        await IOOverrides.runZoned(
          () async {
            final task = await service.exportSelection(
              library: library,
              rootIds: const ['clip'],
              outputPath: output.path,
              options: PortableExportOptions(
                packageName: 'Publish test',
                format: format,
                includeSidecars: false,
                includeDanmaku: false,
                zipEmbedSubtitles: false,
                zipExternalSubtitles: false,
              ),
            );
            final deadline = DateTime.now().add(const Duration(seconds: 20));
            while (task.isActive && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(task.isActive, isFalse, reason: 'Export did not settle');
            expect(
              renameAttempted,
              isTrue,
              reason: 'The injected publication failure was not reached',
            );
            expect(task.status, PortableTransferStatus.failed);
          },
          createFile: (path) {
            final real = Zone.root.run(() => File(path));
            if (p.equals(p.normalize(p.absolute(path)), partialPath)) {
              return _FailedRenameFile(real, () => renameAttempted = true);
            }
            return real;
          },
        );

        expect(
          await output.exists(),
          isTrue,
          reason: 'A failed new export deleted the previous complete export',
        );
        expect(await output.readAsString(), oldContent);
        expect(await input.readAsString(), 'unchanged source media bytes');
        expect(await File(partialPath).exists(), isFalse);
      },
    );

    for (final cancel in [false, true]) {
      test(
        '$format: ${cancel ? 'cancel preserves' : 'success replaces'} an existing export',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'portable-existing-',
          );
          final originalProvider = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _Paths(root.path);
          final library = LibraryService()
            ..writeLibrarySnapshotOverrideForTesting = () async {};
          addTearDown(() async {
            library.resetLibraryForTesting();
            PathProviderPlatform.instance = originalProvider;
            await root.delete(recursive: true);
          });
          final input = File(p.join(root.path, 'source.mp4'));
          await input.writeAsString('unchanged source media bytes');
          library.seedVideoForTesting(
            VideoItem(
              id: 'clip',
              path: input.path,
              title: 'Media',
              durationMs: 1000,
              lastUpdated: 1,
              parentId: 'pending',
              hasProbedChapters: true,
            ),
          );
          await library.moveItemToCollection('clip', null);
          final output = File(
            p.join(
              root.path,
              format == PortableExportFormat.zip ? 'out.zip' : 'out.fluentpack',
            ),
          );
          const oldContent = 'previous complete export';
          await output.writeAsString(oldContent, flush: true);
          final service = PortableTransferService.forTesting();
          final task = await service.exportSelection(
            library: library,
            rootIds: const ['clip'],
            outputPath: output.path,
            options: PortableExportOptions(
              packageName: 'Publish test',
              format: format,
              includeSidecars: false,
              includeDanmaku: false,
              zipEmbedSubtitles: false,
              zipExternalSubtitles: false,
            ),
          );
          if (cancel) {
            expect(task.isActive, isTrue);
            service.cancel(task.id);
          }
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (task.isActive && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(task.isActive, isFalse);
          expect(
            task.status,
            cancel
                ? PortableTransferStatus.cancelled
                : PortableTransferStatus.completed,
            reason: task.error,
          );
          if (cancel) {
            expect(await output.readAsString(), oldContent);
          } else {
            final archive = ZipDecoder().decodeBytes(
              await output.readAsBytes(),
            );
            final media = archive.files.singleWhere(
              (entry) => entry.name.endsWith('.mp4'),
            );
            expect(media.content, orderedEquals(await input.readAsBytes()));
          }
          expect(await input.readAsString(), 'unchanged source media bytes');
          expect(await File('${output.path}.part').exists(), isFalse);
        },
      );
    }
  }
}

/// Real disk I/O remains active; only the final rename fails, after encoding.
class _FailedRenameFile implements File {
  _FailedRenameFile(this.real, this.onRename);
  final File real;
  final void Function() onRename;
  @override
  String get path => real.path;
  @override
  Directory get parent => real.parent;
  @override
  File get absolute => this;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<int> length() => real.length();
  @override
  int lengthSync() => real.lengthSync();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  Future<File> rename(String newPath) async {
    onRename();
    throw FileSystemException('Injected publication failure', newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getDownloadsPath() async => path;
}
