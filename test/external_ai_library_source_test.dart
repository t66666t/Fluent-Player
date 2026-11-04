import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_models.dart';
import 'package:video_player_app/features/ai_chat/ai_conversation_store.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/app_data_paths.dart';

class _Store extends AiConversationStore {
  _Store(this.records);
  final List<AiConversation> records;
  @override
  Future<List<AiConversation>> load(String videoId) async =>
      records.where((c) => c.videoId == videoId).toList();
}

void main() {
  late Directory directory;
  late List<VideoItem> media;
  late List<VideoCollection> folders;
  late Map<String?, List<String>> order;
  String? scope;
  bool allowConversations = false;
  bool ready = true;
  VideoItem? current;

  VideoItem video(
    String id, {
    String? parent,
    String? subtitle,
    String? path,
    bool recycled = false,
  }) => VideoItem(
    id: id,
    title: '课程 $id',
    path: path ?? '${directory.path}/$id.mp4',
    durationMs: 600000,
    lastUpdated: 0,
    parentId: parent,
    subtitlePath: subtitle,
    isRecycled: recycled,
  );
  VideoCollection folder(
    String id, {
    String? parent,
    bool recycled = false,
    bool hidden = false,
  }) => VideoCollection(
    id: id,
    name: '目录 $id',
    createTime: 0,
    parentId: parent,
    isRecycled: recycled,
    isHiddenFromFolders: hidden,
  );
  ExternalAiLibrarySource source({AiConversationStore? store}) =>
      ExternalAiLibrarySource(
        videos: () => media,
        folders: () => folders,
        children: (parent) => [
          for (final id in order[parent] ?? const <String>[]) ...[
            ...media.where((v) => v.id == id),
            ...folders.where((f) => f.id == id),
          ],
        ],
        scopeFolder: () => scope,
        currentMedia: () => current,
        conversationsAllowed: () => allowConversations,
        conversationStore: store ?? _Store([]),
        ready: () => ready,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'fluent_external_ai_library_',
    );
    media = [];
    folders = [];
    order = {};
    scope = null;
    current = null;
    ready = true;
    allowConversations = false;
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'browse preserves software order and scoped descendants while hiding siblings',
    () async {
      folders.addAll([
        folder('allowed'),
        folder('nested', parent: 'allowed'),
        folder('private'),
      ]);
      media.addAll([
        video('last', parent: 'allowed'),
        video('first', parent: 'allowed'),
        video('nested-media', parent: 'nested'),
        video('private-media', parent: 'private'),
      ]);
      order['allowed'] = ['first', 'nested', 'last'];
      order['nested'] = ['nested-media'];
      scope = 'allowed';
      current = media.last;
      final reader = source();
      final first = await reader.callTool('library_browse', {'limit': 2});
      expect((first['items'] as List).map((item) => item['id']), [
        'first',
        'nested',
      ]);
      expect(first['nextOffset'], 2);
      final second = await reader.callTool('library_browse', {
        'offset': first['nextOffset'],
        'limit': 2,
      });
      expect((second['items'] as List).single['id'], 'last');
      expect(second['nextOffset'], isNull);
      expect((first['items'] as List).first['parentId'], isNull);
      final nested = await reader.callTool('library_browse', {
        'folderId': 'nested',
      });
      expect((nested['items'] as List).single['id'], 'nested-media');
      final info = await reader.callTool('media_info', {
        'mediaId': 'nested-media',
      });
      expect(info['folders'], ['目录 allowed', '目录 nested']);
      final overview = await reader.callTool('player_overview', {});
      expect(overview['mediaCount'], 3);
      expect(overview['currentMedia'], isNull);
      await expectLater(
        reader.callTool('library_browse', {'folderId': 'private'}),
        throwsArgumentError,
      );
      await expectLater(
        reader.callTool('media_info', {'mediaId': 'private-media'}),
        throwsArgumentError,
      );
      final search = await reader.callTool('library_search', {'query': '课程'});
      expect(
        (search['items'] as List).map((item) => item['id']),
        isNot(contains('private-media')),
      );
      expect(
        jsonEncode([first, second, info, overview]),
        isNot(contains(directory.path)),
      );
      scope = 'private';
      await expectLater(
        reader.callTool('media_info', {'mediaId': 'first'}),
        throwsArgumentError,
      );
    },
  );

  test(
    'recycled ancestors, hidden folders, cycles, orphans and transient media stay hidden',
    () async {
      folders.addAll([
        folder('recycled', recycled: true),
        folder('nested', parent: 'recycled'),
        folder('hidden', hidden: true),
        folder('cycle-a', parent: 'cycle-b'),
        folder('cycle-b', parent: 'cycle-a'),
      ]);
      media.addAll([
        video('good'),
        video('own-recycled', recycled: true),
        video('ancestor-recycled', parent: 'nested'),
        video('hidden', parent: 'hidden'),
        video('cycle', parent: 'cycle-a'),
        video('orphan', parent: 'missing'),
        video('transient')..isTransient = true,
      ]);
      order[null] = ['recycled', 'hidden', 'good', 'own-recycled', 'transient'];
      final reader = source();
      final browse = await reader.callTool('library_browse', {});
      expect((browse['items'] as List).map((item) => item['id']), ['good']);
      final search = await reader.callTool('library_search', {'query': '课程'});
      expect((search['items'] as List).map((item) => item['id']), ['good']);
      for (final item in media.skip(1)) {
        await expectLater(
          reader.callTool('media_info', {'mediaId': item.id}),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'community edition exposes local media while preserving full-edition source behavior',
    () async {
      media.addAll([
        video('local'),
        video('remote', path: 'https://example.com/video.mp4?token=private'),
      ]);
      order[null] = ['local', 'remote'];
      final reader = source();
      final listing = await reader.callTool('library_browse', {});
      final ids = (listing['items'] as List).map((item) => item['id']).toList();
      if (kAppDataFolderName.endsWith('Community')) {
        expect(ids, ['local']);
        await expectLater(
          reader.callTool('media_info', {'mediaId': 'remote'}),
          throwsArgumentError,
        );
      } else {
        expect(ids, ['local', 'remote']);
        final info = await reader.callTool('media_info', {'mediaId': 'remote'});
        expect(info['id'], 'remote');
        expect(jsonEncode(info), isNot(contains('token=private')));
      }
      final local = await reader.callTool('media_info', {'mediaId': 'local'});
      expect(local['id'], 'local');
    },
  );

  test(
    'long transcript pagination returns every cue and never splits emoji pairs',
    () async {
      final text = [
        for (var i = 0; i < 900; i++)
          '${i + 1}\n00:00:01,000 --> 00:00:02,500\n课程第$i段🙂完整文稿\n',
      ].join('\n');
      final subtitle = await File(
        '${directory.path}/lesson.srt',
      ).writeAsString(text);
      media.add(video('lesson', subtitle: subtitle.path));
      final reader = source();
      final listing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final id = (listing['documents'] as List).single['id'];
      expect(id, isNot(contains('lesson.srt')));
      expect(jsonEncode(listing), isNot(contains(directory.path)));
      final first = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
        'limit': 71,
      });
      final all = StringBuffer(first['text']);
      var next = first['nextOffset'];
      final revision = first['revision'];
      while (next != null) {
        final page = await reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
          'offset': next,
          'limit': 71,
          'revision': revision,
        });
        final part = page['text'] as String;
        expect(
          part.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff),
          isFalse,
        );
        all.write(part);
        next = page['nextOffset'];
        if (next == null) expect(page['complete'], isTrue);
      }
      final whole = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
        'limit': 24000,
      });
      expect(all.toString().startsWith(whole['text'] as String), isTrue);
      expect(all.toString(), contains('[1000ms–2500ms] 课程第899段🙂完整文稿'));
      expect('课程第'.allMatches(all.toString()), hasLength(900));
      expect(all.length, first['totalCharacters']);
      await expectLater(
        reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
          'offset': -1,
        }),
        throwsArgumentError,
      );
      await expectLater(
        reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
          'limit': 1000000,
        }),
        throwsArgumentError,
      );
    },
  );

  test(
    'changed revision requires restarting instead of mixing document versions',
    () async {
      final subtitle = await File(
        '${directory.path}/lesson.txt',
      ).writeAsString('原文');
      media.add(video('lesson', subtitle: subtitle.path));
      final reader = source();
      final listing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final id = (listing['documents'] as List).single['id'];
      final first = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
      });
      await subtitle.writeAsString('已经修改的文稿内容');
      await expectLater(
        reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
          'revision': first['revision'],
        }),
        throwsStateError,
      );
      final current = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
      });
      expect(current['text'], '已经修改的文稿内容');
      expect(current['revision'], isNot(first['revision']));
    },
  );

  test(
    'missing files and arbitrary paths/URLs never become readable tool inputs',
    () async {
      final secret = await File(
        '${directory.path}/secret.txt',
      ).writeAsString('不得读取的未关联文稿');
      media.add(video('lesson', subtitle: '${directory.path}/absent.srt'));
      final reader = source();
      final listing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final id = (listing['documents'] as List).single['id'];
      await expectLater(
        reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
        }),
        throwsArgumentError,
      );
      for (final injected in [
        secret.path,
        'file://${secret.path}',
        'https://example.com/secret.txt',
      ]) {
        await expectLater(
          reader.callTool('document_read', {
            'mediaId': 'lesson',
            'documentId': injected,
          }),
          throwsArgumentError,
        );
        await expectLater(
          reader.callTool('media_info', {'mediaId': injected}),
          throwsArgumentError,
        );
      }
      media.single.subtitlePath = 'https://example.com/remote.srt';
      final noRemote = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      expect(noRemote['documents'], isEmpty);
      expect(noRemote['missing'], isTrue);
      ready = false;
      await expectLater(
        reader.callTool('player_overview', {}),
        throwsStateError,
      );
    },
  );

  test(
    'search continues past missing sources and reports when all sources are unavailable',
    () async {
      final absent = '${directory.path}/absent.srt';
      final valid = await File(
        '${directory.path}/valid.txt',
      ).writeAsString('正常文稿中有关键词，仍应检索到。');
      media.add(
        video('lesson', subtitle: absent)..secondarySubtitlePath = valid.path,
      );
      final reader = source();
      final listing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final documents = listing['documents'] as List;
      expect(documents.map((d) => d['available']), [false, true]);
      expect(listing['missing'], isFalse);
      final found = await reader.callTool('document_search', {
        'mediaId': 'lesson',
        'query': '关键词',
      });
      expect((found['items'] as List).single['excerpt'], contains('关键词'));
      expect(found['unavailableDocumentIds'], [documents.first['id']]);
      expect(jsonEncode(found), isNot(contains(directory.path)));
      await valid.delete();
      final allMissing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      expect(allMissing['missing'], isTrue);
      final noHits = await reader.callTool('document_search', {
        'mediaId': 'lesson',
        'query': '关键词',
      });
      expect(noHits['items'], isEmpty);
      expect(noHits['unavailableDocumentIds'], hasLength(2));
    },
  );

  test(
    'same-size timestamp-preserved edits invalidate transcript revision and cache',
    () async {
      final subtitle = await File(
        '${directory.path}/revision.txt',
      ).writeAsString('before');
      final original = await subtitle.stat();
      media.add(video('lesson', subtitle: subtitle.path));
      final reader = source();
      final listing = await reader.callTool('documents_list', {
        'mediaId': 'lesson',
      });
      final id = (listing['documents'] as List).single['id'];
      final first = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
      });
      await subtitle.writeAsString('AFTER!');
      await subtitle.setLastModified(original.modified);
      expect((await subtitle.stat()).size, original.size);
      await expectLater(
        reader.callTool('document_read', {
          'mediaId': 'lesson',
          'documentId': id,
          'offset': 3,
          'revision': first['revision'],
        }),
        throwsStateError,
      );
      final restart = await reader.callTool('document_read', {
        'mediaId': 'lesson',
        'documentId': id,
      });
      expect(restart['text'], 'AFTER!');
      expect(restart['revision'], isNot(first['revision']));
    },
  );

  test(
    'saved conversation changes reject continuation using a stale revision',
    () async {
      media.add(video('lesson'));
      allowConversations = true;
      final records = [
        AiConversation(
          id: 'c',
          videoId: 'lesson',
          title: '对话',
          messages: [
            AiChatMessage(id: 'm', role: 'assistant', content: '生成中的原始内容'),
          ],
        ),
      ];
      final reader = source(store: _Store(records));
      final schema =
          reader.tools.singleWhere(
                (tool) => tool['name'] == 'conversations_read',
              )['inputSchema']
              as Map;
      expect((schema['properties'] as Map).containsKey('revision'), isTrue);
      final first = await reader.callTool('conversations_read', {
        'mediaId': 'lesson',
        'limit': 15,
      });
      records[0] = records[0].copyWith(
        messages: [
          AiChatMessage(id: 'm', role: 'assistant', content: '新保存的完整回答'),
        ],
      );
      await expectLater(
        reader.callTool('conversations_read', {
          'mediaId': 'lesson',
          'offset': first['nextOffset'],
          'revision': first['revision'],
        }),
        throwsStateError,
      );
      final restart = await reader.callTool('conversations_read', {
        'mediaId': 'lesson',
      });
      expect(restart['text'], contains('新保存的完整回答'));
      expect(restart['revision'], isNot(first['revision']));
    },
  );

  test(
    'conversations require separate permission and paginate all messages without drafts/requests/reasoning',
    () async {
      media.add(video('lesson'));
      final record = AiConversation(
        id: 'conversation',
        videoId: 'lesson',
        title: '学习问题',
        draftText: '未发送草稿',
        messages: [
          for (var i = 0; i < 200; i++)
            AiChatMessage(
              id: 'm$i',
              role: i.isEven ? 'user' : 'assistant',
              content: '第$i条正文',
              reasoning: '隐藏思考',
            ),
        ],
      );
      final branch = AiConversation(
        id: 'branch',
        videoId: 'lesson',
        title: '后续分支',
        parentConversationId: record.id,
        parentMessageId: 'm199',
        messages: [AiChatMessage(id: 'next', role: 'user', content: '分支正文')],
      );
      final reader = source(store: _Store([record, branch]));
      expect(
        reader.tools.any((tool) => tool['name'] == 'conversations_read'),
        isFalse,
      );
      await expectLater(
        reader.callTool('conversations_read', {'mediaId': 'lesson'}),
        throwsArgumentError,
      );
      allowConversations = true;
      expect(
        reader.tools.any((tool) => tool['name'] == 'conversations_read'),
        isTrue,
      );
      final all = StringBuffer();
      int? offset = 0;
      while (offset != null) {
        final page = await reader.callTool('conversations_read', {
          'mediaId': 'lesson',
          'offset': offset,
          'limit': 171,
        });
        all.write(page['text']);
        offset = page['nextOffset'] as int?;
      }
      final records = jsonDecode(all.toString()) as List;
      expect(records.first['messages'], hasLength(200));
      expect(records.last['parentConversationId'], record.id);
      expect(all.toString(), isNot(contains('未发送草稿')));
      expect(all.toString(), isNot(contains('隐藏思考')));
      allowConversations = false;
      await expectLater(
        reader.callTool('conversations_read', {'mediaId': 'lesson'}),
        throwsArgumentError,
      );
    },
  );
}
