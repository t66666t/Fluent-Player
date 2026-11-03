import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_models.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_service.dart';
import 'package:video_player_app/features/subtitle_search/subtitle_search_workspace.dart';

const cueText = '1\n00:00:01,000 --> 00:00:03,000\nこんにちは。\n\n';

class MemorySubtitleSecrets implements SubtitleSearchSecretStorage {
  final values = <String, String>{};
  final reads = <String>[];
  bool failWrite = false;
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('keychain unavailable');
    values[key] = value;
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  SubtitleSearchService service(ResponseBody Function(RequestOptions) respond) {
    final dio = Dio()..httpClientAdapter = _Adapter(respond);
    addTearDown(() => dio.close(force: true));
    return SubtitleSearchService(dio: dio);
  }

  test(
    'normalizes filenames without dropping dotted titles or episode metadata',
    () {
      expect(
        SubtitleSearchQuery.cleanTitle('[Group] Breaking.Bad.S01E01.1080p.mkv'),
        'Breaking Bad',
      );
      expect(SubtitleSearchQuery.episodeFrom('Breaking.Bad.S01E01.mkv'), (
        1,
        1,
      ));
      expect(SubtitleSearchQuery.cleanTitle('Mr.Robot'), 'Mr Robot');
      expect(SubtitleSearchQuery.cleanTitle('葬送のフリーレン'), '葬送のフリーレン');
    },
  );
  test(
    'default sources are usable without reading or saving their keys',
    () async {
      final secrets = MemorySubtitleSecrets();
      final w = SubtitleSearchWorkspace(secrets: secrets);
      addTearDown(w.dispose);
      await w.initialize();
      expect(w.connectedCount, 3);
      expect(w.configured(SubtitleSearchSource.xunlei), isTrue);
      expect(w.configured(SubtitleSearchSource.jimaku), isTrue);
      expect(
        secrets.reads.any(
          (key) => key.contains('jimaku') || key.contains('xunlei'),
        ),
        isFalse,
      );
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'Xunlei query scopes episodes and filters bilingual metadata without a key',
    () async {
      final s = service((request) {
        expect(request.uri.queryParameters['name'], 'Breaking Bad S01E01');
        expect(request.headers.containsKey('Authorization'), isFalse);
        return jsonBody({
          'code': 0,
          'data': [
            {
              'cid': '1',
              'name': 'show.srt',
              'simple_name': 'Show',
              'languages': ['简体', 'English'],
              'url': 'https://subtitle.v.geilijiasu.com/show.srt',
              'ext': 'srt',
            },
            {
              'cid': '2',
              'name': 'other.srt',
              'languages': ['日语'],
              'url': 'https://subtitle.v.geilijiasu.com/other.srt',
            },
          ],
        });
      });
      final page = await s.search(
        SubtitleSearchSource.xunlei,
        const SubtitleSearchQuery(
          text: 'Breaking Bad',
          language: 'en',
          season: 1,
          episode: 1,
        ),
        const SubtitleSearchCredentials(),
      );
      expect(page.hits.single.id, '1');
      expect(page.hits.single.language, contains('English'));
    },
  );
  test(
    'Jimaku searches published aliases and shares its public catalog between searches',
    () async {
      var catalogRequests = 0;
      final s = service((request) {
        catalogRequests++;
        expect(request.headers.containsKey('Authorization'), isFalse);
        return ResponseBody.fromString(
          '<div class="entry" data-extra="{&#34;name&#34;:&#34;Sousou no Frieren&#34;,&#34;english_name&#34;:&#34;Frieren&#34;,&#34;japanese_name&#34;:&#34;葬送のフリーレン&#34;}"><a href="/entry/729">Title</a></div>',
          200,
        );
      });
      final results = await s.search(
        SubtitleSearchSource.jimaku,
        const SubtitleSearchQuery(text: 'Frieren'),
        const SubtitleSearchCredentials(),
      );
      expect(results.hits.first.title, '葬送のフリーレン');
      await s.search(
        SubtitleSearchSource.jimaku,
        const SubtitleSearchQuery(text: '葬送'),
        const SubtitleSearchCredentials(),
      );
      expect(
        catalogRequests,
        2,
        reason: 'anime and live action catalogs fetched once each',
      );
    },
  );
  test(
    'public file parser preserves encoded names and ranks requested episodes',
    () {
      String metadata(String name) => jsonEncode({
        'url': '/entry/729/download/${Uri.encodeComponent(name)}',
        'name': name,
        'size': 50,
      }).replaceAll('"', '&#34;');
      final files = parseJimakuFiles((
        '<div data-extra="${metadata('Frieren - 02.srt')}"></div><div data-extra="${metadata('Frieren - 01.srt')}"></div>',
        '729',
        1,
      ));
      expect(files.first.name, 'Frieren - 01.srt');
      expect(files.first.url, contains('%20'));
    },
  );
  test(
    'download follows validated redirects and never forwards credentials',
    () async {
      var calls = 0;
      final s = service((request) {
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.headers.containsKey('Api-Key'), isFalse);
        calls++;
        if (calls == 1) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://jimaku.cc/entry/1/download/file.srt'],
            },
          );
        }
        return ResponseBody.fromBytes(utf8.encode(cueText), 200);
      });
      final documents = await s.download(
        const SubtitleSearchHit(
          source: SubtitleSearchSource.jimaku,
          id: '1',
          title: 'Title',
        ),
        const SubtitleSearchFile(
          id: 'file',
          name: 'file.srt',
          url: 'https://jimaku.cc/file.srt',
        ),
        const SubtitleSearchCredentials(apiKey: 'must-not-leak'),
      );
      expect(calls, 2);
      expect(documents.single.cues.single.text, 'こんにちは。');
    },
  );
  test('a stalled redirect body does not block a subtitle download', () async {
    var calls = 0;
    final abandoned = StreamController<Uint8List>();
    final cancelled = Completer<void>();
    abandoned.onCancel = () {
      if (!cancelled.isCompleted) cancelled.complete();
    };
    addTearDown(abandoned.close);
    final s = service((request) {
      calls++;
      if (calls == 1) {
        return ResponseBody(
          abandoned.stream,
          302,
          headers: {
            'location': ['https://jimaku.cc/new.srt'],
          },
        );
      }
      return ResponseBody.fromBytes(utf8.encode(cueText), 200);
    });
    final documents = await s
        .download(
          const SubtitleSearchHit(
            source: SubtitleSearchSource.jimaku,
            id: '1',
            title: 'T',
          ),
          const SubtitleSearchFile(
            id: 'f',
            name: 'file.srt',
            url: 'https://jimaku.cc/file.srt',
          ),
          const SubtitleSearchCredentials(),
        )
        .timeout(const Duration(milliseconds: 700));
    expect(documents.single.cues.single.text, 'こんにちは。');
    expect(calls, 2);
    await cancelled.future.timeout(const Duration(milliseconds: 700));
  });
  test('foreign download and redirect hosts are rejected', () async {
    expect(
      () => SubtitleSearchService.checkedDownloadUri(
        SubtitleSearchSource.jimaku,
        'https://jimaku.cc.evil.test/file.srt',
      ),
      throwsA(isA<SubtitleSearchException>()),
    );
    expect(
      () => SubtitleSearchService.checkedDownloadUri(
        SubtitleSearchSource.xunlei,
        'http://127.0.0.1/file.srt',
      ),
      throwsA(isA<SubtitleSearchException>()),
    );
    final s = service(
      (request) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['http://localhost/private'],
        },
      ),
    );
    await expectLater(
      s.download(
        const SubtitleSearchHit(
          source: SubtitleSearchSource.jimaku,
          id: '1',
          title: 'T',
        ),
        const SubtitleSearchFile(
          id: 'f',
          name: 'file.srt',
          url: 'https://jimaku.cc/file.srt',
        ),
        const SubtitleSearchCredentials(),
      ),
      throwsA(isA<SubtitleSearchException>()),
    );
  });
  test(
    'ZIP previews retain version folders without extracting files and exclude non-subtitles',
    () {
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'folder/01.srt',
            utf8.encode(cueText).length,
            utf8.encode(cueText),
          ),
        )
        ..addFile(ArchiveFile('notes.html', 4, utf8.encode('test')));
      final documents = decodeSubtitleSearchPayload((
        Uint8List.fromList(ZipEncoder().encode(archive)),
        'pack.zip',
      ));
      expect(documents.single.name, 'folder/01.srt');
      expect(documents.single.cues.single.text, 'こんにちは。');
      expect(
        () => decodeSubtitleSearchPayload((
          Uint8List.fromList(utf8.encode('<html>blocked</html>')),
          'file.srt',
        )),
        throwsA(isA<SubtitleSearchException>()),
      );
    },
  );
  test(
    'time offsets preserve original files at zero and create portable shifted SRT',
    () {
      final doc = decodeSubtitleSearchPayload((
        Uint8List.fromList(utf8.encode(cueText)),
        'file.srt',
      )).single;
      const hit = SubtitleSearchHit(
        source: SubtitleSearchSource.jimaku,
        id: '1',
        title: 'T',
      );
      expect(
        SubtitleSearchImportRequest(
          hit: hit,
          document: doc,
          role: SubtitleSearchImportRole.primary,
        ).content,
        cueText,
      );
      final shifted = SubtitleSearchImportRequest(
        hit: hit,
        document: doc,
        role: SubtitleSearchImportRole.primary,
        offsetMs: -500,
      );
      expect(shifted.content, contains('00:00:00,500 --> 00:00:02,500'));
    },
  );
  test('keychain failure keeps optional credentials only in memory', () async {
    final secrets = MemorySubtitleSecrets()..failWrite = true;
    final w = SubtitleSearchWorkspace(secrets: secrets);
    addTearDown(w.dispose);
    expect(
      await w.saveCredentials(
        SubtitleSearchSource.assrt,
        const SubtitleSearchCredentials(apiKey: 'private'),
      ),
      isFalse,
    );
    expect(w.configured(SubtitleSearchSource.assrt), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().any(
        (key) => (prefs.get(key)?.toString() ?? '').contains('private'),
      ),
      isFalse,
    );
  });
}
