import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';

void main() {
  test('empty storage includes local pages and podcasts with recent last', () {
    expect(
      MediaLibraryRootEntryOrder.parse(''),
      MediaLibraryRootEntryOrder.defaults,
    );
    expect(MediaLibraryRootEntryOrder.defaults, [
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.recent,
    ]);
  });

  test(
    'saved order is preserved and retired video/cloud entries are discarded',
    () {
      expect(
        MediaLibraryRootEntryOrder.parse('recent,folders,continueLearning'),
        [
          MediaLibraryRootEntry.recent,
          MediaLibraryRootEntry.folders,
          MediaLibraryRootEntry.continueLearning,
          MediaLibraryRootEntry.podcasts,
        ],
      );
      expect(MediaLibraryRootEntryOrder.parse('bilibili,recent'), [
        MediaLibraryRootEntry.recent,
        MediaLibraryRootEntry.continueLearning,
        MediaLibraryRootEntry.folders,
        MediaLibraryRootEntry.podcasts,
      ]);
      expect(
        MediaLibraryRootEntryOrder.encode(MediaLibraryRootEntryOrder.defaults),
        'continueLearning,folders,podcasts,recent',
      );
      expect(MediaLibraryRootEntry.bilibili.label, '哔哩哔哩');
      expect(
        MediaLibraryRootEntryX.tryParse('bilibili'),
        MediaLibraryRootEntry.bilibili,
      );
    },
  );

  test('parse fills missing pages and drops unknown tokens', () {
    expect(MediaLibraryRootEntryOrder.parse('recent,nope'), [
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.podcasts,
    ]);
  });

  test(
    'saved podcast order survives while cloud and website pages stay retired',
    () {
      expect(
        MediaLibraryRootEntryOrder.parse(
          'cloudDrive,podcasts,bilibili,folders',
        ),
        [
          MediaLibraryRootEntry.podcasts,
          MediaLibraryRootEntry.folders,
          MediaLibraryRootEntry.continueLearning,
          MediaLibraryRootEntry.recent,
        ],
      );
      expect(MediaLibraryRootEntry.podcasts.isAvailable, isTrue);
      expect(MediaLibraryRootEntry.podcasts.isLocal, isFalse);
      expect(MediaLibraryRootEntry.cloudDrive.isAvailable, isFalse);
      expect(MediaLibraryRootEntry.bilibili.isAvailable, isFalse);
    },
  );

  test('moved uses Flutter onReorder indices', () {
    final order = MediaLibraryRootEntryOrder.defaults;
    expect(MediaLibraryRootEntryOrder.moved(order, oldIndex: 1, newIndex: 0), [
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.recent,
    ]);
    expect(MediaLibraryRootEntryOrder.moved(order, oldIndex: 0, newIndex: 2), [
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.recent,
    ]);
  });
}
