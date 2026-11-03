import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_video_context.dart';
import 'package:video_player_app/features/ai_chat/ai_context_builder.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';

const srt = '1\n00:00:01,000 --> 00:00:02,000\n已有字幕\n';
VideoItem video(
  String path, {
  String? primary,
  String? secondary,
  List<ManagedSubtitleAsset> assets = const [],
  Map<String, String>? local,
  MediaSourceRef? source,
}) => VideoItem(
  id: 'video',
  path: path,
  title: 'Movie',
  durationMs: 60000,
  lastUpdated: 0,
  subtitlePath: primary,
  secondarySubtitlePath: secondary,
  managedSubtitleAssets: assets,
  localSubtitles: local,
  sourceRef: source,
);
ManagedSubtitleAsset asset(String path, String id) => ManagedSubtitleAsset(
  assetId: id,
  path: path,
  kind: ManagedSubtitleAssetKind.manual,
  displayName: id,
  createdAt: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('metadata-hash names become readable language and source labels', () async {
    final dir = await Directory.systemTemp.createTemp('ai_context_labels_');
    addTearDown(() => dir.delete(recursive: true));
    const internalName = '953e538d-ec89-4772-ae61-f36dd641b40a.srt';
    final subtitle = File(p.join(dir.path, internalName));
    await subtitle.writeAsString(srt);
    final result = await AiVideoContextLoader().load(video: video(
      p.join(dir.path, 'Movie.mp4'),
      assets: [ManagedSubtitleAsset(
        assetId: '953e538d-ec89-4772-ae61-f36dd641b40a',
        path: subtitle.path,
        kind: ManagedSubtitleAssetKind.manual,
        displayName: internalName,
        language: 'zh-Hans',
        createdAt: 0,
      )],
    ));
    final track = result.tracks.single;
    expect(track.label, '手工字幕 · 中文');
    expect(track.sourceDescription, contains('手工编辑'));
    expect(track.sourceDescription, contains('已关联'));
    expect(track.fileName, internalName);
    final prompt = AiContextBuilder().build(video: result, question: '解释字幕', selectedTrackIds: {track.id}, maxCharacters: 1200);
    expect(prompt.text, contains('手工字幕'));
    expect(prompt.text, isNot(contains(internalName)));
    expect(prompt.text, isNot(contains(dir.path)));
  });

  test('fallback names use playback role and readable text language', () async {
    final result = await AiVideoContextLoader().load(
      video: video('virtual://Movie'),
      primarySubtitles: [SubtitleItem(index: 1, startTime: Duration.zero, endTime: const Duration(seconds: 2), text: '未保存的中文字幕')],
      secondarySubtitles: [SubtitleItem(index: 1, startTime: Duration.zero, endTime: const Duration(seconds: 2), text: 'A complete English caption.')],
    );
    expect(result.tracks.map((track) => track.label), ['主字幕 · 中文', '副字幕 · 英语']);
    expect(result.tracks.map((track) => track.role), ['primary', 'secondary']);
    expect(result.tracks.map((track) => track.sourceDescription), everyElement(contains('播放器实时字幕')));
    expect(result.tracks.map((track) => track.fileName), everyElement(isNull));
  });

  test('primarysecondarydefault recommends all readable playback choices', () {
    List<SubtitleItem> text(String value) => [SubtitleItem(index: 1, startTime: Duration.zero, endTime: const Duration(seconds: 60), text: value)];
    final result = AiVideoContext(videoId: 'video', title: 'Movie', tracks: [
      AiSubtitleTrack(id: 'other', label: '另一个完整稿', cues: text('其他字幕')),
      AiSubtitleTrack(id: 'primary', label: '中文', role: 'primary', cues: text('主字幕')),
      AiSubtitleTrack(id: 'secondary', label: 'English', role: 'secondary', cues: text('secondary caption')),
      const AiSubtitleTrack(id: 'bitmap', label: '图片字幕', role: 'secondary', error: '需要 OCR'),
    ]);
    expect(recommendAiSubtitleTracks(result), {'primary', 'secondary'});
    final prompt = AiContextBuilder().build(video: result, question: '介绍', selectedTrackIds: {}, maxCharacters: 1000);
    expect(prompt.selectedChunks, isEmpty, reason: 'recommendations must not override an explicit empty selection');
  });

  test('othersrecommend chooses one complete associated human local-language source', () {
    List<SubtitleItem> text(String value, int seconds) => [SubtitleItem(index: 1, startTime: Duration.zero, endTime: Duration(seconds: seconds), text: value)];
    final manual = AiSubtitleTrack(id: 'manual', label: '课程整理', sourceDescription: '手工编辑 · 已关联 · 中文', cues: text('课程内容' * 200, 600));
    final english = AiSubtitleTrack(id: 'english', label: 'English', sourceDescription: '哔哩哔哩在线 · 人工字幕 · 英语', cues: text('English lesson. ' * 200, 600));
    final short = AiSubtitleTrack(id: 'short', label: '局部草稿', sourceDescription: '手工编辑 · 已关联 · 中文', cues: text('只有开头', 20));
    final automatic = AiSubtitleTrack(id: 'auto', label: '中文', sourceDescription: '哔哩哔哩在线 · 自动生成 · AI 转写', cues: text('自动转写文稿' * 200, 600));
    final garbled = AiSubtitleTrack(id: 'bad', label: '中文', sourceDescription: '手工编辑 · 已关联 · 中文', cues: text('��������', 600), error: '字幕文字疑似乱码');
    final data = AiVideoContext(videoId: 'video', title: 'Movie', metadata: const {'durationMs': 600000, 'preferredLanguage': 'zh-CN'}, tracks: [automatic, short, english, garbled, manual]);
    expect(recommendAiSubtitleTracks(data), {'manual'});
    expect(recommendAiSubtitleTracks(AiVideoContext(videoId: 'video', title: 'Movie', metadata: data.metadata, tracks: [short, automatic])), {'auto'}, reason: 'a tiny manual fragment must not displace a complete transcript');
    expect(recommendAiSubtitleTracks(const AiVideoContext(videoId: 'video', title: 'Movie', tracks: [AiSubtitleTrack(id: 'image', label: '图片', error: '需要 OCR')])), isEmpty);
  });

  test('encoded labels are repaired and duplicate names remain distinguishable', () async {
    final dir = await Directory.systemTemp.createTemp('ai_context_duplicates_');
    addTearDown(() => dir.delete(recursive: true));
    final first = File(p.join(dir.path, 'one.srt'));
    final second = File(p.join(dir.path, 'two.srt'));
    await first.writeAsString(srt);
    await second.writeAsString(srt);
    final data = await AiVideoContextLoader().load(video: video(p.join(dir.path, 'Movie.mp4'), secondary: second.path, assets: [
      ManagedSubtitleAsset(assetId: 'one', path: first.path, kind: ManagedSubtitleAssetKind.imported, displayName: '%E4%B8%AD%E6%96%87', language: 'zh', createdAt: 0),
      ManagedSubtitleAsset(assetId: 'two', path: second.path, kind: ManagedSubtitleAssetKind.imported, displayName: 'ä¸­æ–‡', language: 'zh', createdAt: 0),
    ]));
    expect(data.tracks.first.role, 'secondary');
    expect(data.tracks.map((track) => track.label).toSet().length, 2);
    expect(data.tracks.map((track) => track.label), everyElement(startsWith('中文字幕')));
    expect(data.tracks.map((track) => track.fileName).toSet(), {'one.srt', 'two.srt'});
  });

  test(
    'discovers detached managed local and sidecar files without primary',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai_video_context_');
      addTearDown(() => dir.delete(recursive: true));
      final detached = File(p.join(dir.path, 'detached.srt'));
      final local = File(p.join(dir.path, 'manual.srt'));
      final matching = File(p.join(dir.path, 'Movie.zh-CN.srt'));
      final unrelated = File(p.join(dir.path, 'OtherFilm.srt'));
      for (final file in [detached, local, matching, unrelated]) {
        await file.writeAsString(srt);
      }
      final item = video(
        p.join(dir.path, 'Movie.mp4'),
        assets: [asset(detached.path, '笔记稿')],
        local: {'人工字幕': local.path},
      );
      final result = await AiVideoContextLoader().load(video: item);
      expect(result.tracks.map((track) => track.id).toSet(), {
        AiVideoContextLoader.trackIdForPath(detached.path),
        AiVideoContextLoader.trackIdForPath(local.path),
        AiVideoContextLoader.trackIdForPath(matching.path),
      });
      expect(result.tracks.map((track) => track.role), everyElement('other'));
      expect(result.tracks.map((track) => track.hasText), everyElement(isTrue));
      expect(item.subtitlePath, isNull);
    },
  );

  test(
    'active text overrides saved text and primary secondary IDs stay stable',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai_active_context_');
      addTearDown(() => dir.delete(recursive: true));
      final first = File(p.join(dir.path, 'Movie.srt'));
      final second = File(p.join(dir.path, 'Movie.en.srt'));
      await first.writeAsString(srt);
      await second.writeAsString(srt);
      final item = video(
        p.join(dir.path, 'Movie.mp4'),
        primary: first.path,
        secondary: second.path,
        assets: [asset(first.path, '编辑字幕')],
      );
      final data = await AiVideoContextLoader().load(
        video: item,
        primarySubtitles: [
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
            text: '未保存的实时编辑',
          ),
        ],
      );
      expect(data.tracks.length, 2);
      expect(
        data.tracks
            .singleWhere((track) => track.role == 'primary')
            .cues
            .first
            .text,
        '未保存的实时编辑',
      );
      expect(
        data.tracks.singleWhere((track) => track.role == 'secondary').id,
        AiVideoContextLoader.trackIdForPath(second.path),
      );
    },
  );

  test(
    'file cache reuses parsed cues and invalidates after file changes',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai_context_cache_');
      addTearDown(() => dir.delete(recursive: true));
      final subtitle = File(p.join(dir.path, 'Movie.srt'));
      await subtitle.writeAsString(srt);
      final item = video(p.join(dir.path, 'Movie.mp4'), primary: subtitle.path);
      final loader = AiVideoContextLoader();
      final one = await loader.load(video: item);
      final two = await loader.load(video: item);
      expect(identical(one.tracks.single.cues, two.tracks.single.cues), isTrue);
      await subtitle.writeAsString(srt.replaceFirst('已有字幕', '字幕内容更新且更长'));
      final changed = await loader.load(video: item);
      expect(changed.tracks.single.cues.single.text, '字幕内容更新且更长');
      expect(
        identical(one.tracks.single.cues, changed.tracks.single.cues),
        isFalse,
      );
    },
  );

  test(
    'missing files and bitmap subtitles remain visible with useful errors',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai_context_errors_');
      addTearDown(() => dir.delete(recursive: true));
      final item = video(
        p.join(dir.path, 'Movie.mp4'),
        assets: [
          asset(p.join(dir.path, 'missing.srt'), '丢失'),
          asset(p.join(dir.path, 'bitmap.sup'), '图片'),
        ],
      );
      final result = await AiVideoContextLoader().load(video: item);
      expect(result.tracks.length, 2);
      expect(
        result.tracks.singleWhere((track) => track.label == '丢失').error,
        contains('无法读取'),
      );
      expect(
        result.tracks.singleWhere((track) => track.label == '图片').error,
        contains('OCR'),
      );
    },
  );

  test(
    'Bilibili online subtitles use the existing source without writing or selecting',
    () async {
      final item = video(
        'bilibili://stream/BV1ab411c7mD?cid=42',
        source: const MediaSourceRef(
          value: 'BV1ab411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1ab411c7mD',
          cid: 42,
        ),
      );
      var fetches = 0;
      var writes = 0;
      final service = BilibiliSubtitleTracks(
        source: BilibiliSubtitleTrackSource(
          fetchPublicAnswer: (_, _) async => const BilibiliSubtitleAnswer(
            tracks: [
              BilibiliSubtitleTrack(
                lan: 'zh',
                label: '在线中文',
                isAi: false,
                url: 'https://subtitle.hdslb.com/subtitle.json',
                id: '42',
              ),
            ],
          ),
          fetchLoggedInAnswer: (_, _) async => const BilibiliSubtitleAnswer(),
          isLoggedIn: () async => false,
          fetchContent: (_) async {
            fetches++;
            return {
              'body': [
                {'from': 1.5, 'to': 2.5, 'content': '在线文稿内容'},
              ],
            };
          },
        ),
        store: BilibiliSubtitleTrackStore(
          itemOf: (_) => item,
          noteChanged: (_) async {},
          writeSubtitle: (_, _, _) async {
            writes++;
            return 'must-not-write';
          },
        ),
      );
      addTearDown(service.dispose);
      final loader = AiVideoContextLoader(bilibiliTracks: service);
      final result = await loader.load(video: item);
      final cached = await loader.load(video: item);
      expect(result.tracks.single.cues.single.text, '在线文稿内容');
      expect(result.tracks.single.cues.single.startTime.inMilliseconds, 1500);
      expect(cached.tracks.single.cues, same(result.tracks.single.cues));
      expect(fetches, 1);
      expect(writes, 0);
      expect(item.subtitlePath, isNull);
      expect(item.additionalSubtitles, isNull);
    },
  );

  test(
    'YTDLP metadata keeps descriptive fields and strips request secrets',
    () async {
      const sourceUrl =
          'https://user:password@example.com/video?id=7&token=secret';
      final item = video(
        'virtual://video',
        source: const MediaSourceRef(
          value: sourceUrl,
          kind: MediaSourceKind.url,
        ),
      );
      final task = YtDlpTaskRecord(
        taskId: 'task',
        sourceUrl: sourceUrl,
        selection: const DownloadSelection(),
        createdAtIso: '',
        meta: const VideoMeta(
          id: '7',
          source: 'Example',
          webpageUrl: sourceUrl,
          title: 'Movie',
          uploader: '创作者',
          rawInfo: {
            'description': '视频介绍',
            'tags': ['知识'],
            'cookie': 'SECRET_COOKIE',
            'http_headers': {'Authorization': 'SECRET_AUTH'},
            'url': 'https://cdn.example.com/secret-stream',
          },
        ),
      );
      final result = await AiVideoContextLoader(
        ytDlpTasks: () => [task],
      ).load(video: item);
      expect(result.metadata['importProvider'], 'yt-dlp');
      expect(result.metadata['uploader'], '创作者');
      expect(result.metadata['description'], '视频介绍');
      expect(result.metadata['source'], 'https://example.com/video');
      expect(result.metadata.toString(), isNot(contains('SECRET')));
      expect(result.metadata.toString(), isNot(contains('password')));
      expect(result.metadata.toString(), isNot(contains('token=')));
    },
  );

  test(
    'online subtitle identity survives saving and retains local aliases and live edits',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai_online_identity_');
      addTearDown(() => dir.delete(recursive: true));
      final item = video(
        'bilibili://stream/BV1ab411c7mD?cid=42',
        source: const MediaSourceRef(
          value: 'BV1ab411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1ab411c7mD',
          cid: 42,
        ),
      );
      const remote = BilibiliSubtitleTrack(
        lan: 'zh',
        label: '在线中文',
        isAi: false,
        url: 'https://subtitle.hdslb.com/subtitle.json',
        id: '42',
      );
      final saved = p.join(dir.path, 'saved.srt');
      final service = BilibiliSubtitleTracks(
        source: BilibiliSubtitleTrackSource(
          fetchPublicAnswer: (_, _) async =>
              const BilibiliSubtitleAnswer(tracks: [remote]),
          fetchLoggedInAnswer: (_, _) async => const BilibiliSubtitleAnswer(),
          isLoggedIn: () async => false,
          fetchContent: (_) async => {
            'body': [
              {'from': 1, 'to': 2, 'content': '在线文稿'},
            ],
          },
        ),
        store: BilibiliSubtitleTrackStore(
          itemOf: (_) => item,
          noteChanged: (_) async {},
          writeSubtitle: (_, _, text) async {
            await File(saved).writeAsString(text);
            return saved;
          },
        ),
      );
      addTearDown(service.dispose);
      final loader = AiVideoContextLoader(bilibiliTracks: service);
      final before = await loader.load(video: item);
      expect(await service.load(item.id, remote), saved);
      item.subtitlePath = saved;
      final after = await loader.load(
        video: item,
        primarySubtitles: [
          SubtitleItem(
            index: 1,
            startTime: const Duration(seconds: 1),
            endTime: const Duration(seconds: 2),
            text: '实时编辑的文稿',
          ),
        ],
      );
      expect(after.tracks.length, 1);
      expect(after.tracks.single.id, before.tracks.single.id);
      expect(after.tracks.single.role, 'primary');
      expect(after.tracks.single.cues.single.text, '实时编辑的文稿');
      final fileId = AiVideoContextLoader.trackIdForPath(saved);
      expect(after.tracks.single.aliases, contains(fileId));
      final prompt = AiContextBuilder().build(
        video: after,
        question: '解释文稿',
        selectedTrackIds: {fileId},
        maxCharacters: 1000,
      );
      expect(prompt.text, contains('实时编辑的文稿'));
      expect(prompt.warnings.join(' '), isNot(contains('已不存在')));
    },
  );

  test(
    'all online content requests share a deadline and at most four concurrent slots',
    () async {
      final item = video(
        'bilibili://stream/BV1ab411c7mD?cid=42',
        source: const MediaSourceRef(
          value: 'BV1ab411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1ab411c7mD',
          cid: 42,
        ),
      );
      final tracks = List.generate(
        8,
        (i) => BilibiliSubtitleTrack(
          lan: 'lan$i',
          label: '字幕$i',
          isAi: false,
          url: 'https://subtitle.hdslb.com/$i.json',
          id: '$i',
        ),
      );
      var fetched = 0;
      final stuck = Completer<Object?>();
      final service = BilibiliSubtitleTracks(
        source: BilibiliSubtitleTrackSource(
          fetchPublicAnswer: (_, _) async =>
              BilibiliSubtitleAnswer(tracks: tracks),
          fetchLoggedInAnswer: (_, _) async => const BilibiliSubtitleAnswer(),
          isLoggedIn: () async => false,
          fetchContent: (_) {
            fetched++;
            return stuck.future;
          },
        ),
        store: BilibiliSubtitleTrackStore(
          itemOf: (_) => item,
          noteChanged: (_) async {},
          writeSubtitle: (_, _, _) async => 'must-not-write',
        ),
      );
      addTearDown(() {
        stuck.complete({'body': []});
        service.dispose();
      });
      final loader = AiVideoContextLoader(
        bilibiliTracks: service,
        onlineTimeout: const Duration(milliseconds: 100),
      );
      final watch = Stopwatch()..start();
      final result = await loader.load(video: item);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(result.tracks.length, 8);
      expect(
        result.tracks.map((track) => track.error),
        everyElement(contains('超时')),
      );
      expect(fetched, 4);
      final again = await loader.load(video: item);
      expect(again.tracks.length, 8);
      expect(
        fetched,
        4,
        reason: 'retry backoff prevents another wait on every question',
      );
    },
  );

  test(
    'online listing is bounded and automatic retries use short backoff',
    () async {
      final item = video(
        'bilibili://stream/BV1ab411c7mD?cid=42',
        source: const MediaSourceRef(
          value: 'BV1ab411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1ab411c7mD',
          cid: 42,
        ),
      );
      final listing = Completer<BilibiliSubtitleAnswer>();
      var listingFetches = 0;
      final service = BilibiliSubtitleTracks(
        source: BilibiliSubtitleTrackSource(
          fetchPublicAnswer: (_, _) {
            listingFetches++;
            return listing.future;
          },
          fetchLoggedInAnswer: (_, _) async => const BilibiliSubtitleAnswer(),
          isLoggedIn: () async => false,
          fetchContent: (_) async => {
            'body': [
              {'from': 1, 'to': 2, 'content': '字幕'},
            ],
          },
        ),
        store: BilibiliSubtitleTrackStore(
          itemOf: (_) => item,
          noteChanged: (_) async {},
          writeSubtitle: (_, _, _) async => 'must-not-write',
        ),
      );
      final loader = AiVideoContextLoader(
        bilibiliTracks: service,
        onlineTimeout: const Duration(milliseconds: 50),
      );
      final result = await loader.load(video: item);
      expect(result.metadata['onlineSubtitleWarning'], contains('超时'));
      expect(listingFetches, 1);
      final watch = Stopwatch()..start();
      await loader.load(video: item);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)));
      expect(listingFetches, 1);
      listing.complete(const BilibiliSubtitleAnswer());
      await Future<void>.delayed(Duration.zero);
      service.dispose();
    },
  );
}
