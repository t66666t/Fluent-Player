import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_feed_parser.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_settings.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';

String podcastFixture({
  String title = '频道',
  String media = 'https://example.com/audio.mp3',
  String guid = 'stable',
  bool second = false,
}) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:p="https://podcastindex.org/namespace/1.0"><channel><title>$title</title><description><![CDATA[<p>频道介绍</p>]]></description><itunes:author>主播</itunes:author><itunes:image href="/cover.jpg"/>
<item><title>第一集</title><guid>$guid</guid><pubDate>Fri, 16 Oct 2026 12:30:00 +0800</pubDate><itunes:duration>01:02:03</itunes:duration><itunes:season>2</itunes:season><itunes:episode>3</itunes:episode><enclosure url="$media" type="audio/mpeg" length="1024"/><p:alternateEnclosure type="video/mp4" title="视频版"><p:source uri="https://example.com/video.mp4"/></p:alternateEnclosure><p:transcript url="/transcript.vtt" type="text/vtt"/><p:chapters url="/chapters.json" type="application/json+chapters"/></item>
${second ? '<item><title>新的一集</title><guid>second</guid><enclosure url="https://example.com/second.mp3" type="audio/mpeg"/></item>' : ''}</channel></rss>''';
void main() {
  test('Podcasting 2.0 JSON transcripts preserve their timed captions', () {
    final srt = podcastJsonTranscriptToSrt(
      jsonEncode({
        'segments': [
          {'startTime': 1.25, 'endTime': 4.5, 'body': '<p>你好，世界</p>'},
          {'startTime': 8, 'endTime': 7, 'body': 'invalid'},
        ],
      }),
    );
    expect(srt, contains('00:00:01,250 --> 00:00:04,500'));
    expect(srt, contains('你好，世界'));
    expect(srt, isNot(contains('invalid')));
    expect(() => podcastJsonTranscriptToSrt('{}'), throwsFormatException);
  });
  const parser = PodcastFeedParser();
  PodcastFeed feed({
    bool second = false,
    String media = 'https://example.com/audio.mp3',
  }) => parser.parse(
    utf8.encode(podcastFixture(second: second, media: media)),
    'https://example.com/rss',
    nowMs: 100,
  );
  test(
    'RSS parses namespaces, audio/video versions, timestamps and supplementary assets',
    () {
      final parsed = feed(), episode = parsed.episodes.single;
      expect(parsed.channel.title, '频道');
      expect(parsed.channel.author, '主播');
      expect(parsed.channel.imageUrl, 'https://example.com/cover.jpg');
      expect(episode.durationMs, 3723000);
      expect(
        episode.publishedMs,
        DateTime.utc(2026, 10, 16, 4, 30).millisecondsSinceEpoch,
      );
      expect(episode.season, 2);
      expect(episode.number, 3);
      expect(episode.media.length, 2);
      expect(episode.preferredMedia('video').isVideo, isTrue);
      expect(
        episode.transcripts.single.url,
        'https://example.com/transcript.vtt',
      );
      expect(episode.chaptersUrl, 'https://example.com/chapters.json');
    },
  );
  test(
    'Atom enclosures and author work without depending on a namespace prefix',
    () {
      final value = parser.parse(
        utf8.encode(
          '<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title><author><name>作者</name></author><entry><id>urn:1</id><title>一集</title><published>2026-10-16T04:30:00Z</published><link rel="enclosure" href="/one.opus" type="audio/ogg"/></entry></feed>',
        ),
        'https://example.com/feed',
      );
      expect(
        value.episodes.single.media.single.url,
        'https://example.com/one.opus',
      );
      expect(value.channel.author, '作者');
    },
  );
  test('GUID retains identity across title and enclosure URL updates', () {
    final first = feed();
    final later = parser.parse(
      utf8.encode(
        podcastFixture(title: '新名字', media: 'https://example.com/new.mp3'),
      ),
      'https://example.com/new-rss',
      channelId: first.channel.id,
    );
    expect(first.episodes.single.id, later.episodes.single.id);
  });
  test(
    'duplicate episodes are not duplicated and non-media articles are omitted',
    () {
      var xml = podcastFixture();
      final item = RegExp(
        r'<item>.*?</item>',
        dotAll: true,
      ).firstMatch(xml)!.group(0)!;
      xml = xml.replaceFirst(
        '</channel>',
        '$item<item><title>新闻</title></item></channel>',
      );
      expect(
        parser
            .parse(utf8.encode(xml), 'https://example.com/rss')
            .episodes
            .length,
        1,
      );
    },
  );
  test('OPML round trips Chinese names, escapes and deduplicates feeds', () {
    final source = parser.exportOpml([
      PodcastChannel(
        id: 'one',
        feedUrl: 'https://example.com/rss?one=1&two=2',
        title: '中文 & 测试',
      ),
    ]);
    expect(source, contains('中文 &amp; 测试'));
    expect(parser.parseOpml(source), ['https://example.com/rss?one=1&two=2']);
    expect(() => parser.parseOpml('<rss/>'), throwsFormatException);
  });
  test(
    'settings distinguish inherited false/zero and reject invalid values',
    () {
      final settings = PodcastPreferences().overlay({
        'autoRefresh': false,
        'skipIntro': 0,
        'speed': double.nan,
        'downloadConcurrency': 99,
      });
      expect(settings.flag('autoRefresh'), isFalse);
      expect(settings.integer('skipIntro'), 0);
      expect(settings.number('speed'), 1);
      expect(settings.integer('downloadConcurrency'), 4);
      expect(
        PodcastPreferences({
          'quietHours': true,
          'quietStart': 22,
          'quietEnd': 8,
        }).quietAt(DateTime(2026, 10, 16, 23)),
        isTrue,
      );
      expect(
        PodcastPreferences({
          'quietHours': true,
          'quietStart': 22,
          'quietEnd': 8,
        }).quietAt(DateTime(2026, 10, 16, 12)),
        isFalse,
      );
    },
  );
  test(
    'feed refresh retains listening state, discovery time and absent history',
    () {
      final store = PodcastStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final first = feed(second: true);
      store.mergeFeed(first, initial: true);
      final id = first.episodes.first.id;
      store.saveState(
        id,
        PodcastEpisodeState(positionMs: 10000, favorite: true, updatedMs: 50),
      );
      store.mergeFeed(feed(media: 'https://example.com/changed.mp3'));
      expect(store.episodes().length, 2);
      expect(store.state(id).positionMs, 10000);
      expect(store.state(id).favorite, isTrue);
      expect(store.episode(id)!.discoveredMs, 100);
    },
  );
  test(
    'channel setting reset inherits later global changes and device limits cannot be overridden',
    () {
      final store = PodcastStore(sqlite3.openInMemory());
      addTearDown(store.close);
      store.setSetting(null, 'speed', 1.25);
      store.setSetting('one', 'speed', 2.0);
      store.setSetting(null, 'speed', 1.5);
      expect(store.effective('one').number('speed'), 2);
      store.setSetting('one', 'speed', null);
      expect(store.effective('one').number('speed'), 1.5);
      expect(
        () => store.setSetting('one', 'downloadLimitMb', 1000),
        throwsArgumentError,
      );
    },
  );
  test(
    'missing GUID falls back to a unique stable fingerprint when the media URL changes',
    () {
      final store = PodcastStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final initial = parser.parse(
        utf8.encode(podcastFixture(guid: '')),
        'https://example.com/rss',
      );
      store.mergeFeed(initial, initial: true);
      final id = initial.episodes.single.id;
      store.saveState(
        id,
        PodcastEpisodeState(positionMs: 4500, favorite: true),
      );
      final update = parser.parse(
        utf8.encode(
          podcastFixture(
            guid: '',
            media: 'https://changed.test/audio.mp3',
          ).replaceAll(
            'https://example.com/video.mp4',
            'https://changed.test/video.mp4',
          ),
        ),
        'https://example.com/rss',
      );
      final merged = store.mergeFeed(update);
      expect(merged.single.id, id);
      expect(store.episodes(), hasLength(1));
      expect(store.state(id).positionMs, 4500);
      expect(
        store.episode(id)!.media.first.url,
        'https://changed.test/audio.mp3',
      );
    },
  );
  test(
    'backup merge preserves newer local progress and local storage limits',
    () {
      final first = PodcastStore(sqlite3.openInMemory()),
          second = PodcastStore(sqlite3.openInMemory());
      addTearDown(first.close);
      addTearDown(second.close);
      final parsed = feed();
      first.mergeFeed(parsed, initial: true);
      first.saveState(
        parsed.episodes.first.id,
        PodcastEpisodeState(positionMs: 500, updatedMs: 5),
      );
      first.setSetting(parsed.channel.id, 'speed', 1.5);
      second.mergeFeed(feed(), initial: true);
      second.saveState(
        parsed.episodes.first.id,
        PodcastEpisodeState(positionMs: 1000, updatedMs: 10),
      );
      second.setSetting(null, 'downloadLimitMb', 9000);
      second.importChannel(first.exportChannel(parsed.channel.id));
      expect(second.state(parsed.episodes.first.id).positionMs, 1000);
      expect(second.effective(parsed.channel.id).number('speed'), 1.5);
      expect(second.preferences.integer('downloadLimitMb'), 9000);
    },
  );
  test(
    'podcast cards serialize independently and online queue accepts their logical paths',
    () {
      final collection = VideoCollection(
        id: 'channel',
        name: '播客',
        createTime: 1,
        podcastRef: const PodcastChannelRef(
          channelId: 'channel',
          feedUrl: 'https://example.com/rss',
        ),
      );
      expect(VideoCollection.fromJson(collection.toJson()).isPodcast, isTrue);
      final ref = MediaSourceRef(
        value: 'podcast:one',
        kind: MediaSourceKind.podcastEpisode,
        podcast: const PodcastEpisodeRef(
          channelId: 'channel',
          episodeId: 'one',
          feedUrl: 'https://example.com/rss',
          mediaUrl: 'https://example.com/audio.mp3',
        ),
      );
      final item = VideoItem(
        id: 'one',
        path: ref.value,
        title: '节目',
        durationMs: 1000,
        lastUpdated: 1,
        sourceRef: ref,
        type: MediaType.audio,
      );
      expect(
        PlaybackQueuePolicy(sourceExists: (_) => false).isEligible(item),
        isTrue,
      );
      expect(MediaSourceRef.fromJson(ref.toJson()).podcast!.episodeId, 'one');
    },
  );
  test('white and bright artwork always produce a dark backdrop', () {
    for (final color in [
      Colors.white,
      Colors.yellow,
      Colors.red,
      Colors.blue,
      Colors.black,
    ]) {
      expect(
        HSLColor.fromColor(podcastDarkTint(color)).lightness,
        lessThanOrEqualTo(0.24),
      );
    }
  });
}
