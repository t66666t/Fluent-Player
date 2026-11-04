import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/library_service.dart';

void main() {
  test('archive extraction ignores symbolic links and stays inside root', () {
    final sandbox = Directory.systemTemp.createTempSync(
      'archive_extraction_safety_test_',
    );
    addTearDown(() {
      if (sandbox.existsSync()) {
        sandbox.deleteSync(recursive: true);
      }
    });

    final output = Directory(p.join(sandbox.path, 'output'))..createSync();
    final outside = Directory(p.join(sandbox.path, 'outside'))..createSync();
    final archiveFile = File(p.join(sandbox.path, 'payload.tar'));
    final archive = Archive()
      ..addFile(ArchiveFile.string('media.mp4', 'media'))
      ..addFile(ArchiveFile.symlink('escape', '../outside'))
      ..addFile(ArchiveFile.string('escape/owned.mp4', 'owned'));
    archiveFile.writeAsBytesSync(TarEncoder().encode(archive), flush: true);

    final result = LibraryService.extractArchiveForTesting(
      archivePath: archiveFile.path,
      outputPath: output.path,
    );

    expect(result['extractedMediaEntries'], 2);
    expect(Link(p.join(output.path, 'escape')).existsSync(), isFalse);
    expect(
      File(p.join(output.path, 'escape', 'owned.mp4')).existsSync(),
      isTrue,
    );
    expect(File(p.join(outside.path, 'owned.mp4')).existsSync(), isFalse);
  });

  test('archive extraction keeps subtitle sidecars and skips documents', () {
    final sandbox = Directory.systemTemp.createTempSync(
      'archive_media_filter_test_',
    );
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    final output = Directory(p.join(sandbox.path, 'output'))..createSync();
    final archiveFile = File(p.join(sandbox.path, 'payload.tar'));
    final archive = Archive()
      ..addFile(ArchiveFile.string('season/readme.txt', 'large metadata'))
      ..addFile(ArchiveFile.string('season/episode.mp4', 'media'))
      ..addFile(ArchiveFile.string('season/episode.srt', 'subtitle'));
    archiveFile.writeAsBytesSync(TarEncoder().encode(archive), flush: true);

    final result = LibraryService.extractArchiveForTesting(
      archivePath: archiveFile.path,
      outputPath: output.path,
    );

    expect(result['extractedMediaEntries'], 1);
    expect(result['extractedSubtitleEntries'], 1);
    expect(result['extractedEntries'], 2);
    expect(result['skippedNonMediaEntries'], 1);
    expect(
      File(p.join(output.path, 'season', 'readme.txt')).existsSync(),
      false,
    );
    expect(
      File(p.join(output.path, 'season', 'episode.mp4')).existsSync(),
      true,
    );
    expect(
      File(p.join(output.path, 'season', 'episode.srt')).existsSync(),
      true,
    );
  });

  test('archive extraction enforces entry and byte budgets', () {
    final sandbox = Directory.systemTemp.createTempSync('archive_budget_test_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    final archiveFile = File(p.join(sandbox.path, 'payload.tar'));
    final archive = Archive()
      ..addFile(ArchiveFile.string('one.mp4', '12345'))
      ..addFile(ArchiveFile.string('two.mp4', '67890'));
    archiveFile.writeAsBytesSync(TarEncoder().encode(archive), flush: true);

    expect(
      () => LibraryService.extractArchiveForTesting(
        archivePath: archiveFile.path,
        outputPath: p.join(sandbox.path, 'entry_output'),
        maxEntryCount: 1,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => LibraryService.extractArchiveForTesting(
        archivePath: archiveFile.path,
        outputPath: p.join(sandbox.path, 'byte_output'),
        maxTotalBytes: 8,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('archive extraction rejects sanitized path collisions', () {
    final sandbox = Directory.systemTemp.createTempSync(
      'archive_collision_test_',
    );
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    final archiveFile = File(p.join(sandbox.path, 'payload.tar'));
    final archive = Archive()
      ..addFile(ArchiveFile.string('a?.mp4', 'one'))
      ..addFile(ArchiveFile.string('a*.mp4', 'two'));
    archiveFile.writeAsBytesSync(TarEncoder().encode(archive), flush: true);

    expect(
      () => LibraryService.extractArchiveForTesting(
        archivePath: archiveFile.path,
        outputPath: p.join(sandbox.path, 'output'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('archive extraction rejects abnormal media compression ratios', () {
    final sandbox = Directory.systemTemp.createTempSync('archive_ratio_test_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    final archiveFile = File(p.join(sandbox.path, 'payload.zip'));
    final repetitivePayload = List<String>.filled(10000, '0').join();
    final archive = Archive()
      ..addFile(ArchiveFile.string('compressed.mp4', repetitivePayload));
    archiveFile.writeAsBytesSync(ZipEncoder().encode(archive), flush: true);

    expect(
      () => LibraryService.extractArchiveForTesting(
        archivePath: archiveFile.path,
        outputPath: p.join(sandbox.path, 'output'),
        maxCompressionRatio: 2,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('advertised archive suffixes match implemented decoders', () {
    expect(LibraryService.isSupportedArchivePath('media.zip'), true);
    expect(LibraryService.isSupportedArchivePath('media.tar.gz'), true);
    expect(LibraryService.isSupportedArchivePath('media.tar.bz2'), true);
    expect(LibraryService.isSupportedArchivePath('media.tar.xz'), true);
    expect(LibraryService.isSupportedArchivePath('media.gz'), false);
    expect(LibraryService.isSupportedArchivePath('media.bz2'), false);
    expect(LibraryService.isSupportedArchivePath('media.xz'), false);
  });
}
