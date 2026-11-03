import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/debug/debug_log_buffer.dart';
import 'package:video_player_app/debug/developer_log.dart' as app_log;
import 'package:video_player_app/debug/log_redaction.dart';

void main() {
  test('request credentials are masked in headers, query strings and JSON', () {
    const raw =
        'Authorization: Bearer fake-bearer\nProxy-Authorization: Basic fake-basic\napiKey=fake-key&SESSDATA=fake-cookie {"api_key":"fake-json"}';
    final masked = redactSensitiveLogText(raw);
    expect(masked, isNot(contains('fake-')));
    expect(masked, contains('Bearer ***'));
    expect(redactSensitiveLogText(masked), masked);
  });
  final DebugLogBuffer buffer = DebugLogBuffer.instance;

  setUp(buffer.clear);

  test('identical lines collapse into one entry', () {
    buffer.add('hello');
    buffer.add('hello');

    expect(buffer.entries, hasLength(1));
    expect(buffer.entries.single.text, 'hello');
    expect(buffer.entries.single.display, 'hello ×2');
  });

  test('lines that differ only by numbers collapse', () {
    buffer.add('滚动增量: 1.5');
    buffer.add('当前音量: 0.2');
    buffer.add('滚动增量: 12');

    expect(buffer.entries, hasLength(2));
    expect(buffer.entries.first.text, '滚动增量: 12');
    expect(buffer.entries.first.count, 2);
    expect(buffer.entries.first.display, '滚动增量: 12 ×2');
  });

  test('widget tree dumps collapse to one summary line', () {
    buffer.add(_overflowDump(24));
    buffer.add(_overflowDump(30));

    expect(buffer.entries, hasLength(1));
    expect(
      buffer.entries.single.text,
      'A RenderFlex overflowed by 30 pixels on the bottom.',
    );
    expect(buffer.entries.single.count, 2);
    expect(buffer.displayText, isNot(contains('DebugLogOverlay')));
    expect(buffer.displayText, isNot(contains('EXCEPTION CAUGHT')));
    expect(buffer.displayText, isNot(contains('widget tree')));
  });

  test('stacks that start in the debug ball are dropped', () {
    buffer.add('kept');
    buffer.add('''
boom
#0      DebugLogOverlay.build (package:video_player_app/debug/debug_log_overlay.dart:10:3)
#1      Element.rebuild (package:flutter/src/widgets/framework.dart:1:1)
''');
    buffer.add('''
══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞══
The following assertion was thrown building DebugLogOverlay:
setState() called during build.
#0      DebugLogBuffer.add (package:video_player_app/debug/debug_log_buffer.dart:10:3)
''');

    expect(buffer.entries, hasLength(1));
    expect(buffer.entries.single.text, 'kept');
  });

  test('a dump that only mentions the ball as an ancestor is kept', () {
    buffer.add(_overflowDump(8));

    expect(buffer.entries, hasLength(1));
    expect(
      buffer.entries.single.text,
      'A RenderFlex overflowed by 8 pixels on the bottom.',
    );
  });

  test('parser traces collapse instead of filling the page', () {
    buffer.add('[Parser] Tag: field=1, wireType=2');
    buffer.add('[Parser] Found field 2, bytes: 40');
    buffer.add('Library loaded');
    buffer.add('[Parser] Success! Added subtitle: zh');

    expect(buffer.entries, hasLength(2));
    expect(buffer.entries.first.text, contains('[Parser]'));
    expect(buffer.entries.first.count, 3);
    expect(buffer.entries.last.text, 'Library loaded');
  });

  test('developer log is copied into the buffer', () {
    app_log.log('Error fetching video info', error: StateError('offline'));

    expect(buffer.entries, hasLength(1));
    expect(buffer.entries.single.text, contains('Error fetching video info'));
    expect(buffer.entries.single.text, contains('offline'));
  });

  test('the ring buffer drops the oldest entry past the cap', () {
    for (var i = 0; i < DebugLogBuffer.maxEntries + 1; i++) {
      buffer.add('row ${_letters(i)} end');
    }

    expect(buffer.entries, hasLength(DebugLogBuffer.maxEntries));
    expect(buffer.entries.first.text, 'row ${_letters(1)} end');
    expect(
      buffer.entries.last.text,
      'row ${_letters(DebugLogBuffer.maxEntries)} end',
    );
  });
}

String _overflowDump(int pixels) {
  return '''
══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞════════════════════════
The following assertion was thrown during layout:
A RenderFlex overflowed by $pixels pixels on the bottom.

The relevant error-causing widget was:
  Column

When the exception was thrown, this was the stack:
#0      RenderFlex.performLayout (package:flutter/src/rendering/flex.dart:1:1)
#1      DebugLogOverlay.build (package:video_player_app/debug/debug_log_overlay.dart:20:1)

The widget tree was:
  DebugLogOverlay
    Home
◢◤◢◤◢◤
''';
}

String _letters(int n) {
  var current = n;
  final codes = <int>[];
  do {
    codes.add(97 + current % 26);
    current ~/= 26;
  } while (current > 0);
  return String.fromCharCodes(codes.reversed);
}
