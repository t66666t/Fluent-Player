import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

const _filters = [
  'all',
  'unplayed',
  'inProgress',
  'played',
  'favorite',
  'downloaded',
  'hidden',
];

void main() {
  test(
    'one catalog projection preserves every filter count and search result',
    () {
      final store = PodcastStore(sqlite3.openInMemory());
      addTearDown(store.close);
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'i']) {
        store.write(
          'episode',
          id,
          PodcastEpisode(
            id: id,
            channelId: 'channel',
            title: '节目 $id',
            description: id == 'g' ? '内容关键词' : '',
            publishedMs: id.codeUnitAt(0),
            media: const [PodcastMedia(url: 'https://test/episode.mp3')],
          ).toJson(),
          channel: 'channel',
        );
      }
      store.saveState('b', PodcastEpisodeState(positionMs: 100));
      store.saveState('c', PodcastEpisodeState(played: true, positionMs: 100));
      store.saveState(
        'e',
        PodcastEpisodeState(positionMs: 100, favorite: true),
      );
      store.saveState('f', PodcastEpisodeState(played: true, favorite: true));
      store.saveState('i', PodcastEpisodeState(played: true));
      store.setPresentation('d', hidden: true);
      store.setPresentation('i', hidden: true);
      store.setPresentation('b', localTitle: '本地改名');
      final snapshot = PodcastCatalogSnapshot();
      void resolve({
        String filter = 'all',
        String query = '',
        bool hidePlayed = false,
        String sort = 'newest',
      }) {
        final before = store.catalogQueries;
        snapshot.resolve(
          store: store,
          channelId: 'channel',
          filter: filter,
          query: query,
          sort: sort,
          hidePlayed: hidePlayed,
          downloaded: const {'c', 'd', 'g'},
          countFilters: _filters,
        );
        expect(
          store.catalogQueries - before,
          1,
          reason: 'statistics and rows must share one database projection',
        );
      }

      resolve();
      expect(snapshot.counts, {
        'all': 6,
        'unplayed': 2,
        'inProgress': 2,
        'played': 2,
        'favorite': 2,
        'downloaded': 2,
        'hidden': 2,
      });
      expect(snapshot.ids, ['g', 'f', 'e', 'c', 'b', 'a']);
      resolve(hidePlayed: true);
      expect(snapshot.counts['all'], 4);
      expect(snapshot.counts['favorite'], 2);
      expect(snapshot.counts['played'], 2);
      expect(snapshot.ids, ['g', 'e', 'b', 'a']);
      resolve(filter: 'favorite', hidePlayed: true);
      expect(snapshot.ids, ['e']);
      resolve(filter: 'played', hidePlayed: true);
      expect(snapshot.ids, ['f', 'c']);
      resolve(filter: 'hidden');
      expect(snapshot.ids, ['i', 'd']);
      resolve(query: '本地改名');
      expect(snapshot.ids, ['b']);
      expect(
        snapshot.counts['all'],
        6,
        reason: 'search must not narrow the filter badges',
      );
      resolve(query: '内容关键词');
      expect(snapshot.ids, ['g']);
      resolve(sort: 'oldest');
      expect(snapshot.ids, ['a', 'b', 'c', 'e', 'f', 'g']);
      final before = store.catalogQueries;
      snapshot.resolve(
        store: store,
        channelId: 'channel',
        filter: 'all',
        query: '',
        sort: 'oldest',
        hidePlayed: false,
        downloaded: const {'c', 'd', 'g'},
        countFilters: _filters,
      );
      expect(
        store.catalogQueries,
        before,
        reason: 'an unchanged page still reuses its catalog',
      );
    },
  );
}
