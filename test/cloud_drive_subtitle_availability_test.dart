import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/providers/cloud_drive_provider.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/widgets/cloud_drive_subtitle_tracks_section.dart';

class _Source extends CloudDriveSubtitleTrackSource {
  _Source(this.status);
  final CloudDriveOfficialSubtitleStatus status;
  int calls = 0;
  @override
  int get generation => 1;
  @override
  Listenable? get loginChanges => null;
  @override
  Future<CloudDriveOfficialSubtitleDiscovery> fetchOfficial(
    VideoItem item,
  ) async {
    calls++;
    return CloudDriveOfficialSubtitleDiscovery(status: status);
  }

  @override
  Future<String> fetchText(VideoItem item, CloudDriveSubtitleTrack track) =>
      throw StateError('No subtitle was selected');
}

const _ref = CloudDriveSourceRef(
  providerId: 'uc',
  remoteAccountId: 'account',
  driveId: '0',
  fileId: 'video',
);

VideoItem _item() => VideoItem(
  id: 'uc-card',
  path: _ref.logicalUri,
  title: 'UC video',
  durationMs: 1000,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: _ref.logicalUri,
    kind: MediaSourceKind.cloudDrive,
    cloudDrive: _ref,
  ),
);

CloudDriveSubtitleTracks _tracks(VideoItem item, _Source source) =>
    CloudDriveSubtitleTracks(
      source: source,
      store: CloudDriveSubtitleTrackStore(
        itemOf: (id) => id == item.id ? item : null,
        cardsSharing: (_) => [item],
        allocate: (_, _) async => throw StateError('No file should be created'),
        noteChanged: (_) async {},
      ),
    );

void main() {
  test(
    'unsupported discovery is not a confirmed empty subtitle directory',
    () async {
      final source = _Source(CloudDriveOfficialSubtitleStatus.unsupported);
      final item = _item();
      final tracks = _tracks(item, source);
      addTearDown(tracks.dispose);
      await tracks.ensureLoaded(item.id);
      final list = tracks.listFor(item.id);
      expect(list.unsupported, isTrue);
      expect(list.listed, isFalse);
      expect(list.emptyMessage, isNull);
      await tracks.ensureLoaded(item.id);
      expect(source.calls, 1);
    },
  );

  test(
    'a successful empty directory still reports no official subtitles',
    () async {
      final item = _item();
      final tracks = _tracks(
        item,
        _Source(CloudDriveOfficialSubtitleStatus.ready),
      );
      addTearDown(tracks.dispose);
      await tracks.ensureLoaded(item.id);
      final list = tracks.listFor(item.id);
      expect(list.unsupported, isFalse);
      expect(list.listed, isTrue);
      expect(list.emptyMessage, '这个视频没有官方字幕');
    },
  );

  testWidgets('UC explains missing integration while keeping saved subtitles', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'uc_subtitle_availability_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final saved = File(p.join(root.path, 'saved.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n字幕\n');
    final item = _item()
      ..managedSubtitleAssets = [
        ManagedSubtitleAsset(
          assetId: cloudOfficialAssetId(_ref, 'saved'),
          path: saved.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: 'Saved AI',
          createdAt: 0,
          machineGenerated: true,
        ),
      ];
    final tracks = _tracks(
      item,
      _Source(CloudDriveOfficialSubtitleStatus.unsupported),
    );
    addTearDown(tracks.dispose);
    await tracks.ensureLoaded(item.id);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudDriveSubtitleTracksSection(
            itemId: item.id,
            tracks: tracks,
            onPick: (_) {},
            savedRow: (track) => Text(track.label),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂未接入UC网盘的官方／AI字幕'), findsOneWidget);
    expect(find.text('这个视频没有官方字幕'), findsNothing);
    expect(find.text('Saved AI'), findsOneWidget);
  });
}
