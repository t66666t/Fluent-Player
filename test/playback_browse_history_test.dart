import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_browse_history.dart';

VideoItem item(String id, {String? bvid, int page = 1}) => VideoItem(
  id: id,
  path: bvid == null ? '/$id.mp4' : 'bilibili://stream/$bvid',
  title: id,
  durationMs: 600000,
  lastUpdated: 0,
  sourceRef: bvid == null
      ? null
      : MediaSourceRef(
          kind: MediaSourceKind.bilibiliStream,
          value: bvid,
          bvid: bvid,
          page: page,
        ),
);

PlaybackBrowseEntry visit(VideoItem media, {bool playing = false}) =>
    PlaybackBrowseEntry(
      item: media,
      position: const Duration(seconds: 42),
      wasPlaying: playing,
      queue: [media],
    );

void main() {
  test('links return C → B → A with each original resume point', () {
    final history = PlaybackBrowseHistory();
    final a = item('a');
    final b = item('b');
    final c = item('c');
    final aVisit = visit(a);
    final bVisit = visit(b, playing: true);
    history.record(origin: aVisit, target: b);
    history.record(origin: bVisit, target: c);
    expect(history.previousFor(c), same(bVisit));
    expect(history.itemIds, {'a', 'b'});
    history.returned(bVisit);
    expect(history.previousFor(b), same(aVisit));
    expect(aVisit.position, const Duration(seconds: 42));
    expect(aVisit.wasPlaying, isFalse);
    history.returned(aVisit);
    expect(history.previousFor(a), isNull);
    expect(history.itemIds, isEmpty);
  });

  test('switching parts preserves the origin without creating a visit', () {
    final history = PlaybackBrowseHistory();
    final a = item('a');
    final b = item('b-p1', bvid: 'BV1aa411c7mA');
    final b2 = item('b-p2', bvid: 'BV1aa411c7mA', page: 2);
    final origin = visit(a);
    history.record(origin: origin, target: b);
    expect(history.previousFor(b2), same(origin));
    expect(history.previousFor(item('unrelated')), isNull);
  });

  test('a cancelled or failed link does not mutate the committed history', () {
    final history = PlaybackBrowseHistory();
    final a = item('a');
    final b = item('b');
    history.record(origin: visit(a), target: b);
    // Capturing a pending visit is deliberately separate from committing it.
    visit(b);
    expect(history.previousFor(b)?.item, same(a));
    expect(history.itemIds, {'a'});
  });

  test('unrelated playback starts a new chain and the history is bounded', () {
    final history = PlaybackBrowseHistory(capacity: 2);
    final a = item('a');
    final b = item('b');
    final c = item('c');
    final d = item('d');
    final x = item('x');
    final y = item('y');
    history.record(origin: visit(a), target: b);
    history.record(origin: visit(b), target: c);
    history.record(origin: visit(c), target: d);
    expect(history.itemIds, {'b', 'c'});
    history.record(origin: visit(x), target: y);
    expect(history.itemIds, {'x'});
    history.clear();
    expect(history.previousFor(y), isNull);
  });
}
