import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_models.dart';

SyncProgressEvent _event(
  String id,
  Map<String, int> clock, {
  int position = 1000,
  int wallTime = 1,
  bool completed = false,
}) => SyncProgressEvent(
  id: id,
  groupId: 'folder-group',
  mediaKey: 'same-content',
  title: '第 1 集',
  deviceId: clock.keys.last,
  deviceName: clock.keys.last,
  clock: clock,
  value: SyncProgressValue(
    positionMs: position,
    completed: completed,
    continueEnrolled: true,
    lastPlayedAtMs: wallTime,
    watchMs: 100,
  ),
  createdAtMs: wallTime,
);

void main() {
  test(
    'rewatching backwards replaces its causal predecessor regardless of clock time',
    () {
      final finished = _event(
        'finished',
        {'desktop': 1},
        position: 90000,
        wallTime: 9000,
        completed: true,
      );
      final rewatch = _event(
        'rewatch',
        {'desktop': 2},
        position: 3000,
        wallTime: 1,
      );
      expect(syncProgressHeads([finished, rewatch]), [rewatch]);
      expect(rewatch.descendsFrom(finished), isTrue);
      expect(finished.descendsFrom(rewatch), isFalse);
    },
  );

  test(
    'independent offline watches remain choices even if one position is further',
    () {
      final desktop = _event(
        'desktop',
        {'desktop': 1},
        position: 9000,
        wallTime: 100000,
      );
      final phone = _event('phone', {'phone': 1}, position: 1000, wallTime: 10);
      expect(syncProgressHeads([desktop, phone]), [desktop, phone]);
      expect(desktop.descendsFrom(phone), isFalse);
      expect(phone.descendsFrom(desktop), isFalse);
    },
  );

  test(
    'an edit follows only its accepted branch and preserves the concurrent watch',
    () {
      final base = _event('base', {'desktop': 1});
      final phone = _event('phone', {'desktop': 1, 'phone': 1}, position: 2000);
      final desktop = _event('desktop', {'desktop': 2}, position: 3000);
      final laterDesktop = _event('later-desktop', {
        'desktop': 3,
      }, position: 4000);
      expect(syncProgressHeads([base, phone, desktop, laterDesktop]), [
        laterDesktop,
        phone,
      ]);
    },
  );

  test(
    'explicit choice joins both causal histories and retires the conflict',
    () {
      final desktop = _event('desktop', {'desktop': 3}, position: 4000);
      final phone = _event('phone', {'desktop': 1, 'phone': 2}, position: 1000);
      final resolved = _event('resolved', {
        'desktop': 4,
        'phone': 2,
      }, position: 1000);
      expect(syncProgressHeads([phone, desktop, resolved]), [resolved]);
    },
  );

  test('compacted head rejects stale events replayed by an offline device', () {
    final oldDesktop = _event('old-desktop', {'desktop': 1});
    final oldPhone = _event('old-phone', {'desktop': 1, 'phone': 1});
    final compacted = _event('current', {'desktop': 8, 'phone': 5});
    expect(syncProgressHeads([compacted, oldPhone, oldDesktop]), [compacted]);
  });

  test('merge is idempotent and independent of network arrival order', () {
    final a = _event('a', {'desktop': 1});
    final b = _event('b', {'desktop': 2});
    final c = _event('c', {'desktop': 1, 'phone': 1});
    final expected = [b, c];
    for (final order in [
      [a, b, c],
      [c, b, a],
      [b, a, c],
      [a, a, c, b, b],
    ]) {
      expect(syncProgressHeads(order), expected);
    }
  });

  test('equal positions do not destroy independent causal histories', () {
    final a = _event('a', {'desktop': 1});
    final b = _event('b', {'phone': 1});
    expect(syncProgressHeads([a, b]), [a, b]);
  });

  test(
    'round-trip keeps the full clock required after remote log compaction',
    () {
      final event = _event('current', {
        'desktop': 100,
        'phone': 90,
      }, position: 0);
      final restored = SyncProgressEvent.fromJson(event.toJson());
      expect(restored.clock, {'desktop': 100, 'phone': 90});
      expect(restored.value.positionMs, 0);
      expect(
        restored.descendsFrom(_event('old', {'desktop': 1, 'phone': 2})),
        isTrue,
      );
    },
  );
}
