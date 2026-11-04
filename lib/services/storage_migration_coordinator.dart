import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'app_storage_service.dart';

class StorageParticipant {
  const StorageParticipant(this.name, this.prepare);
  final String name;

  /// Must stop admission, finish writers, flush records, close SQLite handles.
  /// The desktop restarts after a maintenance operation, including failure.
  final Future<void> Function() prepare;
}

class StorageMigrationResult {
  const StorageMigrationResult(this.files, this.bytes, this.journal);
  final int files, bytes;
  final String journal;
}

/// Copy/verify/commit: source files are never deleted by migration. A journal
/// checkpoint plus the original records can recover every pre-commit failure.
class StorageMigrationCoordinator {
  StorageMigrationCoordinator(
    this.storage, {
    this.availableBytes,
    this.checkpoint,
    this.bootstrap = false,
  });
  final AppStorageService storage;
  final bool bootstrap;
  final Future<int> Function(Directory)? availableBytes;
  final Future<void> Function(String)? checkpoint;
  static final Map<String, StorageParticipant> participants = {};
  static bool maintenance = false;
  static Future<void> Function()? preflight;
  static void register(StorageParticipant participant) =>
      participants[participant.name] = participant;

  Future<StorageMigrationResult> migrate(
    Directory target, {
    bool organize = false,
  }) async {
    if (maintenance) throw const StorageUnavailableException('目录整理正在进行');
    if (!bootstrap) await preflight?.call();
    final control = storage.controlDirectory;
    await control.create(recursive: true);
    final journal = File(p.join(control.path, 'migration.json'));
    Map? pending;
    if (await journal.exists()) {
      try {
        final value = jsonDecode(await journal.readAsString());
        if (value is Map &&
            value['version'] == 1 &&
            value['phase'] != 'committed' &&
            value['oldRoot'] == storage.dataDirectory.path &&
            value['targetRoot'] == target.path) {
          pending = value;
        }
      } catch (_) {
        /* do not trust an unreadable journal */
      }
    }
    await storage.validateNewRoot(target, resumeOwnedTarget: pending != null);
    final hadLease = storage.hasForegroundLease;
    await storage.releaseForegroundLease();
    final lock = await File(
      p.join(control.path, 'migration.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      if (hadLease) await storage.acquireForegroundLease();
      throw const StorageUnavailableException('后台任务正在使用存储，请稍后重试');
    }
    final old = storage.dataDirectory;
    final mappings = <String, String>{};
    final entries = <Map<String, dynamic>>[];
    var bytes = 0;
    var prepared = false;
    final runId = DateTime.now().microsecondsSinceEpoch.toString();
    final backups = Directory(p.join(control.path, 'migration-backups', runId));
    try {
      maintenance = true;
      for (final participant
          in (bootstrap
              ? const <StorageParticipant>[]
              : participants.values.toList())) {
        prepared = true;
        await participant.prepare();
      }
      prepared = true;
      await checkpoint?.call('prepared');
      final origins = <String, String>{};
      String originKey(String path) => Platform.isWindows
          ? p.normalize(path).toLowerCase()
          : p.normalize(path);
      if (organize) {
        final library = File(p.join(old.path, 'library.json'));
        if (await library.exists()) {
          final data = jsonDecode(await library.readAsString());
          for (final item in (data['videos'] as List? ?? const [])) {
            if (item is Map && item['path'] is String) {
              final path = originKey(item['path'] as String);
              final source = item['sourceRef'];
              final url = source is Map ? '${source['value'] ?? ''}' : '';
              final uri = Uri.tryParse(url);
              final host = uri?.host.toLowerCase() ?? '';
              final kind =
                  host == 'bilibili.com' ||
                      host.endsWith('.bilibili.com') ||
                      uri?.scheme == 'bilibili' ||
                      item['isBilibiliExported'] == true
                  ? 'bilibili'
                  : 'imported';
              origins[path] = origins.containsKey(path) && origins[path] != kind
                  ? 'imported'
                  : kind;
            }
          }
        }
      }
      final sources = <String, String>{};
      final directories = <String, String>{};
      Future<void> collect(
        Directory root,
        String destination, {
        bool scoped = false,
      }) async {
        if (!await root.exists()) return;
        await Directory(destination).create(recursive: true);
        if (!AppStorageService.samePath(root.path, old.path)) {
          directories[root.path] = destination;
        }
        await for (final item in root.list(followLinks: false)) {
          if (await FileSystemEntity.type(item.path, followLinks: false) ==
              FileSystemEntityType.link) {
            throw StorageUnavailableException('迁移不跟随链接：${item.path}');
          }
          final name = p.basename(item.path);
          if (scoped && !AppStorageService.ownedNames.contains(name)) continue;
          if (item is Directory) {
            await collect(item, p.join(destination, name));
          } else if (item is File) {
            sources[item.path] = p.join(destination, name);
          }
        }
      }

      await collect(old, target.path, scoped: true);
      // Only registered feature roots and task records outside the data root
      // are included, never another library or an entire shared Documents tree.
      for (final e in storage.roots.entries.where(
        (e) => e.key.startsWith('feature:'),
      )) {
        if (!p.isWithin(old.path, e.value.path)) {
          mappings[e.value.path] = p.join(
            target.path,
            e.key.substring('feature:'.length),
          );
          await collect(
            e.value,
            p.join(target.path, e.key.substring('feature:'.length)),
          );
        } else {
          mappings[e.value.path] = p.join(
            target.path,
            p.relative(e.value.path, from: old.path),
          );
        }
      }
      for (final e in storage.registeredStores.entries) {
        if (p.isWithin(old.path, e.value)) continue;
        final source = File(e.value);
        if (!await source.exists()) continue;
        final site = e.key.split('/').first;
        if (site == 'data') {
          sources[source.path] = p.join(target.path, p.basename(source.path));
        } else if (site == 'web') {
          await collect(
            source.parent,
            p.join(target.path, 'downloads', 'web', 'tasks'),
          );
          // Completed legacy web files are one level above queue_v2.
          await for (final item in source.parent.parent.list(
            followLinks: false,
          )) {
            if (item is File) {
              sources[item.path] = p.join(
                target.path,
                'downloads',
                'web',
                'files',
                p.basename(item.path),
              );
            }
          }
        } else if (site == 'douyin') {
          sources[source.path] = p.join(
            target.path,
            'downloads',
            site,
            'tasks',
            'tasks.json',
          );
          await for (final item in source.parent.list(followLinks: false)) {
            if (item is File && item.path != source.path) {
              sources[item.path] = p.join(
                target.path,
                'downloads',
                site,
                'files',
                p.basename(item.path),
              );
            }
          }
        }
      }
      String organized(String source, String destination) {
        if (!organize) return destination;
        final relative = p.relative(destination, from: target.path);
        final parts = p.split(relative);
        if (parts.first == 'imported_videos') {
          return p.joinAll([
            target.path,
            if (origins[originKey(source)] == 'bilibili') ...[
              'downloads',
              'bilibili',
              'files',
            ] else
              'imported_media',
            ...parts.skip(1),
          ]);
        }
        const sites = {
          'douyin_downloads': 'douyin',
          'web_media_downloads': 'web',
          'yt_dlp_downloads': 'yt_dlp',
        };
        final site = sites[parts.first];
        if (site == null) return destination;
        if (site == 'web' && parts.length > 1 && parts[1] == 'queue_v2') {
          final tail = parts.skip(2).toList();
          if (tail.isNotEmpty && tail.first == 'tasks') tail.removeAt(0);
          return p.joinAll([target.path, 'downloads', site, 'tasks', ...tail]);
        }
        return p.joinAll([
          target.path,
          'downloads',
          site,
          if (site == 'douyin' && parts.last == 'tasks.json')
            'tasks'
          else
            'files',
          ...parts.skip(1),
        ]);
      }

      for (final entry in directories.entries) {
        final anchor = organized(
          p.join(entry.key, '.directory-anchor'),
          p.join(entry.value, '.directory-anchor'),
        );
        final destination = p.dirname(anchor);
        mappings[entry.key] = destination;
        await Directory(destination).create(recursive: true);
      }
      final allocated = <String>{};
      final priorHashes = <String, String>{
        for (final e in (pending?['entries'] as List? ?? const []))
          if (e is Map && e['target'] is String && e['sha256'] is String)
            e['target'] as String: e['sha256'] as String,
      };
      for (final e in sources.entries) {
        var destination = organized(e.key, e.value);
        if (AppStorageService.samePath(e.key, destination)) continue;
        final stat = await File(e.key).stat();
        if (await File(destination).exists()) {
          if (await _hash(File(e.key)) != await _hash(File(destination))) {
            if (priorHashes[destination] != await _hash(File(destination))) {
              if (p.basename(destination) == 'library.json') {
                throw const StorageUnavailableException('目标媒体库已变化，请选择空目录');
              }
              final suffix = sha256
                  .convert(utf8.encode(e.key))
                  .toString()
                  .substring(0, 12);
              destination = p.join(
                p.dirname(destination),
                '${p.basenameWithoutExtension(destination)}_$suffix${p.extension(destination)}',
              );
            }
          }
        }
        if (!allocated.add(destination.toLowerCase())) {
          final suffix = sha256
              .convert(utf8.encode(e.key))
              .toString()
              .substring(0, 12);
          destination = p.join(
            p.dirname(destination),
            '${p.basenameWithoutExtension(destination)}_$suffix${p.extension(destination)}',
          );
        }
        mappings[e.key] = destination;
        if (!AppStorageService.samePath(p.dirname(e.key), old.path)) {
          mappings.putIfAbsent(p.dirname(e.key), () => p.dirname(destination));
        }
        entries.add({
          'source': e.key,
          'target': destination,
          'length': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
          'copied': false,
        });
        bytes += stat.size;
      }
      final free = await (availableBytes ?? _freeSpace)(target);
      if (free < bytes + 16 * 1024 * 1024) {
        throw const StorageUnavailableException('目标空间不足；原数据未移动');
      }
      await backups.create(recursive: true);
      final state = <String, dynamic>{
        'version': 1,
        'id': runId,
        'oldRoot': old.path,
        'targetRoot': target.path,
        'phase': 'copying',
        'entries': entries,
        'backup': backups.path,
      };
      await writeStorageJson(journal, state);
      await checkpoint?.call('planned');
      for (var i = 0; i < entries.length; i++) {
        final row = entries[i];
        final source = File(row['source'] as String);
        final destination = File(row['target'] as String);
        await destination.parent.create(recursive: true);
        // Reusing an identical file does not authorize rewriting its contents.
        final partial = File('${destination.path}.migration-$runId');
        await source.copy(partial.path);
        final copiedHandle = await partial.open(mode: FileMode.append);
        try {
          await copiedHandle.flush();
        } finally {
          await copiedHandle.close();
        }
        final digest = await _hash(source);
        if (digest != await _hash(partial) ||
            (await source.stat()).size != row['length'] ||
            (await source.stat()).modified.millisecondsSinceEpoch !=
                row['modified']) {
          throw const StorageUnavailableException('复制期间源文件变化，迁移已停止；原件仍保留');
        }
        if (await destination.exists()) {
          final currentHash = await _hash(destination);
          if (currentHash == digest) {
            await partial.delete();
          } else if (priorHashes[destination.path] == currentHash) {
            await destination.delete();
            await partial.rename(destination.path);
          } else {
            throw StorageUnavailableException('目标文件发生变化：${destination.path}');
          }
        } else {
          await partial.rename(destination.path);
        }
        row['copied'] = true;
        row['sha256'] = digest;
        if (i % 25 == 0) await writeStorageJson(journal, state);
      }
      state['phase'] = 'verified';
      await writeStorageJson(journal, state);
      await checkpoint?.call('verified');
      // Read-only backups of metadata precede any path rewrite. SQLite handles
      // were closed by participants; checkpoint copied databases before commit.
      final snapshot = <String, String>{};
      for (final file in [
        File(p.join(old.path, 'library.json')),
        File(p.join(storage.controlDirectory.path, 'layout.json')),
      ]) {
        if (await file.exists()) {
          final copy = p.join(
            backups.path,
            '${snapshot.length}-${p.basename(file.path)}',
          );
          await file.copy(copy);
          snapshot[file.path] = copy;
        }
      }
      state['metadataBackup'] = snapshot;
      await writeStorageJson(journal, state);
      final oldAliases = Map<String, String>.of(storage.aliases);
      storage.aliases.addAll(mappings);

      try {
        for (final row in entries) {
          final file = File(row['target'] as String);
          if (file.path.endsWith('.json') || file.path.endsWith('.json.bak')) {
            dynamic value;
            try {
              value = jsonDecode(await file.readAsString());
            } on FormatException {
              continue;
            } // preserve unknown or damaged original verbatim
            // Keep the verified copy byte-for-byte. Committed path aliases are
            // applied by each schema adapter on read; its next normal save adds
            // current refs. This makes retries independent of partial rewrites.
            if (p.basename(file.path) == 'library.json' && value is! Map) {
              throw const StorageUnavailableException('媒体库格式不受支持，原数据已保留');
            }
          } else if (file.path.endsWith('.sqlite')) {
            final db = sqlite3.open(file.path);
            try {
              if (db.select('PRAGMA integrity_check').first.values.first !=
                  'ok') {
                throw const StorageUnavailableException('数据库校验失败，已保留原数据库');
              }
              db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
            } finally {
              db.dispose();
            }
          }
        }
        // SharedPreferences snapshots (yt-dlp and old web queues) remain in the
        // same OS store; the common decoder applies these committed aliases.
        for (final row in entries) {
          final current = await File(row['source'] as String).stat();
          if (current.size != row['length'] ||
              current.modified.millisecondsSinceEpoch != row['modified']) {
            throw const StorageUnavailableException(
              '原目录仍有其他程序写入，迁移已停止；请关闭其他实例后重试',
            );
          }
        }
        state['phase'] = 'committing';
        await writeStorageJson(journal, state);
        await checkpoint?.call('committing');
        await storage.commitRoot(target, mappings);
      } catch (_) {
        storage.aliases
          ..clear()
          ..addAll(oldAliases);
        rethrow;
      }
      state['phase'] = 'committed';
      await writeStorageJson(journal, state);
      await checkpoint?.call('committed');
      return StorageMigrationResult(entries.length, bytes, journal.path);
    } catch (_) {
      // Original records are authoritative until catalog commit. Leave the
      // journal and copies for inspection/retry, never delete either tree.
      rethrow;
    } finally {
      await lock.unlock();
      await lock.close();
      if (!prepared || participants.isEmpty || bootstrap) {
        maintenance = false;
        if (hadLease) await storage.acquireForegroundLease();
      }
    }
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  static Future<int> _freeSpace(Directory directory) async {
    if (Platform.isWindows) {
      // Query via the existing native network filesystem-capacity channel.
      return _windowsFreeSpace(directory);
    }
    final result = await Process.run('df', ['-Pk', directory.path]);
    if (result.exitCode != 0) {
      throw const StorageUnavailableException('无法确认目标可用空间');
    }
    final fields = '${result.stdout}'
        .trim()
        .split('\n')
        .last
        .trim()
        .split(RegExp(r'\s+'));
    if (fields.length < 4) {
      throw const StorageUnavailableException('无法确认目标可用空间');
    }
    return int.parse(fields[3]) * 1024;
  }
}

Future<int> _windowsFreeSpace(Directory directory) async {
  final result = await const MethodChannel(
    'com.example.video_player_app/yt_dlp',
  ).invokeMethod<int>('getStorageAvailableBytes', {'path': directory.path});
  if (result == null) throw const StorageUnavailableException('无法确认目标可用空间');
  return result;
}
