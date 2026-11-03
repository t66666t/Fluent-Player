import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_audio_quality.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_audio_selection.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';

StreamItem _audio(
  int id,
  String codec,
  int bandwidth, {
  bool available = true,
}) => StreamItem(
  id: id,
  baseUrl: available ? 'https://upos-test.bilivideo.com/$id' : '',
  codecs: codec,
  codecid: 0,
  bandwidth: bandwidth,
  mimeType: 'audio/mp4',
);

final _aac = _audio(30280, 'mp4a.40.2', 192000);
final _lowAac = _audio(30216, 'mp4a.40.5', 64000);
final _flac = _audio(30251, 'fLaC', 1700000);
final _dolby = _audio(30250, 'ec-3', 1024000);

BilibiliDownloadTask _task(List<BilibiliDownloadEpisode> episodes) {
  final video = BilibiliVideoInfo(
    title: 'Audio',
    desc: '',
    pic: '',
    bvid: 'BVtest',
    aid: '1',
    ownerName: 'UP',
    ownerMid: '1',
    pubDate: 0,
    pages: episodes.map((e) => e.page).toList(),
  );
  return BilibiliDownloadTask(
    singleVideoInfo: video,
    videos: [BilibiliVideoItem(videoInfo: video, episodes: episodes)],
  );
}

BilibiliDownloadEpisode _episode(int cid) => BilibiliDownloadEpisode(
  page: BilibiliPage(cid: cid, page: cid, part: 'P$cid', duration: 3),
  bvid: 'BVtest',
  availableAudioQualities: [_aac, _lowAac, _flac, _dolby],
  selectedAudioQuality: _aac,
);

