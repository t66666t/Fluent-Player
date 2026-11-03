import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_startup.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';

const String srtBody = '1\n00:00:00,000 --> 00:00:02,000\n自动字幕\n';

CloudDriveSubtitleTrack track(
  String id, {
  bool ai = true,
  String label = '中文',
  String uri = 'https://pan.baidu.com/a.srt?sign=1',
}) {
  return CloudDriveSubtitleTrack(
    id: id,
    label: label,
    language: 'zh',
    format: 'srt',
    origin: CloudDriveSubtitleOrigin.provider,
    remoteUri: Uri.parse(uri),
    isAi: ai,
    autoSelect: false,
  );
}

VideoItem cloudItem({String id = 'card', String providerId = 'baidu'}) {
  final source = CloudDriveSourceRef(
    providerId: providerId,
    remoteAccountId: '42',
    driveId: '0',
    fileId: '9',
    pathHint: '/课程/a.mp4',
    revision: 'rev',
  );
  return VideoItem(
    id: id,
    path: source.logicalUri,
    title: '课程',
    durationMs: 2000,
    lastUpdated: 1,
    usesManagedAssociatedSubtitles: true,
    sourceRef: MediaSourceRef(
      value: source.logicalUri,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: source,
    ),
  );
}

CloudDriveSubtitleTrackStore memoryStore(
  Map<String, VideoItem> items,
  Directory root,
) {
  return CloudDriveSubtitleTrackStore(
    itemOf: (id) => items[id],
    cardsSharing: (id) {
      final item = items[id];
      final source = item?.sourceRef?.cloudDrive;
      if (item == null || source == null) return const <VideoItem>[];
      return items.values.where((other) {
        final cloud = other.sourceRef?.cloudDrive;
        if (cloud == null) return false;
        return cloud.sourceKey == source.sourceKey &&
            (cloud.revision ?? '') == (source.revision ?? '');
      }).toList();
    },
    allocate: (id, name) async {
      final directory = Directory(p.join(root.path, id));
      await directory.create(recursive: true);
      return p.join(directory.path, name);
    },
    noteChanged: (_) async {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late VideoItem item;
  late _FakeSource source;
  late CloudDriveSubtitleTracks tracks;
  late MediaPlaybackService service;

  setUp(() async {
    CloudDriveStartup.resetForTest();
    root = await Directory.systemTemp.createTemp('baidu_auto_subs');
    item = cloudItem();
    source = _FakeSource(tracks: [track('human', ai: false), track('zh-ai')]);
    tracks = CloudDriveSubtitleTracks(
      source: source,
      store: memoryStore({item.id: item}, root),
    );
    CloudDriveSubtitleTracks.overrideForTesting = tracks;
    service = MediaPlaybackService.forTesting()..debugSeedCurrentItem(item);
  });

  tearDown(() async {
    CloudDriveSubtitleTracks.overrideForTesting = null;
    service.debugSeedCurrentItem(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'first open downloads exactly one ordinary official track and shows it',
    () async {
      final outcome = await service.debugEnsureAutoOfficialSubtitle(item);

      expect(outcome.status, CloudDriveAutoSubtitleStatus.applied);
      expect(outcome.reason, CloudDriveAutoSubtitleSkipReason.none);
      expect(outcome.trackId, 'human');
      expect(source.officialCalls, 1);
      expect(source.textCalls, 1);
      expect(service.subtitlePaths, hasLength(1));
      expect(service.subtitles, isNotEmpty);
      expect(service.secondarySubtitles, isEmpty);
      expect(service.cloudDriveSubtitleStatus, isNull);

      final saved = tracks
          .listFor(item.id)
          .tracks
          .where((row) => row.savedPath != null)
          .toList();
      expect(saved, hasLength(1));
      expect(saved.single.isAi, isFalse);
      expect(item.managedSubtitleAssets.single.machineGenerated, isFalse);
    },
  );

  test('Quark first open uses the same AI subtitle loading pipeline', () async {
    final quark = cloudItem(id: 'quark', providerId: 'quark');
    final quarkSource = _FakeSource(tracks: [track('quark-ai-cn')]);
    final quarkTracks = CloudDriveSubtitleTracks(
      source: quarkSource,
      store: memoryStore({quark.id: quark}, root),
    );
    CloudDriveSubtitleTracks.overrideForTesting = quarkTracks;
    service.debugSeedCurrentItem(quark);
    final result = await service.debugEnsureAutoOfficialSubtitle(quark);
    expect(result.status, CloudDriveAutoSubtitleStatus.applied);
    expect(quarkSource.officialCalls, 1);
    expect(quarkSource.textCalls, 1);
    expect(service.subtitles.single.text, '自动字幕');
    expect(quark.managedSubtitleAssets.single.machineGenerated, isTrue);
  });

  test(
    're-entering restores the local file without a directory or body',
    () async {
      await service.debugEnsureAutoOfficialSubtitle(item);
      final firstPath = service.subtitlePaths.single;

      source.officialCalls = 0;
      source.textCalls = 0;
      final freshTracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item}, root),
      );
      CloudDriveSubtitleTracks.overrideForTesting = freshTracks;
      final reopened = MediaPlaybackService.forTesting()
        ..debugSeedCurrentItem(item);

      final outcome = await reopened.debugEnsureAutoOfficialSubtitle(item);

      expect(outcome.status, CloudDriveAutoSubtitleStatus.applied);
      expect(outcome.reason, CloudDriveAutoSubtitleSkipReason.cached);
      expect(source.officialCalls, 0);
      expect(source.textCalls, 0);
      expect(reopened.subtitlePaths, <String>[firstPath]);
      reopened.debugSeedCurrentItem(null);
    },
  );

  test(
    'a manual selection while the body is downloading is not overwritten',
    () async {
      final gate = Completer<void>();
      source.textGate = gate;

      final auto = service.debugEnsureAutoOfficialSubtitle(item);
      for (var i = 0; i < 200 && source.textCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(source.textCalls, 1);

      final manual = File(p.join(root.path, 'manual.srt'));
      await manual.writeAsString('1\n00:00:00,000 --> 00:00:02,000\n手动字幕\n');
      final generationBefore = service.subtitleIntentGenerationForTest;
      final applied = await service.loadSubtitlePathsForCurrentItem(
        itemId: item.id,
        paths: <String>[manual.path],
      );
      expect(applied, isTrue);
      expect(
        service.subtitleIntentGenerationForTest,
        greaterThan(generationBefore),
      );

      gate.complete();
      final outcome = await auto;

      expect(outcome.status, CloudDriveAutoSubtitleStatus.skipped);
      expect(service.subtitlePaths, <String>[manual.path]);
      expect(service.subtitles.single.text, contains('手动字幕'));
      expect(
        service.subtitles.any((cue) => cue.text.contains('自动字幕')),
        isFalse,
      );
    },
  );

  test('a cleared subtitle is never filled in again', () async {
    item.blockAutoAssociatedSubtitleSelection = true;
    final outcome = await service.debugEnsureAutoOfficialSubtitle(item);
    expect(outcome.status, CloudDriveAutoSubtitleStatus.preserved);
    expect(outcome.reason, CloudDriveAutoSubtitleSkipReason.disabled);
    expect(source.officialCalls, 0);
    expect(service.subtitlePaths, isEmpty);
  });

  test(
    'a missing manual file keeps the manual intent, not another AI track',
    () async {
      item.subtitlePath = p.join(root.path, 'gone.srt');
      final outcome = await service.debugEnsureAutoOfficialSubtitle(item);
      expect(outcome.status, CloudDriveAutoSubtitleStatus.preserved);
      expect(outcome.reason, CloudDriveAutoSubtitleSkipReason.manual);
      expect(source.officialCalls, 0);
      expect(source.textCalls, 0);
      expect(service.subtitlePaths, isEmpty);
      expect(service.cloudDriveSubtitleStatus, contains('缺失'));
    },
  );

  test(
    'an unreachable runtime reports not ready instead of doing nothing',
    () async {
      CloudDriveSubtitleTracks.overrideForTesting = null;
      final outcome = await service.debugEnsureAutoOfficialSubtitle(item);
      expect(outcome.status, CloudDriveAutoSubtitleStatus.failed);
      expect(outcome.reason, CloudDriveAutoSubtitleSkipReason.notReady);
      expect(outcome.detail, isNotNull);
    },
  );

  test(
    'a corrupt saved copy is fetched once more instead of looping',
    () async {
      await service.debugEnsureAutoOfficialSubtitle(item);
      final path = service.subtitlePaths.single;
      await File(path).writeAsString('这不是字幕', flush: true);

      source.officialCalls = 0;
      source.textCalls = 0;
      final freshTracks = CloudDriveSubtitleTracks(
        source: source,
        store: memoryStore({item.id: item}, root),
      );
      CloudDriveSubtitleTracks.overrideForTesting = freshTracks;
      final again = MediaPlaybackService.forTesting()
        ..debugSeedCurrentItem(item);

      final outcome = await again.debugEnsureAutoOfficialSubtitle(item);

      expect(outcome.status, CloudDriveAutoSubtitleStatus.applied);
      expect(source.officialCalls, 1);
      expect(source.textCalls, 1);
      expect(await File(path).readAsString(), contains('自动字幕'));
      again.debugSeedCurrentItem(null);
    },
  );

  test('two cards of one cloud file share a single download', () async {
    final sibling = cloudItem(id: 'sibling');
    final items = <String, VideoItem>{item.id: item, sibling.id: sibling};
    final shared = CloudDriveSubtitleTracks(
      source: source,
      store: memoryStore(items, root),
    );
    await shared.ensureLoaded(item.id);
    final row = shared
        .listFor(item.id)
        .tracks
        .singleWhere((candidate) => candidate.id == 'zh-ai');
    final results = await Future.wait(<Future<String?>>[
      shared.load(item.id, row),
      shared.load(sibling.id, row),
    ]);
    expect(source.textCalls, 1);
    expect(results.first, results.last);
    expect(sibling.managedSubtitleAssets, hasLength(1));
  });
}

class _FakeSource implements CloudDriveSubtitleTrackSource {
  _FakeSource({required this.tracks});

  final List<CloudDriveSubtitleTrack> tracks;
  final _LoginChanges changes = _LoginChanges();

  @override
  Listenable? get loginChanges => changes;

  @override
  int generation = 1;

  int officialCalls = 0;
  int textCalls = 0;
  Completer<void>? textGate;

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(
    VideoItem item,
  ) async {
    officialCalls++;
    return CloudDriveOfficialSubtitleDiscovery(
      status: CloudDriveOfficialSubtitleStatus.ready,
      tracks: tracks,
    );
  }

  @override
  Future<String> fetchText(
    VideoItem item,
    CloudDriveSubtitleTrack track,
  ) async {
    textCalls++;
    final gate = textGate;
    if (gate != null) await gate.future;
    return srtBody;
  }
}

class _LoginChanges extends ChangeNotifier {}
