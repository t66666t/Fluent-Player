import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/services/subtitle_position_store.dart';

class _FakeBackend implements SubtitlePositionBackend {
  final Map<String, String> strings = <String, String>{};
  final Map<String, double> doubles = <String, double>{};
  Completer<void>? gate;
  bool failNext = false;
  int writes = 0;

  @override
  String? getString(String key) => strings[key];

  @override
  double? getDouble(String key) => doubles[key];

  @override
  Future<bool> setString(String key, String value) => _write(() {
    strings[key] = value;
  });

  @override
  Future<bool> setDouble(String key, double value) => _write(() {
    doubles[key] = value;
  });

  Future<bool> _write(void Function() apply) async {
    writes++;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    if (failNext) {
      failNext = false;
      return false;
    }
    apply();
    return true;
  }
}

void main() {
  test('legacy alignment keys load and a missing override key stays empty', () {
    final _FakeBackend backend = _FakeBackend()
      ..strings['subtitleAlignmentJson'] = '{"x": -0.2, "y": 0.4}'
      ..doubles['audioSubtitleAlignX'] = 0.1
      ..doubles['audioSubtitleAlignY'] = 0.2;
    final SubtitlePositionStore store = SubtitlePositionStore(backend)..load();
    expect(store.videoOverride('清幕标准'), isNull);
    expect(store.exportOverrides()['presetOverrides'], isEmpty);
    store.dispose();
  });

  test('preset video and audio overrides do not clobber each other', () async {
    final _FakeBackend backend = _FakeBackend();
    final SubtitlePositionStore store = SubtitlePositionStore(backend)..load();
    await store.commitPreset(
      presetId: '清幕标准',
      audio: false,
      alignment: const Alignment(-0.2, 0.5),
    );
    await store.commitPreset(
      presetId: '清幕标准',
      audio: true,
      alignment: const Alignment(0.1, 0.3),
    );
    await store.commitPreset(
      presetId: '银幕经典',
      audio: false,
      alignment: const Alignment(0.4, -0.2),
    );
    final SubtitlePositionStore reloaded = SubtitlePositionStore(backend)
      ..load();
    expect(reloaded.videoOverride('清幕标准'), const Alignment(-0.2, 0.5));
    expect(reloaded.audioOverride('清幕标准'), const Alignment(0.1, 0.3));
    expect(reloaded.videoOverride('银幕经典'), const Alignment(0.4, -0.2));
    expect(reloaded.audioOverride('银幕经典'), isNull);
    store.dispose();
    reloaded.dispose();
  });

  test('a slow write keeps the newest coalesced value', () async {
    final _FakeBackend backend = _FakeBackend();
    final Completer<void> gate = Completer<void>();
    backend.gate = gate;
    final SubtitlePositionStore store = SubtitlePositionStore(backend)..load();
    final Future<PositionCommitResult> first = store.commitAlignment(
      channel: SubtitlePositionChannel.video,
      alignment: const Alignment(0.1, 0.1),
      current: Alignment.center,
    );
    await Future<void>.delayed(Duration.zero);
    backend.gate = null;
    final Future<PositionCommitResult> second = store.commitAlignment(
      channel: SubtitlePositionChannel.video,
      alignment: const Alignment(0.2, 0.2),
      current: const Alignment(0.1, 0.1),
    );
    final Future<PositionCommitResult> third = store.commitAlignment(
      channel: SubtitlePositionChannel.video,
      alignment: const Alignment(-0.4, 0.8),
      current: const Alignment(0.2, 0.2),
    );
    gate.complete();
    final List<PositionCommitResult> results = await Future.wait([
      first,
      second,
      third,
      store.flush(),
    ]);
    expect(results.every((PositionCommitResult result) => result.ok), isTrue);
    final SubtitlePositionStore reloaded = SubtitlePositionStore(backend)
      ..load();
    expect(backend.strings['subtitleAlignmentJson'], contains('-0.4'));
    expect(backend.doubles['subtitleAlignY'], 0.8);
    reloaded.dispose();
    store.dispose();
  });

  test('a failed write stays dirty and the next commit can succeed', () async {
    final _FakeBackend backend = _FakeBackend()..failNext = true;
    final SubtitlePositionStore store = SubtitlePositionStore(backend)..load();
    final PositionCommitResult failed = await store.commitAlignment(
      channel: SubtitlePositionChannel.audio,
      alignment: const Alignment(0.3, 0.3),
      current: Alignment.center,
    );
    expect(failed.ok, isFalse);
    expect(store.lastError, isNull);
    final PositionCommitResult flushed = await store.flush();
    expect(flushed.ok, isTrue);
    expect(backend.strings['audioSubtitleAlignmentJson'], contains('0.3'));
    store.dispose();
  });

  test('damaged entries and a newer document do not wipe the rest', () async {
    final _FakeBackend backend = _FakeBackend()
      ..strings[kSubtitlePositionOverridesKey] = '''
{
  "version": 1,
  "presetOverrides": {
    "清幕标准": {"video": {"x": 0.2, "y": 0.2}, "audio": {"x": "bad"}},
    "银幕经典": {"video": {"x": 9, "y": 0}},
    "清幕轻映": {"audio": {"x": -0.5, "y": 0.25}}
  }
}
''';
    final SubtitlePositionStore store = SubtitlePositionStore(backend)..load();
    expect(store.videoOverride('清幕标准'), const Alignment(0.2, 0.2));
    expect(store.audioOverride('清幕标准'), isNull);
    expect(store.videoOverride('银幕经典'), isNull);
    expect(store.audioOverride('清幕轻映'), const Alignment(-0.5, 0.25));
    backend.strings[kSubtitlePositionOverridesKey] =
        '{"version": 9, "presetOverrides": {"清幕标准": {"video": {"x": 1, "y": 1}}}}';
    store.load();
    expect(store.overridesBlocked, isTrue);
    final PositionCommitResult refused = await store.commitPreset(
      presetId: '清幕标准',
      audio: false,
      alignment: Alignment.center,
    );
    expect(refused.ok, isFalse);
    expect(backend.strings[kSubtitlePositionOverridesKey], contains('"version": 9'));
    store.dispose();
  });
}
