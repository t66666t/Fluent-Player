import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_quality_switch.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_resume.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_session_recovery.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_text.dart';
import 'package:video_player_app/features/cloud_drive/services/seek_preview_policy.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_stream_gateway.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

class _RecordingCloudNetwork extends NetworkHttp {
  _RecordingCloudNetwork(NetworkSettingsService settings)
    : super(settings: settings);
  final scopes = <NetworkScope>[];
  @override
  HttpClient createClient({
    NetworkScope scope = NetworkScope.other,
    Uri? source,
    RequestNetworkContext? context,
    NetworkMode? modeOverride,
    bool cancelOnChange = true,
    SecurityContext? securityContext,
  }) {
    scopes.add(scope);
    return super.createClient(
      scope: scope,
      source: source,
      context: context,
      modeOverride: modeOverride,
      cancelOnChange: cancelOnChange,
      securityContext: securityContext,
    );
  }
}

void main() {
  test(
    'API and media gateway use the independent cloud network route',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.write('{}');
        request.response.close();
      });
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final network = _RecordingCloudNetwork(settings);
      addTearDown(network.dispose);
      final uri = Uri.parse('http://127.0.0.1:${server.port}/scope');
      await NetworkCloudDriveHttp(network: network).send(
        CloudDriveHttpRequest(
          method: 'GET',
          uri: uri,
          connectionScope: 'api-scope-${server.port}',
        ),
      );
      final upstream = await NetworkCloudDriveUpstreamClient(network: network)
          .open(
            CloudDriveUpstreamRequest(
              method: 'GET',
              uri: uri,
              connectionScope: 'media-scope-${server.port}',
            ),
          );
      await upstream.body!.drain<void>();
      await upstream.close();
      expect(network.scopes, [
        NetworkScope.cloudDrive,
        NetworkScope.cloudDrive,
      ]);
    },
  );
  test(
    'HTTP transport returns rotated cookies only for their response domain',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.cookies.add(Cookie('__puus', 'fresh')..path = '/');
        request.response.cookies.add(
          Cookie('foreign', 'unsafe')..domain = 'unrelated.test',
        );
        request.response.write('{}');
        request.response.close();
      });
      final response = await NetworkCloudDriveHttp().send(
        CloudDriveHttpRequest(
          method: 'GET',
          uri: Uri.parse('http://127.0.0.1:${server.port}/api'),
        ),
      );
      expect(response.cookies.single.name, '__puus');
      expect(response.cookies.single.value, 'fresh');
      expect(response.cookies.single.domain, '127.0.0.1');
      expect(response.cookies.single.matches(response.finalUri), isTrue);
    },
  );

  test('probe stops before a large ignored range is buffered', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.add(List<int>.filled(256 * 1024, 7));
      request.response.close();
    });
    final client = NetworkCloudDriveHttp();
    final response = await client.send(
      CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:${server.port}/media.mp4'),
        range: (0, 1),
        readMode: CloudDriveReadMode.probe,
        maxBytes: 1024,
        timeout: const Duration(seconds: 5),
      ),
    );
    expect(response.statusCode, 200);
    expect(response.body.length, lessThanOrEqualTo(1024));
    expect(response.finalUri.path, '/media.mp4');
  });

  test('relative redirects keep the current host', () {
    final resolved = resolveCloudDriveRedirect(
      Uri.parse('https://pan.baidu.com/api/file'),
      '/rest/file',
    );
    expect(resolved.toString(), 'https://pan.baidu.com/rest/file');
  });

  test('logs drop urls cookies and lease tokens', () {
    const raw =
        'open https://d.pcs.baidu.com/a.mp4?sign=secret Cookie: BDUSS=abc /cd/leaseToken';
    final redacted = redactCloudDriveLog(raw);
    expect(redacted.contains('sign=secret'), isFalse);
    expect(redacted.contains('BDUSS=abc'), isFalse);
    expect(redacted.contains('leaseToken'), isFalse);
    expect(redacted.contains('<url>'), isTrue);
    final quark = redactCloudDriveLog(
      '__puus=private; __pus=private; __kps=private; __ktd=private; __uid=private',
    );
    expect(quark, isNot(contains('private')));
  });

  test('only the latest quality ticket may commit', () {
    final gate = CloudDriveQualitySwitch();
    final first = gate.begin();
    final second = gate.begin();
    expect(gate.isLatest(first), isFalse);
    expect(
      cloudDriveQualityCommitAllowed(
        ticket: first,
        latestTicket: second,
        itemId: 'a',
        currentItemId: 'a',
      ),
      isFalse,
    );
    expect(
      cloudDriveQualityCommitAllowed(
        ticket: second,
        latestTicket: second,
        itemId: 'a',
        currentItemId: 'a',
      ),
      isTrue,
    );
    gate.finish(first);
    expect(gate.switching, isTrue);
    gate.finish(second);
    expect(gate.switching, isFalse);
  });

  test('finish notifies after the spinner is cleared', () {
    final gate = CloudDriveQualitySwitch();
    final ticket = gate.begin();
    var seenSwitching = true;
    publishCloudDriveQualityEnd(
      gate: gate,
      ticket: ticket,
      notify: () => seenSwitching = gate.switching,
    );
    expect(seenSwitching, isFalse);
    final newer = gate.begin();
    publishCloudDriveQualityEnd(
      gate: gate,
      ticket: ticket,
      notify: () => seenSwitching = gate.switching,
    );
    expect(gate.isLatest(newer), isTrue);
    expect(seenSwitching, isTrue);
  });

  test('window resume does not reopen a healthy session', () {
    expect(
      shouldReopenCloudDrivePlayback(
        deviceChanged: true,
        configurationChanged: false,
        sessionHealthy: true,
      ),
      isFalse,
    );
    expect(
      shouldReopenCloudDrivePlayback(
        deviceChanged: true,
        configurationChanged: false,
        sessionHealthy: false,
      ),
      isTrue,
    );
    expect(
      shouldReopenCloudDrivePlayback(
        deviceChanged: false,
        configurationChanged: true,
        sessionHealthy: true,
      ),
      isFalse,
    );
    expect(
      cloudDriveSessionIsHealthy(
        controllerReady: true,
        controllerFailed: false,
        playingOrPaused: true,
      ),
      isTrue,
    );
  });

  test('cloud preview keeps the time and hides the image well', () {
    expect(
      decideSeekPreview(
        audio: false,
        bilibili: false,
        bilibiliSpritesReady: false,
        cloudDrive: true,
        cloudLocalFramesReady: false,
      ).showsImage,
      isFalse,
    );
    expect(
      decideSeekPreview(
        audio: false,
        bilibili: false,
        bilibiliSpritesReady: false,
        cloudDrive: true,
        cloudLocalFramesReady: true,
        remoteRandomAccessEnabled: true,
      ).showsImage,
      isFalse,
    );
    expect(
      decideSeekPreview(
        audio: false,
        bilibili: false,
        bilibiliSpritesReady: false,
        cloudDrive: false,
        cloudLocalFramesReady: false,
      ).source,
      SeekPreviewSource.localFrames,
    );
    expect(
      decideSeekPreview(
        audio: false,
        bilibili: true,
        bilibiliSpritesReady: true,
        cloudDrive: false,
        cloudLocalFramesReady: false,
      ).source,
      SeekPreviewSource.officialStoryboard,
    );
  });

  test('range resume rejects a full 200 and accepts a matching 206', () {
    expect(
      decideCloudDriveResume(
        localBytes: 4,
        statusCode: 200,
        contentRangeStart: null,
        contentRangeTotal: null,
      ).action,
      CloudDriveResumeAction.replace,
    );
    expect(
      decideCloudDriveResume(
        localBytes: 4,
        statusCode: 206,
        contentRangeStart: 4,
        contentRangeTotal: 10,
        responseEtag: '"a"',
        expectedEtag: 'W/"a"',
      ).action,
      CloudDriveResumeAction.append,
    );
    expect(
      decideCloudDriveResume(
        localBytes: 4,
        statusCode: 206,
        contentRangeStart: 4,
        contentRangeTotal: 10,
        responseEtag: '"b"',
        expectedEtag: '"a"',
      ).action,
      CloudDriveResumeAction.replace,
    );
    expect(
      decideCloudDriveResume(
        localBytes: 10,
        statusCode: 416,
        contentRangeStart: null,
        contentRangeTotal: 10,
      ).action,
      CloudDriveResumeAction.complete,
    );
    expect(
      decideCloudDriveResume(
        localBytes: 4,
        statusCode: 416,
        contentRangeStart: null,
        contentRangeTotal: 10,
      ).action,
      CloudDriveResumeAction.replace,
    );
  });

  test('json subtitles become srt and html is rejected', () {
    final srt = interpretCloudDriveSubtitleBody(
      '{"body":[{"from":1.5,"to":2.5,"content":"你好"}]}',
    );
    expect(srt, contains('你好'));
    expect(srt, contains('00:00:01,500'));
    expect(
      () => interpretCloudDriveSubtitleBody('<html><body>login</body></html>'),
      throwsA(isA<CloudDriveFailure>()),
    );
    expect(
      () => interpretCloudDriveSubtitleBody('{"errno":-6}'),
      throwsA(isA<CloudDriveFailure>()),
    );
    final merged = mergeSegmentedWebVtt([
      (
        playlistStart: Duration.zero,
        body: 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n第一句\n',
      ),
      (
        playlistStart: const Duration(seconds: 10),
        body: 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n第二句\n',
      ),
    ]);
    expect(merged, contains('00:00:10.000'));
    expect(merged, contains('第二句'));
  });
}
