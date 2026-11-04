import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_http.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/providers/quark_cloud_drive_provider.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

class _Http implements CloudDriveHttp {
  _Http(this.handle);
  final CloudDriveHttpResponse Function(CloudDriveHttpRequest) handle;
  final calls = <CloudDriveHttpRequest>[];
  @override
  Future<CloudDriveHttpResponse> send(
    CloudDriveHttpRequest request, {
    Object? cancelToken,
  }) async {
    calls.add(request);
    return handle(request);
  }
}

CloudDriveHttpResponse _json(
  CloudDriveHttpRequest r,
  Object data, {
  List<CloudDriveCookie> cookies = const [],
}) => CloudDriveHttpResponse(
  statusCode: 200,
  headers: const {'content-type': 'application/json'},
  body: utf8.encode(jsonEncode(data)),
  finalUri: r.uri,
  cookies: cookies,
);

CloudDriveCredential _jar([String value = 'old']) => CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: '__puus', value: value, domain: '.quark.cn'),
  ],
);

CloudDrivePlaybackRequest _request({
  CloudDriveCredential? credential,
  String? quality,
  String account = 'a',
  String revision = 'r1',
}) => CloudDrivePlaybackRequest(
  credential: credential ?? _jar(),
  accountLocalId: account,
  remoteAccountId: account,
  driveId: '0',
  fileId: 'video',
  name: 'Lesson.mp4',
  revision: revision,
  preferredQualityId: quality,
  durationMs: 600000,
);

CloudDriveHttpResponse _media(
  CloudDriveHttpRequest r, {
  String? manifest,
  int status = 206,
}) => CloudDriveHttpResponse(
  statusCode: status,
  headers: {
    'content-type': manifest == null
        ? 'video/mp4'
        : 'application/vnd.apple.mpegurl',
    'content-range': 'bytes 0-1/6000',
    'accept-ranges': 'bytes',
  },
  body: manifest == null ? [0, 1] : utf8.encode(manifest),
  finalUri: r.uri,
);

Map<String, Object> _play({
  bool denied = false,
  bool pending = false,
  int duration = 600,
}) => {
  'code': 0,
  'data': {
    'meta': {'duration': 600},
    'video_list': [
      {
        'resolution': 'super',
        'accessable': false,
        'trans_status': 'success',
        'right': 'svip',
      },
      {
        'resolution': 'low',
        'accessable': !denied,
        'trans_status': pending ? 'doing' : 'success',
        'video_info': {
          'duration': duration,
          'height': 270,
          'format': 'm3u8',
          'url': 'https://media.quark.cn/video.m3u8',
        },
      },
    ],
  },
};

