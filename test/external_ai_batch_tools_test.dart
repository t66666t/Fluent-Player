import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';

class _RealHttp extends HttpOverrides {}

class _ExistenceOnlyFile implements File {
  _ExistenceOnlyFile(this.file);
  final File file;
  @override
  Future<bool> exists() => file.exists();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Inventory must not read linked transcript content');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late List<VideoItem> media;
  late List<VideoCollection> folders;
  String? scope;

  Future<VideoItem> video(String id, {String? text, String? parent}) async {
    final file = File(p.join(directory.path, '$id.txt'));
    if (text != null) await file.writeAsString(text);
    return VideoItem(
      id: id,
      title: '课程 $id',
      path: p.join(directory.path, '$id.mp4'),
      durationMs: 60000,
      lastUpdated: 0,
      parentId: parent,
      subtitlePath: file.path,
    );
  }

  ExternalAiLibrarySource source() => ExternalAiLibrarySource(
    videos: () => media,
    folders: () => folders,
    children: (parent) => [
      ...folders.where((f) => f.parentId == parent),
      ...media.where((v) => v.parentId == parent),
    ],
    scopeFolder: () => scope,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluent_mcp_batch_');
    media = [];
    folders = [];
    scope = null;
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'one inventory finds available subtitles without reading linked bodies',
    () async {
      for (var i = 0; i < 150; i++) {
        media.add(await video('$i', text: i.isEven ? '字幕正文 $i' : null));
      }
      final files = {
        for (final v in media) v.subtitlePath!: File(v.subtitlePath!),
      };
      final result = await IOOverrides.runZoned(
        () => source().callTool('library_documents', {'hasDocuments': true}),
        createFile: (path) => _ExistenceOnlyFile(files[path]!),
      );
      expect(result['totalMedia'], 150);
      expect(result['scannedMedia'], 150);
      expect(result['mediaWithDocuments'], 75);
      expect(result['unavailableDocumentCount'], 75);
      expect(result['nextOffset'], isNull);
      final items = result['items'] as List;
      expect(items, hasLength(75));
      expect(items.every((v) => v['availableDocumentCount'] == 1), isTrue);
      expect(jsonEncode(result), isNot(contains(directory.path)));
    },
  );

  test(
    'batch discovers matching sidecars for many unlinked videos in one directory',
    () async {
      for (var i = 0; i < 60; i++) {
        final item = await video('episode-$i');
        item.subtitlePath = null;
        media.add(item);
        await File(
          p.join(directory.path, 'episode-$i.zh.srt'),
        ).writeAsString('1\n00:00:00,000 --> 00:00:59,500\n第$i个视频\n');
      }
      final result = await source().callTool('library_documents', {
        'hasDocuments': true,
      });
      expect(result['nextOffset'], isNull);
      expect(result['scannedMedia'], 60);
      expect(result['mediaWithDocuments'], 60);
      final items = result['items'] as List;
      expect(items, hasLength(60));
      for (var i = 0; i < 60; i++) {
        expect(
          (items[i]['documents'] as List).single['label'],
          'episode-$i.zh.srt',
        );
      }
    },
  );

  test(
    'filtered inventory advances across empty pages without skipping media',
    () async {
      for (var i = 0; i < 13; i++) {
        media.add(await video('$i', text: i >= 6 ? '正文' : null));
      }
      final reader = source();
      final ids = <String>[];
      int? offset = 0;
      var scanned = 0;
      while (offset != null) {
        final result = await reader.callTool('library_documents', {
          'hasDocuments': true,
          'offset': offset,
          'scanLimit': 3,
          'limit': 2,
        });
        ids.addAll(
          (result['items'] as List).map((v) => v['mediaId'] as String),
        );
        scanned += result['scannedMedia'] as int;
        expect(result['endOffset'], greaterThan(offset));
        offset = result['nextOffset'] as int?;
      }
      expect(ids, [for (var i = 6; i < 13; i++) '$i']);
      expect(scanned, 13);
    },
  );

