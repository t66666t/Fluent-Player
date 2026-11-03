// Opt-in live probe of the production upload/recognition pipeline.
// GONGYI_AUDIO_PROBE_FILE=<synthetic audio> flutter test tool/gongyi_audio_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';

void main() {
  test(
    'recognizes an audio file without extracting or transcoding it',
    () async {
      HttpOverrides.global = null;
      final path = Platform.environment['GONGYI_AUDIO_PROBE_FILE'];
      expect(
        path,
        isNotNull,
        reason: 'Set GONGYI_AUDIO_PROBE_FILE explicitly.',
      );
      final file = File(path!);
      final dio = Dio(
        BaseOptions(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/120.0.0.0 Safari/537.36',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(minutes: 2),
        ),
      );
      addTearDown(() => dio.close(force: true));
      final clock = Stopwatch()..start();
      final events = <Map<String, Object?>>[];
      var lastUploadPercent = -10;
      final report = <String, Object?>{
        'file': file.uri.pathSegments.last,
        'bytes': await file.length(),
        'events': events,
      };
      try {
        final subtitles =
            await GongyiAsrService(
              dio: dio,
              maxPollRiskWaits: 0,
              uploadRetryDelays: const [],
              resultQueryTimeout: const Duration(minutes: 2),
            ).transcribeAudio(
              path,
              onProgress: (_, message) {
                final match = RegExp(r'^上传音频 (\d+)%').firstMatch(message);
                if (match != null) {
                  final percent = int.parse(match[1]!);
                  if (percent < 100 && percent - lastUploadPercent < 10) return;
                  lastUploadPercent = percent;
                }
                events.add({
                  'ms': clock.elapsedMilliseconds,
                  'message': message,
                });
                // ignore: avoid_print
                print('[audio-probe] ${clock.elapsedMilliseconds}ms $message');
              },
            );
        report['success'] = true;
        report['cues'] = subtitles.length;
        report['text'] = subtitles.map((cue) => cue.text).join(' ');
        expect(subtitles, isNotEmpty);
        expect(subtitles.any((cue) => cue.text.contains('音频')), isTrue);
      } catch (error) {
        report['success'] = false;
        report['error'] = error.toString();
        if (error is GongyiAsrException) report['kind'] = error.kind.name;
        rethrow;
      } finally {
        report['elapsedMs'] = clock.elapsedMilliseconds;
        final output = Platform.environment['GONGYI_AUDIO_PROBE_REPORT'];
        if (output != null) {
          await File(
            output,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        }
        // ignore: avoid_print
        print(
          '[audio-probe] ${jsonEncode({...report, 'events': events.length, if (report['text'] case final String text) 'text': text.length > 150 ? '${text.substring(0, 150)}…' : text})}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
