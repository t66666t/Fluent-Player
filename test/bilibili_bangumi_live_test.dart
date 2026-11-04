import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';
import 'package:video_player_app/services/settings_service.dart';

// Opt in with --dart-define=BILIBILI_BANGUMI_LIVE_TEST=true.
// Uses production parsing and HTTP transport in an isolated, logged-out profile.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BILIBILI_BANGUMI_LIVE_TEST');
  const references = {
    '273401': ('学徒 第二季', ['第1集 玩具大赛']),
    '5528791': ('海绵宝宝：皮老板大电影', ['原版', '中文版']),
    '341309': ('咒术回战', ['第1集 两面宿傩']),
    '4280680': ('天赐的声音7', ['第1期 实力歌手组队竞演']),
    '6084344': ('年会不能停！2', ['正片']),
    '673044': ('坏蛋联盟', ['原版', '中文']),
  };
  late Directory root;
  late PathProviderPlatform originalPaths;
  late HttpOverrides? originalHttpOverrides;
  late BilibiliDownloadService service;

  setUpAll(() async {
    if (!enabled) return;
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('bilibili-bangumi-live-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          PlatformProxyResolver.channel,
          (_) async => ['DIRECT'],
        );
    await NetworkHttp.instance.settings.ready;
    await NetworkHttp.instance.settings.setUnifiedMode(NetworkMode.direct);
    service = BilibiliDownloadService();
  });

  tearDownAll(() async {
    if (!enabled) return;
    service.dispose();
    await NetworkHttp.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformProxyResolver.channel, null);
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttpOverrides;
    await root.delete(recursive: true);
  });

  for (final entry in references.entries) {
    test('live ep${entry.key}: titles, episode names and identities', () async {
      final short = (await service.parseSingleLine(
        'https://b23.tv/ep${entry.key}',
      ))!;
      final full = (await service.parseSingleLine(
        'https://www.bilibili.com/bangumi/play/ep${entry.key}',
      ))!;
      expect(short.collectionInfo?.title, entry.value.$1);
      expect(short.videos, isNotEmpty);
      expect(short.videos.length, full.videos.length);
      expect(
        short.videos.take(entry.value.$2.length).map((v) => v.videoInfo.title),
        entry.value.$2,
      );
      for (var i = 0; i < short.videos.length; i++) {
        final video = short.videos[i];
        final comparison = full.videos[i];
        expect(video.videoInfo.title, comparison.videoInfo.title);
        expect(video.videoInfo.bvid, comparison.videoInfo.bvid);
        expect(video.videoInfo.bvid, matches(r'^BV[0-9A-Za-z]{10}$'));
        expect(video.episodes.single.page.cid, greaterThan(0));
        expect(
          video.episodes.single.page.cid,
          comparison.episodes.single.page.cid,
        );
        expect(video.episodes.single.page.part, video.videoInfo.title);
      }
      // Visible in the opt-in test output as a compact verification record.
      // ignore: avoid_print
      print(
        '${entry.key}: ${short.collectionInfo!.title}, '
        '${short.videos.length} entries, '
        '${short.videos.take(3).map((v) => v.videoInfo.title).join(' / ')}',
      );
    }, skip: !enabled);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