  test(
    'batch selectors preserve requested order, recursion and authorization',
    () async {
      folders.addAll([
        VideoCollection(id: 'allowed', name: '允许', createTime: 0),
        VideoCollection(
          id: 'nested',
          name: '子目录',
          createTime: 0,
          parentId: 'allowed',
        ),
        VideoCollection(id: 'private', name: '私有', createTime: 0),
        VideoCollection(
          id: 'hidden',
          name: '隐藏',
          createTime: 0,
          parentId: 'allowed',
          isHiddenFromFolders: true,
        ),
      ]);
      media.addAll([
        await video('a', parent: 'allowed', text: '关键词甲'),
        await video('b', parent: 'nested', text: '关键词乙'),
        await video('c', parent: 'private', text: '关键词私有'),
        await video('d', parent: 'hidden', text: '关键词隐藏'),
      ]);
      scope = 'allowed';
      final reader = source();
      final all = await reader.callTool('library_documents', {});
      expect((all['items'] as List).map((v) => v['mediaId']), ['a', 'b']);
      final direct = await reader.callTool('library_documents', {
        'recursive': false,
      });
      expect((direct['items'] as List).single['mediaId'], 'a');
      final selected = await reader.callTool('library_documents', {
        'mediaIds': ['b', 'a', 'b'],
      });
      expect((selected['items'] as List).map((v) => v['mediaId']), ['b', 'a']);
      for (final name in [
        'library_documents',
        'library_document_search',
        'documents_read_batch',
      ]) {
        await expectLater(
          reader.callTool(name, {
            'mediaIds': ['a', 'c'],
            'query': '关键词',
          }),
          throwsArgumentError,
        );
        await expectLater(
          reader.callTool(name, {
            'mediaIds': ['d'],
            'query': '关键词',
          }),
          throwsArgumentError,
        );
        await expectLater(
          reader.callTool(name, {
            'mediaIds': [directory.path],
            'query': '关键词',
          }),
          throwsArgumentError,
        );
      }
      await expectLater(
        reader.callTool('library_documents', {'folderId': 'private'}),
        throwsArgumentError,
      );
      final search = await reader.callTool('library_document_search', {
        'query': '关键词',
      });
      expect((search['items'] as List).map((v) => v['mediaId']), ['a', 'b']);
      scope = 'private';
      final revoked = await reader.callTool('library_document_search', {
        'query': '关键词',
      });
      expect((revoked['items'] as List).single['mediaId'], 'c');
    },
  );

  test(
    'global keyword search finds bodies, paginates and bounds excerpts',
    () async {
      for (var i = 0; i < 18; i++) {
        media.add(
          await video(
            '$i',
            text: i.isEven ? '不同标题的文稿中包含光圈。光圈调整。光圈原理。光圈实践。' : '没有关键词',
          ),
        );
      }
      final srt = await File(
        p.join(directory.path, 'timed.srt'),
      ).writeAsString('1\n00:00:12,000 --> 00:00:15,000\n光圈与景深\n');
      media.last.subtitlePath = srt.path;
      media.add(await video('missing'));
      final reader = source();
      final ids = <String>[];
      var unavailable = 0;
      int? offset = 0;
      while (offset != null) {
        final result = await reader.callTool('library_document_search', {
          'query': '光圈',
          'offset': offset,
          'limit': 3,
          'scanLimit': 5,
        });
        expect(result['isExcerpt'], isTrue);
        unavailable += result['unavailableDocumentCount'] as int;
        for (final item in result['items'] as List) {
          ids.add(item['mediaId'] as String);
          final matches = item['matches'] as List;
          expect(matches.length, lessThanOrEqualTo(3));
          if (item['mediaId'] == '17') {
            expect(matches.single['excerpt'], contains('[12000ms–15000ms]'));
          } else {
            expect(item['excerptsLimited'], isTrue);
          }
          expect(matches.first['revision'], isNotEmpty);
        }
        expect(jsonEncode(result), isNot(contains(directory.path)));
        offset = result['nextOffset'] as int?;
      }
      expect(ids, [
        ...[for (var i = 0; i < 18; i += 2) '$i'],
        '17',
      ]);
      expect(unavailable, 1);
    },
  );

  test(
    'batch reads many videos directly, preferring existing primary documents',
    () async {
      for (var i = 0; i < 80; i++) {
        final item = await video('$i', text: '第$i段完整正文');
        final translation = await File(
          p.join(directory.path, '$i.en.txt'),
        ).writeAsString('Translation $i');
        item.secondarySubtitlePath = translation.path;
        media.add(item);
      }
      final result = await source().callTool('documents_read_batch', {
        'mediaIds': media.map((v) => v.id).toList(),
      });
      expect(result['complete'], isTrue);
      expect(result['errors'], isEmpty);
      expect(result['nextRequests'], isEmpty);
      final items = result['items'] as List;
      expect(items, hasLength(80));
      for (var i = 0; i < 80; i++) {
        expect(items[i]['text'], '第$i段完整正文');
        expect(items[i]['label'], '主字幕');
      }
    },
  );

  test(
    'batch continuation reconstructs every document without clipping or broken emoji',
    () async {
      final originals = <String, String>{};
      for (var i = 0; i < 4; i++) {
        originals['$i'] = List.filled(95, '第$i段🙂完整文稿\n').join();
        media.add(await video('$i', text: originals['$i']));
      }
      final reader = source();
      final texts = <String, StringBuffer>{};
      Map<String, dynamic> args = {'mediaIds': media.map((v) => v.id).toList()};
      var calls = 0;
      while (true) {
        final result = await reader.callTool('documents_read_batch', {
          ...args,
          'maxCharacters': 73,
        });
        calls++;
        expect(calls, lessThan(100));
        expect(result['errors'], isEmpty);
        expect(result['returnedCharacters'], lessThanOrEqualTo(74));
        for (final item in result['items'] as List) {
          final text = item['text'] as String;
          expect(utf8.decode(utf8.encode(text)), text);
          texts
              .putIfAbsent(item['mediaId'] as String, StringBuffer.new)
              .write(text);
        }
        final next = result['nextRequests'] as List;
        if (next.isEmpty) {
          expect(result['complete'], isTrue);
          break;
        }
        expect(result['complete'], isFalse);
        args = {'requests': next};
      }
      expect(texts.map((id, text) => MapEntry(id, text.toString())), originals);
    },
  );