class _AudioApi extends BilibiliApiService {
  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async =>
      BilibiliStreamInfo(
        videoStreams: [],
        audioStreams: [_aac, _flac, _dolby],
        qualityMap: {},
      );
  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async => const BilibiliPlayerMetadata(subtitles: [], chapters: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ordinary codecs and AAC bitrates alone never create an audio menu', () {
    expect(
      bilibiliAudioMenuTracks([
        _aac,
        _lowAac,
        _audio(30232, 'mp4a.40.2', 128000),
        _audio(30299, 'opus', 256000),
      ]),
      isEmpty,
    );
    expect(
      bilibiliAudioMenuTracks([
        _aac,
        _audio(30251, 'fLaC', 1700000, available: false),
      ]),
      isEmpty,
    );
  });

  test(
    'special audio menus collapse formats and offer one ordinary fallback',
    () {
      final menu = bilibiliAudioMenuTracks([
        _lowAac,
        _audio(30232, 'mp4a.40.2', 128000),
        _flac,
        _dolby,
        _aac,
        _audio(30251, 'fLaC', 900000),
        _audio(30299, 'opus', 256000),
      ]);
      expect(
        menu.map((track) => BilibiliAudioQuality.fromStream(track).label),
        ['Hi-Res无损', '杜比全景声', '普通音质'],
      );
      expect(menu.last, same(_aac));
    },
  );

  test(
    'audio preference ranks fidelity and spatial formats independently of list order or bitrate',
    () {
      final hugeAac = _audio(30280, 'mp4a.40.2', 9000000);
      final tracks = [_lowAac, hugeAac, _dolby, _flac];
      expect(selectBilibiliAudioTrack(tracks)?.id, 30251);
      expect(
        selectBilibiliAudioTrack(
          tracks,
          preference: BilibiliAudioPreference.dolby,
        )?.id,
        30250,
      );
      expect(
        selectBilibiliAudioTrack(
          tracks,
          preference: BilibiliAudioPreference.standard,
        ),
        same(hugeAac),
      );
      expect(
        selectBilibiliAudioTrack(tracks, preferredId: 30216),
        same(_lowAac),
      );
      expect(selectBilibiliAudioTrack([_aac, _dolby])?.id, 30250);
      expect(
        selectBilibiliAudioTrack([
          _aac,
        ], preference: BilibiliAudioPreference.dolby),
        same(_aac),
      );
      expect(
        selectBilibiliAudioTrack([
          _flac,
        ], preference: BilibiliAudioPreference.standard),
        same(_flac),
      );
    },
  );

  test(
    'permission flags without playable audio URLs cannot win automatic selection',
    () {
      final unavailableFlac = _audio(30251, 'fLaC', 9000000, available: false);
      expect(selectBilibiliAudioTrack([unavailableFlac, _aac]), same(_aac));
      expect(selectBilibiliAudioTrack([unavailableFlac]), isNull);
      final backup = StreamItem(
        id: 30251,
        baseUrl: '',
        backupUrls: ['https://backup.bilivideo.com/audio'],
        codecs: 'fLaC',
        codecid: 0,
        bandwidth: 1000,
      );
      expect(selectBilibiliAudioTrack([_aac, backup]), same(backup));
    },
  );

  test('audio facts survive task persistence and legacy tasks still load', () {
    final episode = _episode(1)
      ..selectedAudioQuality = _dolby
      ..downloadedAudioQuality = _flac;
    final json = episode.toJson();
    final restored = BilibiliDownloadEpisode.fromJson(json);
    expect(restored.selectedAudioQuality?.id, 30250);
    expect(restored.downloadedAudioQuality?.id, 30251);
    expect(restored.availableAudioQualities, hasLength(4));
    json.remove('selectedAudioQuality');
    json.remove('downloadedAudioQuality');
    json.remove('availableAudioQualities');
    final old = BilibiliDownloadEpisode.fromJson(json);
    expect(old.selectedAudioQuality, isNull);
    expect(old.downloadedAudioQuality, isNull);
    expect(old.availableAudioQualities, isEmpty);
  });

  test(
    'download audio defaults, preferences and invalid saved values persist independently of streaming',
    () async {
      final service = BilibiliDownloadService();
      addTearDown(service.dispose);
      await service.loadSettingsForTesting();
      expect(
        service.preferredAudioQuality,
        BilibiliAudioPreference.bestAvailable,
      );
      await service.updateSettings(
        1,
        80,
        'zh',
        false,
        false,
        audioQuality: BilibiliAudioPreference.dolby,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bilibili_preferred_audio_quality'), 'dolby');
      expect(prefs.containsKey('bilibili_stream_preferred_audio'), isFalse);
      final reopened = BilibiliDownloadService();
      addTearDown(reopened.dispose);
      await reopened.loadSettingsForTesting();
      expect(reopened.preferredAudioQuality, BilibiliAudioPreference.dolby);
      await prefs.setString(
        'bilibili_preferred_audio_quality',
        'future-unknown-format',
      );
      await reopened.loadSettingsForTesting();
      expect(
        reopened.preferredAudioQuality,
        BilibiliAudioPreference.bestAvailable,
      );
    },
  );

  test(
    'settings update only untouched pending audio, preserving queued work and checkpoints',
    () async {
      final service = BilibiliDownloadService();
      addTearDown(service.dispose);
      final pending = _episode(1);
      final resumed = _episode(2)
        ..status = DownloadStatus.failed
        ..canResume = true
        ..audioResumeState = const DownloadPartResumeState(
          tempPath: 'saved.m4s',
          downloadedBytes: 42,
          totalBytes: 100,
          streamId: 30280,
          codecid: 0,
          codecs: 'mp4a.40.2',
        );
      final queued = _episode(3)..status = DownloadStatus.queued;
      final completed = _episode(4)
        ..status = DownloadStatus.completed
        ..outputPath = 'finished.mp4'
        ..downloadedAudioQuality = _flac;
      final checkpoint = resumed.audioResumeState!.toJson();
      service.replaceTasksForTesting([
        _task([pending, resumed, queued, completed]),
      ]);
      await service.updateSettings(
        1,
        80,
        'zh',
        false,
        false,
        audioQuality: BilibiliAudioPreference.dolby,
      );
      expect(pending.selectedAudioQuality?.id, 30250);
      expect(resumed.selectedAudioQuality?.id, 30280);
      expect(resumed.audioResumeState!.toJson(), checkpoint);
      expect(queued.selectedAudioQuality?.id, 30280);
      expect(completed.downloadedAudioQuality?.id, 30251);
      expect(service.canSelectEpisodeAudio(resumed), isFalse);
      expect(service.canSelectEpisodeAudio(queued), isFalse);
    },
  );

  test(
    'metadata refresh keeps a manual audio choice and the exact resumed representation',
    () async {
      final service = BilibiliDownloadService(apiService: _AudioApi());
      addTearDown(service.dispose);
      final manual = _episode(1)..selectedAudioQuality = _dolby;
      final resumed = _episode(2)
        ..canResume = true
        ..audioResumeState = const DownloadPartResumeState(
          tempPath: 'saved.m4s',
          downloadedBytes: 42,
          streamId: 30280,
          codecid: 0,
          codecs: 'mp4a.40.2',
        );
      service.replaceTasksForTesting([
        _task([manual, resumed]),
      ]);
      await service.fetchEpisodeInfo(manual);
      await service.fetchEpisodeInfo(resumed);
      expect(manual.selectedAudioQuality?.id, 30250);
      expect(resumed.selectedAudioQuality?.id, 30280);
      expect(resumed.audioResumeState?.downloadedBytes, 42);
    },
  );
}
