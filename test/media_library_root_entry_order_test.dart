import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';

void main() {
  test('empty storage uses folders in the middle', () {
    expect(
      MediaLibraryRootEntryOrder.parse(''),
      MediaLibraryRootEntryOrder.defaults,
    );
    expect(MediaLibraryRootEntryOrder.defaults, [
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]);
  });

  test('saved three-page order keeps its order and appends bilibili', () {
    expect(
      MediaLibraryRootEntryOrder.parse('recent,folders,continueLearning'),
      [
        MediaLibraryRootEntry.recent,
        MediaLibraryRootEntry.folders,
        MediaLibraryRootEntry.continueLearning,
        MediaLibraryRootEntry.bilibili,
        MediaLibraryRootEntry.podcasts,
        MediaLibraryRootEntry.cloudDrive,
      ],
    );
    expect(MediaLibraryRootEntryOrder.parse('bilibili,recent'), [
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]);
    expect(
      MediaLibraryRootEntryOrder.encode(MediaLibraryRootEntryOrder.defaults),
      'continueLearning,folders,recent,bilibili,podcasts,cloudDrive',
    );
    expect(MediaLibraryRootEntry.bilibili.label, '哔哩哔哩');
    expect(
      MediaLibraryRootEntryX.tryParse('bilibili'),
      MediaLibraryRootEntry.bilibili,
    );
  });

  test('parse fills missing pages and drops unknown tokens', () {
    expect(MediaLibraryRootEntryOrder.parse('recent,nope'), [
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]);
  });

  test('moved uses Flutter onReorder indices', () {
    final order = MediaLibraryRootEntryOrder.defaults;
    expect(MediaLibraryRootEntryOrder.moved(order, oldIndex: 1, newIndex: 0), [
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]);
    expect(MediaLibraryRootEntryOrder.moved(order, oldIndex: 0, newIndex: 2), [
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.bilibili,
      MediaLibraryRootEntry.podcasts,
      MediaLibraryRootEntry.cloudDrive,
    ]);
  });
}