  test(
    'batch reports missing, broken and changed documents without claiming full coverage',
    () async {
      media.addAll([
        await video('changing', text: 'before content'),
        await video('missing'),
        await video('good', text: 'good content'),
      ]);
      final reader = source();
      final first = await reader.callTool('documents_read_batch', {
        'mediaIds': ['changing'],
        'maxCharacters': 3,
      });
      final file = File(media.first.subtitlePath!);
      final stat = await file.stat();
      await file.writeAsString('AFTER! content');
      await file.setLastModified(stat.modified);
      final changed = await reader.callTool('documents_read_batch', {
        'requests': [
          ...first['nextRequests'] as List,
          {'mediaId': 'missing'},
          {'mediaId': 'good'},
        ],
      });
      expect(changed['complete'], isFalse);
      expect(changed['nextRequests'], isEmpty);
      expect((changed['items'] as List).single['text'], 'good content');
      expect((changed['errors'] as List).map((v) => v['code']), [
        'revision_changed',
        'missing_documents',
      ]);
      expect(jsonEncode(changed), isNot(contains(directory.path)));
      final absent = await reader.callTool('documents_read_batch', {
        'requests': [
          {'mediaId': 'good', 'documentId': '../../private.txt'},
        ],
      });
      expect((absent['errors'] as List).single['code'], 'document_unavailable');
    },
  );

  test('new tools reject malformed selectors and unbounded batches', () async {
    media.add(await video('a', text: '正文'));
    final reader = source();
    for (final args in <Map<String, dynamic>>[
      {'mediaIds': []},
      {
        'mediaIds': [1],
      },
      {'recursive': 'true'},
      {'hasDocuments': 'yes'},
      {'scanLimit': 1001},
      {'offset': 2},
    ]) {
      await expectLater(
        reader.callTool('library_documents', args),
        throwsArgumentError,
      );
    }
    for (final args in <Map<String, dynamic>>[
      {},
      {
        'mediaIds': ['a'],
        'requests': [
          {'mediaId': 'a'},
        ],
      },
      {'mediaIds': List.filled(101, 'a')},
      {
        'mediaIds': ['a'],
        'maxCharacters': 120001,
      },
      {
        'requests': [
          {'mediaId': 'a', 'path': 'private.txt'},
        ],
      },
      {
        'requests': [
          {'mediaId': 'a', 'offset': -1},
        ],
      },
    ]) {
      await expectLater(
        reader.callTool('documents_read_batch', args),
        throwsArgumentError,
      );
    }
    await expectLater(
      reader.callTool('library_document_search', {'query': ''}),
      throwsArgumentError,
    );
  });

  test(
    'real HTTP needs two tool calls to find and read 100 short video transcripts',
    () async {
      for (var i = 0; i < 100; i++) {
        media.add(await video('$i', text: '第$i个视频的完整测试文稿。'));
      }
      const token = 'synthetic-batch-test-token';
      final server = ExternalAiServer(dataSource: source(), token: token);
      final endpoint = await server.start();
      final client = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _RealHttp(),
      );
      addTearDown(() async {
        client.close(force: true);
        await server.stop();
      });
      Future<Map> rpc(String method, [Map<String, dynamic>? params]) async {
        final request = await client.postUrl(endpoint);
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer $token');
        request.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': server.requestCount + 1,
            'method': method,
            'params': ?params,
          }),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        final data = jsonDecode(await utf8.decodeStream(response)) as Map;
        expect(data['error'], isNull);
        return data['result'] as Map;
      }

      final init = await rpc('initialize', {'protocolVersion': '2025-11-25'});
      expect(init['instructions'], contains('documents_read_batch'));
      final tools = (await rpc('tools/list'))['tools'] as List;
      expect(tools.map((t) => t['name']), containsAll(['library_documents', 'library_document_search', 'documents_read_batch', 'playback_read', 'folder_info']));
      final before = server.requestCount;
      final watch = Stopwatch()..start();
      final inventory = await rpc('tools/call', {
        'name': 'library_documents',
        'arguments': {'hasDocuments': true},
      });
      expect(inventory['isError'], isFalse);
      final ids = (inventory['structuredContent']['items'] as List)
          .map((v) => v['mediaId'])
          .toList();
      expect(ids, hasLength(100));
      final read = await rpc('tools/call', {
        'name': 'documents_read_batch',
        'arguments': {'mediaIds': ids},
      });
      expect(read['isError'], isFalse);
      expect(read['structuredContent']['complete'], isTrue);
      expect(read['structuredContent']['items'], hasLength(100));
      expect(server.requestCount - before, 2);
      watch.stop();
      // This measures real local transport and synthetic short files, not model
      // reasoning speed or the user's media library.
      // ignore: avoid_print
      print(
        'MCP batch fixture: 100 media, 2 tool calls, ${watch.elapsedMilliseconds} ms',
      );
    },
  );
}
