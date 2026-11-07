import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/external_ai/external_ai_guide.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_workspace_context.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';

void main() {
  test(
    'revocation during an asynchronous settings snapshot prevents a late reply',
    () async {
      var prefs = const ExternalAiPreferences(
        token: 'initial',
        enabled: true,
        allowTaskControl: true,
      );
      final waiting = Completer<Map<String, dynamic>>();
      final guide = ExternalAiGuide(
        preferences: () => prefs,
        processingOptions: () => waiting.future,
        subtitleOptions: () async => {
          'current': {'optimizationPrompt': 'private prompt'},
        },
      );
      final response = guide.callTool('player_guide', {});
      prefs = prefs.copyWith(allowTaskControl: false);
      waiting.complete({'serviceId': 'gongyi'});
      await expectLater(response, throwsStateError);
    },
  );
  test(
    'live guide identifies public ASR rather than inferring an installed local model',
    () async {
      final guide = ExternalAiGuide(
        preferences: () => const ExternalAiPreferences(
          token: 'local-test',
          enabled: true,
          allowTaskControl: true,
        ),
        processingOptions: () async => {
          'current': {
            'serviceId': 'gongyi',
            'name': '公益接口',
            'kind': 'gongyi',
            'sourceLanguage': 'auto',
            'requiresLocalModel': false,
            'apiKey': 'DO-NOT-SEND',
          },
          'models': [
            {'id': 'qwen', 'installed': true},
          ],
        },
        subtitleOptions: () async => {
          'current': {
            'optimizationEnabled': false,
            'optimizationPrompt': '保持原语言，纠错',
            'translationProvider': 'bing',
            'translationMode': 'fixed',
            'targetLanguage': 'zh-CN',
          },
        },
      );
      final result = await guide.callTool('player_guide', {});
      final settings = result['currentSettings'] as Map;
      expect(settings['transcription']['kind'], 'gongyi');
      expect(settings['transcription']['requiresLocalModel'], false);
      expect(settings['translation']['translationProvider'], 'bing');
      expect(jsonEncode(result), isNot(contains('DO-NOT-SEND')));
      expect(jsonEncode(result), isNot(contains('qwen')));
      expect(result['optimization'], isNotNull);
      expect(result['queue'], isNotNull);
    },
  );

  test(
    'guide cannot read processing settings without the app task permission',
    () async {
      final guide = ExternalAiGuide(
        preferences: () =>
            const ExternalAiPreferences(token: 'local-test', enabled: true),
        processingOptions: () async => throw StateError('must not read'),
        subtitleOptions: () async => throw StateError('must not read'),
      );
      expect((await guide.currentSettings())['available'], false);
      await expectLater(
        guide.callTool('player_guide', {'path': 'file'}),
        throwsArgumentError,
      );
    },
  );

  test(
    'visible directory and selected subtitle are distinct from playback and protected by folder scope',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-guide-');
      final owner = Object();
      try {
        final caption = await File(
          '${root.path}/lesson.srt',
        ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nTest\n');
        final folder = VideoCollection(
          id: 'folder',
          name: 'visible directory',
          createTime: 0,
        );
        final hidden = VideoCollection(
          id: 'hidden',
          name: 'PRIVATE-FOLDER',
          createTime: 0,
          isHiddenFromFolders: true,
        );
        final item = VideoItem(
          id: 'media',
          title: 'lesson',
          path: '${root.path}/private.mp4',
          parentId: folder.id,
          subtitlePath: caption.path,
          durationMs: 3000,
          lastUpdated: 0,
          managedSubtitleAssets: [
            ManagedSubtitleAsset(
              assetId: 'subtitle',
              path: caption.path,
              kind: ManagedSubtitleAssetKind.manual,
              displayName: 'chosen',
              language: 'en',
              createdAt: 123,
            ),
          ],
        );
        String? scope;
        final source = ExternalAiLibrarySource(
          videos: () => [item],
          folders: () => [folder, hidden],
          children: (_) => [item],
          scopeFolder: () => scope,
        );
        ExternalAiWorkspaceContext.instance.publish(
          owner: owner,
          viewType: ExternalAiWorkspaceView.libraryFolder,
          folderId: folder.id,
        );
        final overview = await source.callTool('player_overview', {});
        expect(overview['activeLibraryContext']['folderId'], folder.id);
        expect(overview['currentMedia'], isNull);
        final listing = await source.callTool('documents_list', {
          'mediaId': item.id,
        });
        final doc = (listing['documents'] as List).single;
        expect(doc['selected'], true);
        expect(doc['createdAt'], 123);
        expect(doc['language'], 'en');
        expect(await source.selectedDocumentId(item.id), doc['id']);
        expect(jsonEncode([overview, listing]), isNot(contains(root.path)));
        expect(source.authorizedMediaInFolder(folderId: folder.id), [item]);
        ExternalAiWorkspaceContext.instance.publish(
          owner: owner,
          viewType: ExternalAiWorkspaceView.libraryFolder,
          folderId: hidden.id,
        );
        expect(source.currentLibraryContext()['available'], false);
        expect(
          jsonEncode(source.currentLibraryContext()),
          isNot(contains('PRIVATE-FOLDER')),
        );
        ExternalAiWorkspaceContext.instance.publish(
          owner: owner,
          viewType: ExternalAiWorkspaceView.libraryRoot,
        );
        scope = folder.id;
        expect(source.currentLibraryContext()['available'], false);
        expect(
          () => source.authorizedMediaInFolder(folderId: hidden.id),
          throwsArgumentError,
        );
      } finally {
        ExternalAiWorkspaceContext.instance.clear(owner);
        await root.delete(recursive: true);
      }
    },
  );
}
