import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_library_continue_policy.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_activity_projection.dart';

void main() {
  test(
    'combined sections match separate queries across mixed libraries and policies',
    () {
      final random = Random(763);
      final now = DateTime.utc(2026, 10, 22);
      for (var round = 0; round < 40; round++) {
        final folders = {
          for (var i = 0; i < 10; i++)
            'f$i': VideoCollection(
              id: 'f$i',
              name: 'f$i',
              createTime: 1,
              isRecycled: i % 4 == 0,
              parentId: i == 9 ? 'f9' : null,
            ),
        };
        final items = {
          for (var i = 0; i < 150; i++)
            'v$i': VideoItem(
              id: 'v$i',
              path: '/meta/$i.mp4',
              title: '$i',
              durationMs: random.nextInt(200000),
              lastUpdated: 1,
              lastPositionMs: random.nextInt(120000),
              isRecycled: random.nextInt(10) == 0,
              parentId: i % 5 == 0 ? null : 'f${i % 10}',
            ),
        };
        final store = LibraryActivityStore(
          media: {
            for (final item in items.values)
              if (random.nextInt(10) != 0)
                item.id: MediaActivityRecord(
                  mediaId: item.id,
                  lastPlayedAtMs: random.nextBool()
                      ? null
                      : now.millisecondsSinceEpoch -
                            random.nextInt(40) * 86400000,
                  accumulatedWatchMs: random.nextInt(180000),
                  completed: random.nextInt(4) == 0,
                  hidden: random.nextInt(10) == 0,
                ),
          },
          pinnedIds: ['f1', 'v1', 'v2', 'v10'],
        );
        var enumerations = 0;
        final projection = LibraryActivityProjection(
          store: store,
          videoOf: (id) => items[id],
          collectionOf: (id) => folders[id],
          allVideos: () {
            enumerations++;
            return items.values;
          },
        );
        for (final mode in ContinueWatchCombineMode.values) {
          final policy = ContinueWatchPolicy.defaults.copyWith(
            combineMode: mode,
            minWatchMs: round.isEven ? 0 : 30000,
            maxAgeDays: round % 3 == 0 ? 14 : 0,
            excludeCompleted: round.isEven,
            minProgressFraction: round.isEven ? 0 : .2,
          );
          final expectedRecent = projection.continueLearningGroups(
            policy: policy,
            now: now,
          );
          final expectedUnknown = projection.continueLearningGroups(
            policy: policy,
            now: now,
            unknownPlayedOnly: true,
          );
          enumerations = 0;
          final combined = projection.continueLearningSections(
            policy: policy,
            now: now,
          );
          expect(enumerations, 1);
          Object rows(List<ContinueLearningGroup> groups) => [
            for (final group in groups) [group.rowId, group.mediaIds],
          ];
          expect(rows(combined.recent), rows(expectedRecent));
          expect(rows(combined.unknown), rows(expectedUnknown));
        }
      }
    },
  );
}
