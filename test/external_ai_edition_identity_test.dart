import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/external_ai/external_ai_clients.dart';
import 'package:video_player_app/features/external_ai/external_ai_library_source.dart';
import 'package:video_player_app/features/external_ai/external_ai_preferences.dart';
import 'package:video_player_app/features/external_ai/external_ai_server.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/app_branding.dart';

class _Source extends ExternalAiDataSource {
  @override
  List<Map<String, dynamic>> get tools => [];
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async => {};
}

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the actual edition has a unique product, MCP key and default port', () {
    expect(
      kApplicationId,
      kIsCommunityEdition
          ? 'cn.teezy.fluentplayer.standard'
          : 'cn.teezy.fluentplayer.pro',
    );
    expect(
      kAppDisplayName,
      kIsCommunityEdition ? 'Fluent Player' : 'Fluent Player Pro',
    );
    expect(
      kMcpServerName,
      kIsCommunityEdition ? 'fluent_player' : 'fluent_player_pro',
    );
    expect(
      ExternalAiPreferences.defaultPort,
      kIsCommunityEdition ? 38462 : 38461,
    );
    for (final client in ExternalAiClient.values) {
      final configuration = externalAiClientConfiguration(
        client,
        endpoint: Uri.parse(
          'http://127.0.0.1:${ExternalAiPreferences.defaultPort}/mcp',
        ),
        token: 'own-token',
      );
      if (client == ExternalAiClient.codex) {
        expect(configuration, contains('[mcp_servers.$kMcpServerName]'));
      } else {
        final decoded = jsonDecode(configuration) as Map;
        expect(
          (decoded[client == ExternalAiClient.vsCode ? 'servers' : 'mcpServers']
                  as Map)
              .keys,
          [kMcpServerName],
        );
      }
    }
  });

  test(
    'credentials never adopt another edition and persisted custom ports remain unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mcp-edition-credentials-',
      );
      addTearDown(() => root.delete(recursive: true));
      final otherId = kIsCommunityEdition
          ? 'cn.teezy.fluentplayer.pro'
          : 'cn.teezy.fluentplayer.standard';
      final other = File(p.join(root.path, 'external_ai', '$otherId.json'));
      await other.parent.create(recursive: true);
      final original = jsonEncode(
        const ExternalAiPreferences(
          token: 'other-edition-secret',
          port: 45009,
        ).toJson(),
      );
      await other.writeAsString(original);
      final store = ExternalAiPreferencesStore(root: root);
      final own = await store.load();
      expect(own.token, isNot('other-edition-secret'));
      expect(own.port, ExternalAiPreferences.defaultPort);
      expect(
        await File(
          p.join(root.path, 'external_ai', '$kApplicationId.json'),
        ).exists(),
        isTrue,
      );
      await store.save(own.copyWith(port: 45011));
      expect((await store.load()).port, 45011);
      expect((await store.load()).token, own.token);
      expect(await other.readAsString(), original);
    },
  );

  test(
    'both editions merge into the same JSON client configuration without replacing each other',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-edition-json-');
      addTearDown(() => root.delete(recursive: true));
      for (final client in [
        ExternalAiClient.workBuddy,
        ExternalAiClient.workBuddyAi,
        ExternalAiClient.cursor,
        ExternalAiClient.vsCode,
        ExternalAiClient.geminiCli,
        ExternalAiClient.claudeCode,
      ]) {
        final file = File(p.join(root.path, '${client.name}.json'));
        await file.writeAsString('{"theme":"keep"}');
        for (final (name, port, token) in [
          ('fluent_player', 38462, 'standard-secret'),
          ('fluent_player_pro', 38461, 'pro-secret'),
        ]) {
          await installExternalAiClient(
            client,
            targetFile: file,
            serverName: name,
            endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
            token: token,
          );
        }
        final json = jsonDecode(await file.readAsString()) as Map;
        final servers =
            json[client == ExternalAiClient.vsCode ? 'servers' : 'mcpServers']
                as Map;
        expect(
          servers.keys,
          containsAll(['fluent_player', 'fluent_player_pro']),
        );
        expect(
          servers['fluent_player']['headers']['Authorization'],
          'Bearer standard-secret',
        );
        expect(
          servers['fluent_player_pro']['headers']['Authorization'],
          'Bearer pro-secret',
        );
        expect(json['theme'], 'keep');
        final original = await file.readAsString();
        await expectLater(
          installExternalAiClient(
            client,
            targetFile: file,
            serverName: 'fluent_player',
            endpoint: Uri.parse('http://127.0.0.1:45012/mcp'),
            token: 'replacement',
          ),
          throwsFormatException,
        );
        expect(await file.readAsString(), original);
      }
    },
  );

  test(
    'both Codex entries preserve independent credentials and unrelated TOML',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-edition-toml-');
      addTearDown(() => root.delete(recursive: true));
      final file = File(p.join(root.path, 'config.toml'));
      const original =
          '# Keep comments\nmodel = "existing-model"\n[mcp_servers.other]\ncommand = "keep"\n';
      await file.writeAsString(original);
      for (final (name, port, token) in [
        ('fluent_player', 38462, 'standard-secret'),
        ('fluent_player_pro', 38461, 'pro-secret'),
      ]) {
        await installExternalAiClient(
          ExternalAiClient.codex,
          targetFile: file,
          serverName: name,
          endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
          token: token,
        );
      }
      final merged = await file.readAsString();
      expect(merged, startsWith(original));
      expect(merged, contains('[mcp_servers.fluent_player]'));
      expect(merged, contains('[mcp_servers.fluent_player_pro]'));
      expect(merged, contains('Bearer standard-secret'));
      expect(merged, contains('Bearer pro-secret'));
    },
  );

  test(
    'Codex prefix names coexist in either installation order with CRLF and independent updates',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-install-order-');
      addTearDown(() => root.delete(recursive: true));
      const entries = [
        ('fluent_player', 38462, 'standard-secret'),
        ('fluent_player_pro', 38461, 'pro-secret'),
      ];
      for (final order in [entries, entries.reversed.toList()]) {
        final file = File(p.join(root.path, '${order.first.$1}.toml'));
        const original = '# User settings\r\nmodel = "keep"\r\n';
        await file.writeAsString(original);
        for (final (name, port, token) in order) {
          await installExternalAiClient(
            ExternalAiClient.codex,
            targetFile: file,
            serverName: name,
            endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
            token: token,
          );
        }
        final merged = await file.readAsString();
        expect(merged, startsWith(original));
        expect(merged, contains('[mcp_servers.fluent_player]'));
        expect(merged, contains('[mcp_servers.fluent_player_pro]'));
        for (final (name, port, token) in order.reversed) {
          final repeated = await installExternalAiClient(
            ExternalAiClient.codex,
            targetFile: file,
            serverName: name,
            endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
            token: token,
          );
          expect(repeated.changed, isFalse);
        }
        expect(await file.readAsString(), merged);
      }
    },
  );

  test(
    'legacy full fluent_player entries are never adopted or overwritten by the new standard edition',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-legacy-full-');
      addTearDown(() => root.delete(recursive: true));
      for (final client in [ExternalAiClient.cursor, ExternalAiClient.codex]) {
        final file = File(p.join(root.path, '${client.name}.config'));
        final originals = client == ExternalAiClient.codex
            ? [
                '[mcp_servers.fluent_player]\nurl = "http://127.0.0.1:38461/mcp"\nhttp_headers = { Authorization = "Bearer legacy-full-token" }\n',
                '# BEGIN FLUENT PLAYER MCP fluent_player\n[mcp_servers.fluent_player]\nurl = "http://127.0.0.1:38461/mcp"\nhttp_headers = { Authorization = "Bearer legacy-full-token" }\n# END FLUENT PLAYER MCP fluent_player\n',
                '# BEGIN FLUENT PLAYER MCP fluent_player\n# Application: ${kIsCommunityEdition ? 'cn.teezy.fluentplayer.pro' : 'cn.teezy.fluentplayer.standard'}\n[mcp_servers.fluent_player]\nurl = "http://127.0.0.1:38461/mcp"\n# END FLUENT PLAYER MCP fluent_player\n',
              ]
            : [
                jsonEncode({
                  'mcpServers': {
                    'fluent_player': {
                      'url': 'http://127.0.0.1:38461/mcp',
                      'headers': {'Authorization': 'Bearer legacy-full-token'},
                    },
                  },
                }),
              ];
        for (final original in originals) {
          await file.writeAsString(original);
          await expectLater(
            installExternalAiClient(
              client,
              targetFile: file,
              serverName: 'fluent_player',
              endpoint: Uri.parse('http://127.0.0.1:38462/mcp'),
              token: 'standard-token',
            ),
            throwsFormatException,
          );
          expect(await file.readAsString(), original);
          await installExternalAiClient(
            client,
            targetFile: file,
            serverName: 'fluent_player_pro',
            endpoint: Uri.parse('http://127.0.0.1:38461/mcp'),
            token: 'new-pro-token',
          );
          final updated = await file.readAsString();
          if (client == ExternalAiClient.codex) {
            expect(updated, startsWith(original));
          } else {
            final parsed = jsonDecode(updated) as Map;
            expect(
              parsed['mcpServers']['fluent_player']['headers']['Authorization'],
              'Bearer legacy-full-token',
            );
          }
          expect(updated, contains('new-pro-token'));
        }
      }
    },
  );

  test(
    'real MCP initialize advertises the active product identity and port conflicts fail closed',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      addTearDown(() => HttpOverrides.global = previous);
      final server = ExternalAiServer(
        dataSource: _Source(),
        token: 'own-secret',
      );
      final endpoint = await server.start();
      addTearDown(server.stop);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(endpoint);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer own-secret');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {'protocolVersion': '2025-11-25'},
        }),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      final result =
          (jsonDecode(await utf8.decodeStream(response)) as Map)['result']
              as Map;
      expect(result['serverInfo']['name'], kMcpServerName);
      expect(result['serverInfo']['title'], kAppDisplayName);
      expect(result['instructions'], contains(kApplicationId));
      final other = ExternalAiServer(
        dataSource: _Source(),
        token: 'other-secret',
      );
      addTearDown(other.stop);
      await expectLater(
        other.start(port: endpoint.port),
        throwsA(isA<SocketException>()),
      );
      expect(other.isRunning, isFalse);
      final wrongToken = await client.postUrl(endpoint);
      wrongToken.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer other-secret',
      );
      final rejected = await wrongToken.close();
      expect(rejected.statusCode, 401);
      await rejected.drain<void>();
    },
  );

  test(
    'MCP source visibility preserves local and RSS identities while filtering other community remote media',
    () async {
      const rss = MediaSourceRef(
        kind: MediaSourceKind.podcastEpisode,
        value: 'podcast:episode',
        podcast: PodcastEpisodeRef(
          channelId: 'channel',
          episodeId: 'episode',
          feedUrl: 'https://publisher.test/feed.xml',
          mediaUrl: 'https://cdn.publisher.test/episode.mp3',
        ),
      );
      final media = [
        VideoItem(
          id: 'local',
          title: 'Local',
          path: p.join(Directory.systemTemp.path, 'mcp-local.mp4'),
          durationMs: 0,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'rss',
          title: 'RSS',
          path: 'podcast:episode',
          sourceRef: rss,
          durationMs: 0,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'raw-web',
          title: 'Raw web',
          path: 'https://example.test/video.mp4',
          durationMs: 0,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'mismatched-rss',
          title: 'Mismatched',
          path: 'podcast:other',
          sourceRef: rss,
          durationMs: 0,
          lastUpdated: 0,
        ),
      ];
      final source = ExternalAiLibrarySource(
        videos: () => media,
        folders: () => [],
        children: (_) => media,
        scopeFolder: () => null,
      );
      final result = await source.callTool('library_browse', {});
      final ids = (result['items'] as List).map((e) => e['id']).toList();
      expect(
        ids,
        kIsCommunityEdition
            ? ['local', 'rss']
            : media.map((e) => e.id).toList(),
      );
      final overview = await source.callTool('player_overview', {});
      expect(overview['application'], kApplicationId);
      expect(overview['applicationName'], kAppDisplayName);
    },
  );
}