void main() {
  test(
    'rotated response cookies reach original probe, descriptor and covers',
    () async {
      final http = _Http((r) {
        if (r.uri.path.endsWith('/download')) {
          return _json(
            r,
            {
              'code': 0,
              'data': [
                {
                  'download_url': 'https://media.quark.cn/movie.mp4',
                  'duration': 100000,
                  'size': 6000,
                },
              ],
            },
            cookies: const [
              CloudDriveCookie(
                name: '__puus',
                value: 'new',
                domain: '.quark.cn',
              ),
              CloudDriveCookie(
                name: '__puus',
                value: 'evil',
                domain: '.unrelated.test',
              ),
            ],
          );
        }
        expect(r.headers['Cookie'], '__puus=new');
        if (r.uri.path.endsWith('.mp4')) {
          expect(r.readMode, CloudDriveReadMode.probe);
          expect(r.range, (0, 1));
        }
        return _media(r, status: r.uri.path.endsWith('.jpg') ? 200 : 206);
      });
      final provider = QuarkCloudDriveProvider(http: http);
      final result = await provider.resolvePlayback(_request());
      expect(result.quality.id, 'original');
      expect(result.cookies.single.value, 'new');
      // Quark metadata is seconds even for videos longer than 100,000 seconds.
      expect(result.durationMs, 100000000);
      await provider.readThumbnail(
        CloudDriveFileRequest(
          credential: _jar(),
          accountLocalId: 'a',
          remoteAccountId: 'a',
          driveId: '0',
          fileId: 'video',
        ),
        Uri.parse('https://media.quark.cn/cover.jpg'),
      );
    },
  );

  test('one logged in account cannot rotate another account cookie', () async {
    final http = _Http((r) {
      if (r.uri.path.endsWith('/download')) {
        final owner = r.headers['Cookie']!.contains('second')
            ? 'second'
            : 'first';
        return _json(
          r,
          {
            'code': 0,
            'data': [
              {'download_url': 'https://media.quark.cn/$owner.mp4'},
            ],
          },
          cookies: [
            CloudDriveCookie(
              name: '__puus',
              value: '$owner-updated',
              domain: '.quark.cn',
            ),
          ],
        );
      }
      expect(
        r.headers['Cookie'],
        contains(
          r.uri.path.contains('second') ? 'second-updated' : 'first-updated',
        ),
      );
      return _media(r);
    });
    final provider = QuarkCloudDriveProvider(http: http);
    await provider.resolvePlayback(_request(credential: _jar('first')));
    await provider.resolvePlayback(
      _request(credential: _jar('second'), account: 'b'),
    );
    await provider.resolvePlayback(_request(credential: _jar('first')));
  });

  test(
    'nonmember sees unavailable tiers and can select only its full low stream',
    () async {
      final http = _Http(
        (r) => r.uri.path.endsWith('/play')
            ? _json(r, _play())
            : _media(
                r,
                status: 200,
                manifest: '#EXTM3U\n#EXTINF:600,\nseg.ts\n#EXT-X-ENDLIST\n',
              ),
      );
      final provider = QuarkCloudDriveProvider(http: http);
      final choices = await provider.discoverQualities(_request());
      final restricted = choices.singleWhere((q) => q.id == 'super');
      expect(restricted.selectable, isFalse);
      expect(restricted.statusDetail, contains('权益'));
      expect(choices.last.label, '270P 转码');
      expect(
        http.calls.length,
        1,
        reason: 'Background listing does not download every rung',
      );
      final result = await provider.resolvePlayback(_request(quality: 'low'));
      expect(result.verifiedComplete, isTrue);
      expect(
        result.qualities.any((q) => q.id == 'original'),
        isTrue,
        reason:
            'Starting from a remembered transcode must retain the original entry',
      );
      expect(result.manifest?.text, contains('#EXTINF:600'));
      expect(result.manifest?.baseUri, result.upstreamUri);
      await expectLater(
        provider.resolvePlayback(_request(quality: 'super')),
        throwsA(
          isA<CloudDriveFailure>().having(
            (e) => e.kind,
            'kind',
            CloudDriveFailureKind.entitlement,
          ),
        ),
      );
    },
  );

  test(
    'HTML and short preview manifests never become successful transcodes',
    () async {
      for (final text in [
        '<html>login</html>',
        '#EXTM3U\n#EXTINF:30,\nseg.ts\n',
      ]) {
        final provider = QuarkCloudDriveProvider(
          http: _Http(
            (r) => r.uri.path.endsWith('/play')
                ? _json(r, _play())
                : _media(r, status: 200, manifest: text),
          ),
        );
        await expectLater(
          provider.resolvePlayback(_request(quality: 'low')),
          throwsA(isA<CloudDriveFailure>()),
        );
      }
    },
  );

  test(
    'explicit original is not silently replaced when CDN rejects it',
    () async {
      final http = _Http(
        (r) => r.uri.path.endsWith('/download')
            ? _json(r, {
                'code': 0,
                'data': [
                  {'download_url': 'https://media.quark.cn/a.mp4'},
                ],
              })
            : _media(r, status: 412),
      );
      await expectLater(
        QuarkCloudDriveProvider(
          http: http,
        ).resolvePlayback(_request(quality: 'original')),
        throwsA(isA<CloudDriveFailure>()),
      );
      expect(http.calls.any((r) => r.uri.path.endsWith('/play')), isFalse);
    },
  );

  test(
    'sidecars use file parent, match the episode and read with rotated cookies',
    () async {
      final http = _Http((r) {
        if (r.uri.path.endsWith('/info')) {
          return _json(r, {
            'code': 0,
            'data': {
              'fid': 'video',
              'pdir_fid': 'parent',
              'file_name': 'Lesson.mp4',
              'file': true,
              'category': 1,
            },
          });
        }
        if (r.uri.path.endsWith('/extension')) {
          expect(r.uri.queryParameters['pdir_fid'], 'parent');
          return _json(r, {
            'code': 0,
            'data': {
              'list': [
                {'fid': 'sub', 'file_name': 'Lesson.zh-CN.srt'},
                {'fid': 'other', 'file_name': 'Other Lesson.en.srt'},
              ],
            },
            'metadata': {'_total': 2},
          });
        }
        if (r.uri.path.endsWith('/download')) {
          return _json(
            r,
            {
              'code': 0,
              'data': [
                {'download_url': 'https://media.quark.cn/sub.srt'},
              ],
            },
            cookies: const [
              CloudDriveCookie(
                name: '__puus',
                value: 'subtitle-new',
                domain: '.quark.cn',
              ),
            ],
          );
        }
        expect(r.headers['Cookie'], '__puus=subtitle-new');
        return CloudDriveHttpResponse(
          statusCode: 200,
          headers: const {},
          body: utf8.encode('1\n00:00:01,000 --> 00:00:03,000\n你好\n'),
          finalUri: r.uri,
        );
      });
      final provider = QuarkCloudDriveProvider(http: http);
      final catalog = await provider.discoverSidecarCatalog(_request());
      expect(catalog.tracks.single.fileId, 'sub');
      expect(catalog.tracks.single.autoSelect, isTrue);
      final text = await provider.readSubtitleText(
        CloudDriveSubtitleReadRequest(
          credential: _jar(),
          accountLocalId: 'a',
          remoteAccountId: 'a',
          driveId: '0',
          track: catalog.tracks.single,
        ),
      );
      expect(text, contains('你好'));
    },
  );

  test(
    'official check confirms a real capability response without creating tasks',
    () async {
      final http = _Http((r) {
        expect(r.uri.host, 'quick-note.quark.cn');
        expect(r.method, 'GET');
        expect(r.uri.queryParameters['fid'], 'video');
        expect(r.uri.queryParameters['req_id'], isNotEmpty);
        expect(r.uri.queryParameters['entry'], 'video_player');
        expect(r.uri.queryParameters['support_auto'], '3');
        expect(r.uri.queryParameters['fr'], 'pc');
        return _json(r, {
          'code': 0,
          'success': true,
          'data': {
            'support_subtitle': true,
            'support_auto_subtitle': true,
            'default_lang': 'cn',
            'user_right': 'free_limit',
            'accessible': 1,
          },
        });
      });
      final catalog = await QuarkCloudDriveProvider(
        http: http,
      ).discoverOfficialSubtitles(_request());
      expect(catalog.confirmedEmpty, isTrue);
      expect(http.calls.length, 1);
    },
  );

  test(
    'existing AI task result becomes a readable scoped Chinese AI track',
    () async {
      final http = _Http(
        (r) => r.uri.path.endsWith('/check')
            ? _json(r, {
                'code': 0,
                'data': {
                  'accessible': 1,
                  'task_list': [
                    {'task_id': 'task', 'task_status': 'success'},
                  ],
                },
              })
            : _json(r, {
                'code': 0,
                'data': {
                  'source_lang': 'cn',
                  'subtitle_content_source':
                      '1\n00:00:01,000 --> 00:00:03,000\nAI 台词\n',
                },
              }),
      );
      final provider = QuarkCloudDriveProvider(http: http);
      final a = await provider.discoverOfficialSubtitles(_request());
      final b = await provider.discoverOfficialSubtitles(
        _request(account: 'b'),
      );
      final changed = await provider.discoverOfficialSubtitles(
        _request(revision: 'r2'),
      );
      expect(a.tracks.single.language, 'zh-Hans');
      expect(a.tracks.single.isAi, isTrue);
      expect(a.tracks.single.id, isNot(b.tracks.single.id));
      expect(a.tracks.single.id, isNot(changed.tracks.single.id));
      final text = await provider.readSubtitleText(
        CloudDriveSubtitleReadRequest(
          credential: _jar(),
          accountLocalId: 'a',
          remoteAccountId: 'a',
          driveId: '0',
          track: a.tracks.single,
        ),
      );
      expect(text, contains('AI 台词'));
      expect(http.calls.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test(
    'desktop subtitle play info exposes source, translation and bilingual text',
    () async {
      const source = '1\n00:00:02,890 --> 00:00:05,274\n中文原文\n';
      const translation =
          '1\n00:00:02,890 --> 00:00:05,274\nEnglish translation\n';
      final http = _Http((r) {
        expect(r.method, 'GET');
        if (r.uri.path.endsWith('/check')) {
          return _json(r, {
            'code': 0,
            'success': true,
            'data': {
              'support_subtitle': true,
              'support_auto_subtitle': true,
              'default_lang': 'cn',
              'user_right': 'free_limit',
              'accessible': 1,
              // Actual desktop contract; task_list is absent.
              'subtitle_play_info': {
                'transfer_task_id': 'source-task',
                'translate_task_id': 'translation-task',
                'bilingual': 0,
              },
            },
          });
        }
        expect(r.uri.path, '/video/subtitle/result');
        final translated =
            r.uri.queryParameters['task_id'] == 'translation-task';
        return _json(r, {
          'code': 0,
          'success': true,
          'data': {
            'task_id': translated ? 'translation-task' : 'source-task',
            'status': 2,
            'source_lang': 'cn',
            'translate_lang': translated ? 'en' : 'cn',
            'subtitle_content': base64.encode(
              utf8.encode(translated ? translation : source),
            ),
            'subtitle_format': 'srt',
            'progress': 100,
          },
        });
      });
      final provider = QuarkCloudDriveProvider(http: http);
      final catalog = await provider.discoverOfficialSubtitles(_request());
      final again = await provider.discoverOfficialSubtitles(_request());
      expect(catalog.status, CloudDriveOfficialSubtitleStatus.ready);
      expect(catalog.tracks.map((t) => t.label), [
        '夸克 AI · 中文（源语言）',
        '夸克 AI · 英文',
        '夸克 AI · 中英双字',
      ]);
      expect(catalog.tracks.map((t) => t.language), ['zh-Hans', 'en', 'mul']);
      expect(catalog.tracks.every((t) => t.isAi && t.textAvailable), isTrue);
      expect(catalog.tracks.map((t) => t.id), again.tracks.map((t) => t.id));
      final expected = [
        '中文原文',
        'English translation',
        '中文原文\nEnglish translation',
      ];
      for (var i = 0; i < catalog.tracks.length; i++) {
        final body = await provider.readSubtitleText(
          CloudDriveSubtitleReadRequest(
            credential: _jar(),
            accountLocalId: 'a',
            remoteAccountId: 'a',
            driveId: '0',
            track: catalog.tracks[i],
          ),
        );
        final cues = SubtitleParser.parse(body);
        expect(cues.single.text, expected[i]);
        expect(cues.single.startTime.inMilliseconds, 2890);
        expect(cues.single.endTime.inMilliseconds, 5274);
      }
      expect(http.calls.length, 6); // Local reads do not submit or export.
    },
  );

  test('a failing translation leaves the source available', () async {
    final provider = QuarkCloudDriveProvider(
      http: _Http((r) {
        if (r.uri.path.endsWith('/check')) {
          return _json(r, {
            'code': 0,
            'data': {
              'subtitle_play_info': {
                'transfer_task_id': 'source',
                'translate_task_id': 'bad',
              },
            },
          });
        }
        if (r.uri.queryParameters['task_id'] == 'bad') {
          return _json(r, {'code': 15001, 'success': false});
        }
        return _json(r, {
          'code': 0,
          'data': {
            'status': 2,
            'source_lang': 'cn',
            'translate_lang': 'cn',
            'subtitle_content': base64.encode(
              utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n原文\n'),
            ),
          },
        });
      }),
    );
    final catalog = await provider.discoverOfficialSubtitles(_request());
    expect(catalog.status, CloudDriveOfficialSubtitleStatus.ready);
    expect(catalog.tracks.single.language, 'zh-Hans');
    expect(catalog.message, isNotNull);
  });

  test(
    'pending or invalid completed content is not a confirmed empty catalog',
    () async {
      for (final result in [
        {'status': 1, 'progress': 20},
        {
          'status': 2,
          'subtitle_content': base64.encode(utf8.encode('<html>login</html>')),
        },
      ]) {
        final provider = QuarkCloudDriveProvider(
          http: _Http(
            (r) => _json(
              r,
              r.uri.path.endsWith('/check')
                  ? {
                      'code': 0,
                      'data': {
                        'subtitle_play_info': {'transfer_task_id': 'task'},
                      },
                    }
                  : {'code': 0, 'data': result},
            ),
          ),
        );
        final catalog = await provider.discoverOfficialSubtitles(_request());
        expect(catalog.status, CloudDriveOfficialSubtitleStatus.failed);
        expect(catalog.confirmedEmpty, isFalse);
      }
    },
  );

  test(
    'subtitle permission and server failures are not reported as no subtitles',
    () async {
      final restricted = await QuarkCloudDriveProvider(
        http: _Http(
          (r) => _json(r, {
            'code': 0,
            'data': {'accessible': 0},
          }),
        ),
      ).discoverOfficialSubtitles(_request());
      expect(restricted.status, CloudDriveOfficialSubtitleStatus.restricted);
      final failed = await QuarkCloudDriveProvider(
        http: _Http(
          (r) => _json(r, {
            'code': 15001,
            'msg': 'inner server error',
            'success': false,
          }),
        ),
      ).discoverOfficialSubtitles(_request());
      expect(failed.status, CloudDriveOfficialSubtitleStatus.failed);
      expect(failed.confirmedEmpty, isFalse);
    },
  );
}
