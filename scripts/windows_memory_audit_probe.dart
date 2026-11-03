// Independent Windows Release memory diagnostic; never a production entry.
// Uses synthetic local artwork and lyric cues, no library/accounts/models.
// MEMORY_AUDIT_FIXTURES names the prepared fixture directory. Run each artwork
// case in a fresh process: maxRss is a process-lifetime high-water mark.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';

const _fixtures = String.fromEnvironment('MEMORY_AUDIT_FIXTURES');
const _port = int.fromEnvironment('MEMORY_AUDIT_PORT', defaultValue: 8781);
bool _working = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || _fixtures.isEmpty) exit(2);
  SharedPreferences.setMockInitialValues({});
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Isolated Windows memory diagnostic')),
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  await for (final request in server) {
    unawaited(_request(request));
  }
}

Map<String, Object?> _memory() => {
  'rssBytes': ProcessInfo.currentRss,
  'maxRssBytes': ProcessInfo.maxRss,
};

Future<Map<String, Object?>> _artwork(String extension) async {
  final file = File('$_fixtures/animated.$extension');
  final cache = MusicArtworkBackdropCache.instance..clearForTest();
  final before = _memory();
  final watch = Stopwatch()..start();
  final bytes = await cache.warm(file.path);
  final after = _memory();
  watch.stop();
  if (bytes == null) throw StateError('Backdrop generation returned null');
  final output = File('$_fixtures/output-$extension.jpg');
  await output.writeAsBytes(bytes);
  final decoded = image_lib.decodeJpg(bytes);
  return {
    'kind': extension,
    'before': before,
    'afterWarm': after,
    'warmMs': watch.elapsedMilliseconds,
    'jpegSha256': sha256.convert(bytes).toString(),
    'jpegBytes': bytes.length,
    'jpegPath': output.path,
    'width': decoded?.width,
    'height': decoded?.height,
    'cacheHitIsSameBuffer': identical(bytes, cache.peek(file.path)),
    'fixtureBytes': await file.length(),
    'note':
        'maxRss includes the real background compute isolate. Current RSS '
        'can retain allocator pages after otherwise unreachable objects.',
  };
}

SubtitleItem _cue(int cycle, int index, String padding) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index),
  endTime: Duration(seconds: index + 1),
  text: 'track $cycle line $index $padding',
);

Map<String, Object?> _lyricSession(
  MusicLyricSelectionController controller,
  int cycle,
) {
  final padding = List.filled(512, 'x').join();
  final source = SubtitleCueBuffer()
    ..addAll(List.generate(10000, (index) => _cue(cycle, index, padding)));
  controller.begin(
    mediaId: 'synthetic-$cycle',
    primary: source.snapshot,
    secondary: const [],
    splitSubtitleByLine: false,
    mode: MusicLyricTrackDisplayMode.both,
    groupId: 'p:0',
    time: Duration.zero,
    awaitingPointer: false,
  );
  final activeCount = controller.retainedSourceCueCount;
  final selectedText = controller.document.textFor(controller.selection);
  final frozenTextLength = controller.document.fullText.length;
  // A frozen streaming view legitimately owns its source while selecting.
  source.addAll([_cue(cycle, 10000, 'append after snapshot')]);
  controller.noteSource(
    mediaId: 'synthetic-$cycle',
    primary: source.snapshot,
    secondary: const [],
    splitSubtitleByLine: false,
  );
  final activeRemainedFrozen =
      controller.document.fullText.length == frozenTextLength &&
      controller.contentStale;
  final action = switch (cycle % 3) {
    0 => 'finish',
    1 => 'cancel',
    _ => 'source-switch',
  };
  switch (action) {
    case 'finish':
      controller.finish();
    case 'cancel':
      controller.cancel();
    case 'source-switch':
      controller.noteSource(
        mediaId: 'next-$cycle',
        primary: const [],
        secondary: const [],
        splitSubtitleByLine: false,
      );
  }
  return {
    'cycle': cycle,
    'action': action,
    'activeRetainedCues': activeCount,
    'closedRetainedCues': controller.retainedSourceCueCount,
    'activeRemainedFrozen': activeRemainedFrozen,
    'selectedTextSha256': sha256.convert(utf8.encode(selectedText)).toString(),
    'documentEmptyAfterClose': controller.document.isEmpty,
    ..._memory(),
  };
}

Future<Map<String, Object?>> _lyrics() async {
  final controller = MusicLyricSelectionController();
  final before = _memory();
  final rows = <Map<String, Object?>>[];
  for (var cycle = 0; cycle < 6; cycle++) {
    rows.add(_lyricSession(controller, cycle));
    // Let the native UI remain responsive and allow ordinary GC; do not force
    // allocation churn or claim that released VM pages must return to the OS.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final retainedBeforeDispose = controller.retainedSourceCueCount;
  controller.dispose();
  return {
    'kind': 'lyrics',
    'before': before,
    'sessions': rows,
    'retainedBeforeDispose': retainedBeforeDispose,
    'retainedAfterDispose': controller.retainedSourceCueCount,
    'after': _memory(),
    'note':
        'Retained counts diagnose actual source references held by the '
        'controller; RSS is allocator/process memory, not a live-object count.',
  };
}

Future<void> _request(HttpRequest request) async {
  var ownsWork = false;
  try {
    if (request.uri.path == '/close') {
      if (_working) throw StateError('A diagnostic is still running');
      await request.response.close();
      exit(0);
    }
    Map<String, Object?> result;
    if (request.uri.path == '/status') {
      result = {
        'ready': true,
        'working': _working,
        'pid': pid,
        'release': const bool.fromEnvironment('dart.vm.product'),
        'platform': Platform.operatingSystem,
        ..._memory(),
      };
    } else {
      if (_working) throw StateError('A diagnostic is still running');
      _working = ownsWork = true;
      result = switch (request.uri.path) {
        '/artwork/gif' => await _artwork('gif'),
        '/artwork/png' => await _artwork('png'),
        '/artwork/indexed-opaque' => await _artwork('opaque.png'),
        '/artwork/indexed-alpha' => await _artwork('alpha.png'),
        '/lyrics' => await _lyrics(),
        _ => throw StateError('Unknown diagnostic'),
      };
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result));
  } catch (error, stack) {
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.write(jsonEncode({'error': '$error', 'stack': '$stack'}));
  } finally {
    if (ownsWork) _working = false;
    await request.response.close();
  }
}
