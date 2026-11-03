// ignore_for_file: avoid_print

import 'package:video_player_app/utils/clipboard_link.dart';

// Offline, no clipboard access or network. Run explicitly with:
// dart run tool/benchmark_clipboard_links.dart
void main() {
  final inputs = <String, String>{
    'share':
        r'8.46 复制打开抖音，看看作品 https\://v.douyin.com/OnCdbJYwbOw/ k@P.XM 11/06',
    '100K prose': '${'生活继续，明天再见。' * 10000} https://v.douyin.com/whHBSfP9sow/',
    'bracket noise': '${'[' * 100000} https://example.com/watch',
    '32 URLs': List.generate(
      32,
      (i) => 'https://example.com/$i?sig=A%2bB%3d&t=30',
    ).join('\n'),
  };
  for (final entry in inputs.entries) {
    for (var i = 0; i < 100; i++) {
      ClipboardLinkDetector.detect(entry.value);
    }
    final times = <int>[];
    for (var i = 0; i < 300; i++) {
      final clock = Stopwatch()..start();
      ClipboardLinkDetector.detect(entry.value);
      times.add(clock.elapsedMicroseconds);
    }
    times.sort();
    print(
      '${entry.key} (${entry.value.length} chars): median ${times[150]} us, p95 ${times[285]} us',
    );
  }
}
