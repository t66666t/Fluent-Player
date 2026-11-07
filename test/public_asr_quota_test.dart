import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/public_asr_quota.dart';

void main() {
  late Directory root;
  late DateTime now;
  PublicAsrQuota quota() =>
      PublicAsrQuota(directory: () async => root, now: () => now);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('public-asr-quota-');
    now = DateTime.utc(2026, 11, 6);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'rolling five-hour window admits ten hours and releases only expired use',
    () async {
      await quota().reserve(
        duration: const Duration(hours: 6),
        reservationId: 'first',
      );
      now = now.add(const Duration(hours: 2));
      await quota().reserve(
        duration: const Duration(hours: 4),
        reservationId: 'second',
      );
      await expectLater(
        quota().check(duration: const Duration(hours: 1)),
        throwsA(
          isA<PublicAsrQuotaException>().having(
            (e) => e.retryAt,
            'earliest release',
            DateTime.utc(2026, 11, 6, 5),
          ),
        ),
      );
      await expectLater(
        quota().check(duration: const Duration(hours: 7)),
        throwsA(
          isA<PublicAsrQuotaException>().having(
            (e) => e.retryAt,
            'a larger submission needs both releases',
            DateTime.utc(2026, 11, 6, 7),
          ),
        ),
      );
      now = DateTime.utc(2026, 11, 6, 5);
      await quota().reserve(
        duration: const Duration(hours: 6),
        reservationId: 'third',
      );
      await expectLater(
        quota().check(duration: const Duration(hours: 1)),
        throwsA(
          isA<PublicAsrQuotaException>().having(
            (e) => e.retryAt,
            'second release',
            DateTime.utc(2026, 11, 6, 7),
          ),
        ),
      );
    },
  );

  test('preflight checks do not spend duration', () async {
    for (var i = 0; i < 3; i++) {
      await quota().check(duration: const Duration(hours: 10));
    }
    await quota().reserve(
      duration: const Duration(hours: 10),
      reservationId: 'whole',
    );
    await expectLater(
      quota().check(duration: const Duration(milliseconds: 1)),
      throwsA(isA<PublicAsrQuotaException>()),
    );
  });

  test(
    'a saved reservation survives restart and retries without a second charge',
    () async {
      await quota().reserve(
        duration: const Duration(hours: 10),
        reservationId: 'pending',
      );
      final checkpoint = GongyiAsrTaskCheckpoint(usageReservationId: 'pending');
      final restored = GongyiAsrTaskCheckpoint.fromJson(
        jsonDecode(jsonEncode(checkpoint.toJson())) as Map,
      );
      await quota().reserve(
        duration: const Duration(hours: 10),
        reservationId: restored.usageReservationId!,
      );
      await quota().check(
        duration: const Duration(hours: 10),
        reservationId: restored.usageReservationId,
      );
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
      await expectLater(
        quota().reserve(
          duration: const Duration(hours: 9),
          reservationId: 'pending',
        ),
        throwsA(isA<PublicAsrQuotaException>()),
      );
    },
  );

  test(
    'only a definitively finished or missing task releases its reservation identity',
    () async {
      final checkpoint = GongyiAsrTaskCheckpoint(
        usageReservationId: 'original',
      );
      await checkpoint.setTask('server-task');
      expect(checkpoint.usageReservationId, 'original');
      await checkpoint.setTask(null);
      expect(checkpoint.usageReservationId, isNull);
      expect(GongyiAsrTaskCheckpoint.fromJson({'taskId': 'legacy'}).toJson(), {
        'taskId': 'legacy',
      });
    },
  );

  test(
    'concurrent instances cannot reserve beyond the shared local allowance',
    () async {
      Future<bool> submit(String id) async {
        try {
          await quota().reserve(
            duration: const Duration(hours: 7),
            reservationId: id,
          );
          return true;
        } on PublicAsrQuotaException {
          return false;
        }
      }

      final results = await Future.wait([submit('left'), submit('right')]);
      expect(results.where((ok) => ok), hasLength(1));
      await quota().reserve(
        duration: const Duration(hours: 3),
        reservationId: 'tail',
      );
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
    },
  );

  test(
    'damaged or deleted initialized records never silently reset the allowance',
    () async {
      await quota().reserve(
        duration: const Duration(hours: 10),
        reservationId: 'used',
      );
      final file = File(p.join(root.path, PublicAsrQuota.recordName));
      final original = await file.readAsString();
      await file.writeAsString('{broken');
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
      expect(await file.readAsString(), '{broken');
      await file.writeAsString(original);
      final modified = jsonDecode(original) as Map;
      (modified['state'] as Map)['entries'] = [];
      await file.writeAsString(jsonEncode(modified));
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
      await file.delete();
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
    },
  );

  test(
    'a substantial clock rollback is refused and small corrections do not free time',
    () async {
      await quota().reserve(
        duration: const Duration(hours: 10),
        reservationId: 'used',
      );
      now = now.subtract(const Duration(seconds: 30));
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(
          isA<PublicAsrQuotaException>().having(
            (e) => e.retryAt,
            'still full',
            isNotNull,
          ),
        ),
      );
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        quota().check(duration: const Duration(seconds: 1)),
        throwsA(
          isA<PublicAsrQuotaException>().having(
            (e) => e.message,
            'clock diagnostic',
            contains('系统时间'),
          ),
        ),
      );
    },
  );

  test('independent app data roots retain independent usage records', () async {
    await quota().reserve(
      duration: const Duration(hours: 10),
      reservationId: 'used',
    );
    final other = PublicAsrQuota(
      directory: () async => Directory(p.join(root.path, 'other')),
      now: () => now,
    );
    await other.reserve(
      duration: const Duration(hours: 10),
      reservationId: 'used',
    );
  });

  test(
    'two processes serialize quota reservations through the file lock',
    () async {
      final script = File(p.join(root.path, 'reserve.dart'));
      final module = File(
        'lib/services/public_asr_quota.dart',
      ).absolute.uri.toString();
      await script.writeAsString('''
import 'dart:io';
import '$module';
Future<void> main(List<String> args) async {
  final quota = PublicAsrQuota(directory: () async => Directory(args[0]),
      now: () => DateTime.utc(2026, 11, 6));
  try {
    await quota.reserve(duration: const Duration(hours: 7), reservationId: args[1]);
  } on PublicAsrQuotaException {
    exitCode = 2;
  }
}
''');
      final packageConfig = File(
        '.dart_tool/package_config.json',
      ).absolute.path;
      Future<ProcessResult> run(String id) => Process.run('dart', [
        '--packages=$packageConfig',
        script.path,
        root.path,
        id,
      ], runInShell: Platform.isWindows);
      final results = await Future.wait([run('left'), run('right')]);
      expect(
        results.map((r) => r.exitCode).toList()..sort(),
        [0, 2],
        reason: results.map((r) => '${r.stdout}\n${r.stderr}').join('\n'),
      );
      await quota().check(duration: const Duration(hours: 3));
      await expectLater(
        quota().check(duration: const Duration(hours: 4)),
        throwsA(isA<PublicAsrQuotaException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
