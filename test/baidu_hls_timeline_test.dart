import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/baidu_hls_timeline.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';

import 'cloud_drive_gateway_test.dart' show sample;

String playlist(Uri base) =>
    '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
    '#EXT-X-DISCONTINUITY\n#EXTINF:2,\n${base.resolve('/clip_1_ts/0.mp4')}\n'
    '#EXT-X-DISCONTINUITY\n#EXTINF:2,\n${base.resolve('/clip_1_ts/1.mp4')}\n'
    '#EXT-X-ENDLIST\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only complete independent MP4 playlists use a lazy local timeline', () {
    final base = Uri.parse('https://v2-ant.baidu.com/video.m3u8');
    var id = 0;
    final text = playlist(base);
    String localize(Uri uri) => 'http://127.0.0.1:1234/cd/token/h/${id++}.mp4';
    final result = baiduIndependentMp4Timeline(
      text,
      base,
      localize,
      verifiedMp4: true,
    )!;
    expect(
      baiduIndependentMp4Timeline(text, base, localize, verifiedMp4: false),
      isNull,
    );
    expect(result, startsWith('# mpv EDL v0\n'));
    expect(result, contains('!delay_open,media_type=video'));
    expect(result, contains('!delay_open,media_type=audio'));
    expect(result, isNot(contains('v2-ant.baidu.com')));
    expect(result.split('\n').where((s) => s.startsWith('%')), hasLength(2));
    for (final unsupported in [
      text.replaceAll('#EXT-X-ENDLIST', ''),
      text.replaceAll('#EXT-X-DISCONTINUITY\n', ''),
      text.replaceFirst('#EXTINF:2,', '#EXTINF:0,'),
      text.replaceFirst(
        '#EXTINF:2,',
        '#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:2,',
      ),
      text.replaceFirst('#EXTINF:2,', '#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,'),
    ]) {
      expect(
        baiduIndependentMp4Timeline(
          unsupported,
          base,
          localize,
          verifiedMp4: true,
        ),
        isNull,
      );
    }
  });

  final ffmpeg = p.absolute('assets/binaries/windows/ffmpeg.exe');
  final mpv = p.absolute('build/windows/x64/runner/Release/libmpv-2.dll');
  final available =
      Platform.isWindows && File(ffmpeg).existsSync() && File(mpv).existsSync();
  test(
    'native seeks and crosses independent HEVC MP4 segments without opening the whole video',
    () async {
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('baidu_mp4_timeline');
      final file = File(p.join(root.path, 'clip.mp4'));
      final generated = await Process.run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x180:rate=12',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=44100',
        '-t',
        '2',
        '-c:v',
        'libx265',
        '-preset',
        'ultrafast',
        '-x265-params',
        'log-level=error:pools=1',
        '-c:a',
        'aac',
        '-movflags',
        '+faststart',
        file.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final bytes = await file.readAsBytes();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final reads = <String>[];
      origin.listen((request) async {
        reads.add(
          '${request.uri.path} ${request.headers.value('range') ?? ''}',
        );
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = range == null || range[2]!.isEmpty
            ? bytes.length - 1
            : int.parse(range[2]!);
        request.response.statusCode = range == null ? 200 : 206;
        request.response.headers.contentType = ContentType('video', 'mp4');
        if (range != null) {
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${origin.port}/video.m3u8');
      final gateway = CloudDriveStreamGateway();
      final lease = await gateway.open(
        descriptor: sample(uri: uri, transport: CloudDriveTransport.hls)
            .copyWith(
              manifest: CloudDriveManifestSnapshot(
                text: playlist(uri),
                baseUri: uri,
                fetchedAt: DateTime.now(),
              ),
            ),
        accountLocalId: 'local-hevc',
      );
      MediaKit.ensureInitialized(libmpv: mpv);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      try {
        await player.setVolume(0);
        await player.setVideoTrack(VideoTrack.auto());
        await native.setProperty('start', '2.4');
        await player.open(
          Media(
            lease.loopbackUri.toString(),
            httpHeaders: {cloudDriveNativeTimelineHeader: '1'},
          ),
          play: true,
        );
        final playbackDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (player.state.position.inMilliseconds <= 2500 &&
            DateTime.now().isBefore(playbackDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await native.getProperty('video-dec-params/w'), '320');
        expect(player.state.position.inMilliseconds, greaterThan(2500));
        expect(
          reads.where(
            (r) =>
                r.startsWith('/clip_1_ts/0.mp4') && !r.endsWith('bytes=0-15'),
          ),
          isEmpty,
          reason: 'Non-zero starts may only inspect the first segment prefix',
        );
        await player.seek(const Duration(milliseconds: 1700));
        await player.play();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(player.state.position.inMilliseconds, greaterThan(2100));
        expect(
          reads.any(
            (r) =>
                r.startsWith('/clip_1_ts/0.mp4') && !r.endsWith('bytes=0-15'),
          ),
          isTrue,
        );
        expect(await native.getProperty('video-dec-params/w'), '320');
        expect(player.state.duration, const Duration(seconds: 4));
      } finally {
        await player.dispose();
        await lease.release();
        await gateway.close();
        await origin.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: available ? false : 'Requires bundled Windows ffmpeg/libmpv',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
