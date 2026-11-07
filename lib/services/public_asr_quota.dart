import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/serial_task_queue.dart';

class PublicAsrQuotaException implements Exception {
  const PublicAsrQuotaException(this.message, {this.retryAt});

  final String message;
  final DateTime? retryAt;

  @override
  String toString() => message;
}

/// Local usage protection, not a security boundary against a modified client.
/// Only new submissions reserve duration; polling has no quota operation.
class PublicAsrQuota {
  PublicAsrQuota({
    required Future<Directory> Function() directory,
    DateTime Function()? now,
    this.window = const Duration(hours: 5),
    this.allowance = const Duration(hours: 10),
  }) : _directory = directory,
       _now = now ?? DateTime.now {
    if (window <= Duration.zero || allowance <= Duration.zero) {
      throw ArgumentError('Usage window and allowance must be positive');
    }
  }

  static const recordName = 'public_asr_usage_v1.json';
  static final _operations = SerialTaskQueue();
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final Duration window;
  final Duration allowance;

  Future<void> check({required Duration duration, String? reservationId}) =>
      _access(duration, reservationId, reserve: false);

  Future<void> reserve({
    required Duration duration,
    required String reservationId,
  }) => _access(duration, reservationId, reserve: true);

  Future<void> _access(
    Duration duration,
    String? reservationId, {
    required bool reserve,
  }) async {
    if (duration.inMilliseconds <= 0 ||
        (reservationId != null &&
            (reservationId.isEmpty || reservationId.length > 160)) ||
        (reserve && reservationId == null)) {
      throw ArgumentError(
        'A positive duration and valid reservation are required',
      );
    }
    if (duration > allowance) {
      throw const PublicAsrQuotaException('本段超过公益接口的时长额度，请缩短片段后重试');
    }
    await _operations.enqueue(() async {
      RandomAccessFile? lock;
      var locked = false;
      try {
        final root = await _directory();
        await root.create(recursive: true);
        final file = File(p.join(root.path, recordName));
        lock = await File('${file.path}.lock').open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        locked = true;
        final wallTime = _now().toUtc().millisecondsSinceEpoch;
        final state = await _read(file, initialized: await lock.length() > 0);
        if (wallTime < 0 ||
            wallTime + const Duration(minutes: 2).inMilliseconds < state.seen) {
          throw const PublicAsrQuotaException(
            '系统时间早于公益接口使用记录，请校准时间后重试；已完成片段会保留',
          );
        }
        final current = wallTime < state.seen ? state.seen : wallTime;
        state.seen = current;
        state.entries.removeWhere(
          (entry) => entry.at <= current - window.inMilliseconds,
        );
        final existing = state.entries.where((e) => e.id == reservationId);
        if (existing.isNotEmpty) {
          if (existing.single.duration != duration.inMilliseconds) {
            throw const PublicAsrQuotaException('公益接口片段计量范围不一致，已停止提交');
          }
        } else {
          final used = state.entries.fold<int>(0, (sum, e) => sum + e.duration);
          var excess =
              used + duration.inMilliseconds - allowance.inMilliseconds;
          if (excess > 0) {
            DateTime? retryAt;
            for (final entry in state.entries) {
              excess -= entry.duration;
              if (excess <= 0) {
                retryAt = DateTime.fromMillisecondsSinceEpoch(
                  entry.at + window.inMilliseconds,
                  isUtc: true,
                );
                break;
              }
            }
            final time = retryAt!.toLocal();
            final hour = time.hour.toString().padLeft(2, '0');
            final minute = time.minute.toString().padLeft(2, '0');
            final second = time.second.toString().padLeft(2, '0');
            throw PublicAsrQuotaException(
              '公益接口额度不足：滚动 ${_durationLabel(window)}内最多提交 '
              '${_durationLabel(allowance)}，已提交 '
              '${_durationLabel(Duration(milliseconds: used))}；'
              '最早 ${time.month}月${time.day}日 $hour:$minute:$second 可重试，已完成片段会保留',
              retryAt: retryAt,
            );
          }
          if (reserve) {
            state.entries.add(
              _UsageEntry(reservationId!, current, duration.inMilliseconds),
            );
          }
        }
        await _write(file, state);
        if (await lock.length() == 0) {
          await lock.writeFrom(const [1]);
          await lock.flush();
        }
      } on PublicAsrQuotaException {
        rethrow;
      } catch (_) {
        throw const PublicAsrQuotaException(
          '公益接口使用记录无法安全读取或保存，已暂停提交；请检查存储后重试，原记录不会自动清零',
        );
      } finally {
        if (lock != null) {
          try {
            if (locked) await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      }
    });
  }

  static String _durationLabel(Duration value) {
    final seconds = (value.inMicroseconds / 1000000).ceil();
    return [
      if (seconds >= 3600) '${seconds ~/ 3600}小时',
      if (seconds % 3600 >= 60) '${seconds % 3600 ~/ 60}分',
      if (seconds % 60 != 0 || seconds == 0) '${seconds % 60}秒',
    ].join();
  }

  Future<_UsageState> _read(File file, {required bool initialized}) async {
    if (!await file.exists()) {
      if (initialized) throw const FormatException('Missing usage record');
      return _UsageState(0, []);
    }
    if (await file.length() > 16 * 1024 * 1024) {
      throw const FormatException('Usage record too large');
    }
    final body = jsonDecode(await file.readAsString());
    if (body is! Map || body['state'] is! Map || body['checksum'] is! String) {
      throw const FormatException('Invalid usage record');
    }
    final payload = body['state'] as Map;
    // Detect interrupted writes and accidental edits, not hostile tampering.
    if (sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
            body['checksum'] ||
        payload['version'] != 1 ||
        payload['seen'] is! int ||
        (payload['seen'] as int) < 0 ||
        payload['entries'] is! List) {
      throw const FormatException('Invalid usage state');
    }
    final entries = <_UsageEntry>[];
    final ids = <String>{};
    var last = 0;
    for (final raw in payload['entries'] as List) {
      if (raw is! Map ||
          raw['id'] is! String ||
          (raw['id'] as String).isEmpty ||
          (raw['id'] as String).length > 160 ||
          raw['at'] is! int ||
          raw['duration'] is! int ||
          (raw['duration'] as int) <= 0 ||
          (raw['duration'] as int) > const Duration(days: 1).inMilliseconds ||
          (raw['at'] as int) < last ||
          (raw['at'] as int) > payload['seen'] ||
          !ids.add(raw['id'] as String)) {
        throw const FormatException('Invalid usage entry');
      }
      last = raw['at'] as int;
      entries.add(
        _UsageEntry(raw['id'] as String, last, raw['duration'] as int),
      );
    }
    return _UsageState(payload['seen'] as int, entries);
  }

  Future<void> _write(File file, _UsageState state) async {
    final payload = {
      'version': 1,
      'seen': state.seen,
      'entries': [
        for (final entry in state.entries)
          {'id': entry.id, 'at': entry.at, 'duration': entry.duration},
      ],
    };
    final pending = File('${file.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'state': payload,
        'checksum': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
      }),
      flush: true,
    );
    await pending.rename(file.path);
  }
}

class _UsageState {
  _UsageState(this.seen, this.entries);
  int seen;
  final List<_UsageEntry> entries;
}

class _UsageEntry {
  _UsageEntry(this.id, this.at, this.duration);
  final String id;
  final int at, duration;
}
