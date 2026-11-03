import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/player_panel_history.dart';

void main() {
  for (final base in ['none', 'subtitles', 'bilibili']) {
    test('$base: nested tools return through their full source path', () {
      final history = PlayerPanelHistory<String>();
      var shown = base;
      for (final tool in ['compose', 'manager', 'transcription']) {
        history.open(current: shown, target: tool);
        shown = tool;
      }
      expect(history.pop(fallback: 'wrong'), 'manager');
      expect(history.pop(fallback: 'wrong'), 'compose');
      expect(history.pop(fallback: 'wrong'), base);
      expect(history.pop(fallback: 'default'), 'default');
    });
  }

  test('opening the same tool cannot add itself to the return path', () {
    final history = PlayerPanelHistory<String>();
    history.open(current: 'details', target: 'settings');
    for (var i = 0; i < 5; i++) {
      history.open(current: 'settings', target: 'settings');
    }
    expect(history.panels, ['details']);
    expect(history.pop(fallback: 'wrong'), 'details');
  });

  test('switching to an ancestor rewinds rather than creating a cycle', () {
    final history = PlayerPanelHistory<String>();
    history.open(current: 'details', target: 'settings');
    history.open(current: 'settings', target: 'style');
    history.open(current: 'style', target: 'manager');
    history.open(current: 'manager', target: 'settings');
    expect(history.panels, ['details']);
    expect(history.pop(fallback: 'wrong'), 'details');
  });

  test('layout changes update every return destination', () {
    final history = PlayerPanelHistory<String>();
    history.open(current: 'bilibili', target: 'compose');
    history.open(current: 'compose', target: 'manager');
    history.remap((panel) => panel == 'bilibili' ? 'none' : panel);
    expect(history.pop(fallback: 'wrong'), 'compose');
    expect(history.pop(fallback: 'wrong'), 'none');
  });

  test('an explicit base selection discards pending tool returns', () {
    final history = PlayerPanelHistory<String>();
    history.open(current: 'details', target: 'settings');
    history.clear();
    expect(history.pop(fallback: 'subtitles'), 'subtitles');
  });

  test('layout remapping cannot create a self-return or a history cycle', () {
    final history = PlayerPanelHistory<String>();
    history.open(current: 'subtitles', target: 'settings');
    history.open(current: 'settings', target: 'bilibili');
    history.open(current: 'bilibili', target: 'manager');
    history.remap((panel) => panel == 'bilibili' ? 'subtitles' : panel);
    expect(history.panels, ['subtitles']);
    history.discardCurrent('subtitles');
    expect(history.pop(fallback: 'none'), 'none');
  });
}
