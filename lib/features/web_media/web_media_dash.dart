import 'dart:math' as math;
import 'package:xml/xml.dart';
import 'web_media_resource.dart';

class WebMediaDashSegment {
  const WebMediaDashSegment(this.url, this.seconds, {this.range});
  final Uri url;
  final double seconds;
  final String? range;
}

class WebMediaDashTrack {
  const WebMediaDashTrack(this.resource, this.segments, {this.initialization});
  final WebMediaResource resource;
  final List<WebMediaDashSegment> segments;
  final WebMediaDashSegment? initialization;

  String get playlist {
    String quoted(Uri uri) {
      if (uri.toString().contains('"')) throw const FormatException('无效的清单地址');
      return '"$uri"';
    }

    String range(String value) {
      final parts = value.split('-').map(int.parse).toList();
      if (parts.length != 2 || parts[1] < parts[0]) {
        throw const FormatException('无效的媒体范围');
      }
      return '${parts[1] - parts[0] + 1}@${parts[0]}';
    }

    final init = initialization;
    return [
      '#EXTM3U',
      '#EXT-X-VERSION:7',
      '#EXT-X-TARGETDURATION:${segments.map((s) => s.seconds.ceil()).fold<int>(1, math.max)}',
      '#EXT-X-MEDIA-SEQUENCE:0',
      '#EXT-X-PLAYLIST-TYPE:VOD',
      if (init != null)
        '#EXT-X-MAP:URI=${quoted(init.url)}${init.range == null ? '' : ',BYTERANGE="${range(init.range!)}"'}',
      for (final segment in segments) ...[
        '#EXTINF:${segment.seconds},',
        if (segment.range != null) '#EXT-X-BYTERANGE:${range(segment.range!)}',
        segment.url.toString(),
      ],
      '#EXT-X-ENDLIST',
    ].join('\n');
  }
}

/// Parse a finite, unencrypted MPD. Never silently save the first period or
/// the first fragment of a stream that cannot be represented completely.
List<WebMediaDashTrack> parseWebMediaDash(
  String text,
  WebMediaResource source,
) {
  final root = XmlDocument.parse(text).rootElement;
  if (root.name.local != 'MPD' || root.getAttribute('type') == 'dynamic') {
    throw const FormatException('暂不支持这个 DASH 直播清单');
  }
  if (root.descendants.whereType<XmlElement>().any(
    (e) => e.name.local == 'ContentProtection',
  )) {
    throw const FormatException('网页媒体受加密保护，无法直接下载');
  }
  List<XmlElement> children(XmlElement e, String name) =>
      e.childElements.where((c) => c.name.local == name).toList();
  double duration(String? value) {
    final m = RegExp(
      r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    ).firstMatch(value ?? '');
    if (m == null) return 0;
    return (double.tryParse(m[1] ?? '') ?? 0) * 86400 +
        (double.tryParse(m[2] ?? '') ?? 0) * 3600 +
        (double.tryParse(m[3] ?? '') ?? 0) * 60 +
        (double.tryParse(m[4] ?? '') ?? 0);
  }

  Uri resolve(Uri base, String value) {
    final uri = safeWebMediaUri(value, baseUrl: base);
    if (uri == null) throw const FormatException('清单包含无法下载的地址');
    return uri;
  }

  Uri baseFor(XmlElement node, Uri parent) {
    final base = children(node, 'BaseURL').firstOrNull;
    return base == null ? parent : resolve(parent, base.innerText.trim());
  }

  final periods = children(root, 'Period');
  if (periods.length != 1) throw const FormatException('暂不支持多时段 DASH 清单');
  final period = periods.single;
  final seconds = duration(period.getAttribute('duration')) != 0
      ? duration(period.getAttribute('duration'))
      : duration(root.getAttribute('mediaPresentationDuration'));
  if (seconds <= 0 || seconds > 604800) {
    throw const FormatException('未能确认完整视频时长');
  }
  final rootBase = baseFor(root, Uri.parse(source.url));
  final periodBase = baseFor(period, rootBase);
  final result = <WebMediaDashTrack>[];
  var adaptationIndex = 0;
  for (final adaptation in children(period, 'AdaptationSet')) {
    adaptationIndex++;
    final adaptationBase = baseFor(adaptation, periodBase);
    for (final rep in children(adaptation, 'Representation')) {
      if (result.length >= 128) throw const FormatException('DASH 画质数量过多');
      final nodes = [root, period, adaptation, rep];
      String? attr(String key) =>
          nodes.reversed.map((n) => n.getAttribute(key)).nonNulls.firstOrNull;
      final id = rep.getAttribute('id') ?? '${result.length}';
      final mime = attr('mimeType') ?? '';
      final type = attr('contentType') ?? mime.split('/').first;
      if (type != 'video' && type != 'audio') continue;
      final base = baseFor(rep, adaptationBase);
      final segments = <WebMediaDashSegment>[];
      WebMediaDashSegment? init;
      final lists = nodes.expand((n) => children(n, 'SegmentList')).toList();
      final templates = nodes
          .expand((n) => children(n, 'SegmentTemplate'))
          .toList();
      if (lists.isNotEmpty) {
        final list = lists.last;
        final entries = children(list, 'SegmentURL');
        if (entries.isEmpty || entries.length > 20000) {
          throw const FormatException('无效的 DASH 分片清单');
        }
        final initialization = children(list, 'Initialization').firstOrNull;
        if (initialization != null) {
          init = WebMediaDashSegment(
            resolve(base, initialization.getAttribute('sourceURL') ?? ''),
            0,
            range: initialization.getAttribute('range'),
          );
        }
        final scale = int.tryParse(list.getAttribute('timescale') ?? '1') ?? 1;
        final length = int.tryParse(list.getAttribute('duration') ?? '') ?? 0;
        final timeline = children(list, 'SegmentTimeline').firstOrNull;
        final times = <double>[];
        if (scale <= 0) throw const FormatException('无效的 DASH 时间单位');
        if (timeline != null) {
          for (final item in children(timeline, 'S')) {
            final d = int.tryParse(item.getAttribute('d') ?? '') ?? 0;
            final r = int.tryParse(item.getAttribute('r') ?? '0') ?? 0;
            if (d <= 0 || r < 0 || r > 20000) {
              throw const FormatException('不支持的 DASH 分片时间线');
            }
            for (var i = 0; i <= r; i++) {
              if (times.length >= entries.length) {
                throw const FormatException('DASH 时间线与分片不一致');
              }
              times.add(d / scale);
            }
          }
        } else if (length > 0) {
          times.addAll(List.filled(entries.length, length / scale));
        }
        if (times.length != entries.length ||
            times.fold<double>(0, (a, b) => a + b) + .25 < seconds) {
          throw const FormatException('DASH 分片清单缺少完整时间信息');
        }
        for (var i = 0; i < entries.length; i++) {
          final item = entries[i];
          segments.add(
            WebMediaDashSegment(
              resolve(base, item.getAttribute('media') ?? ''),
              times[i],
              range: item.getAttribute('mediaRange'),
            ),
          );
        }
      } else if (templates.isNotEmpty) {
        String? setting(String key) => templates.reversed
            .map((n) => n.getAttribute(key))
            .nonNulls
            .firstOrNull;
        final scale = int.tryParse(setting('timescale') ?? '1') ?? 1;
        if (scale <= 0) throw const FormatException('无效的 DASH 时间单位');
        var number = int.tryParse(setting('startNumber') ?? '1') ?? 1;
        final offset =
            int.tryParse(setting('presentationTimeOffset') ?? '0') ?? 0;
        final media = setting('media');
        if (media == null) throw const FormatException('缺少 DASH 分片地址');
        String substitute(String pattern, int num, int time) {
          final escaped = pattern.replaceAll(r'$$', '\u0001');
          final value = escaped
              .replaceAllMapped(
                RegExp(
                  r'\$(RepresentationID|Bandwidth|Number|Time)(?:%0(\d+)d)?\$',
                ),
                (m) {
                  final raw = switch (m[1]) {
                    'RepresentationID' => id,
                    'Bandwidth' => rep.getAttribute('bandwidth') ?? '0',
                    'Time' => '$time',
                    _ => '$num',
                  };
                  return raw.padLeft(
                    (int.tryParse(m[2] ?? '') ?? 0).clamp(0, 20),
                    '0',
                  );
                },
              )
              .replaceAll('\u0001', r'$');
          if (RegExp(r'\$\w+\$').hasMatch(value)) {
            throw const FormatException('不支持的 DASH 地址模板');
          }
          return value;
        }

        final initial = setting('initialization');
        if (initial != null) {
          init = WebMediaDashSegment(
            resolve(base, substitute(initial, number, 0)),
            0,
          );
        }
        final timelines = templates
            .expand((n) => children(n, 'SegmentTimeline'))
            .toList();
        final timeline = timelines.isEmpty
            ? <XmlElement>[]
            : children(timelines.last, 'S');
        void add(int time, int length) {
          if (segments.length >= 20000 || length <= 0) {
            throw const FormatException('DASH 分片数量或时长无效');
          }
          segments.add(
            WebMediaDashSegment(
              resolve(base, substitute(media, number++, time)),
              length / scale,
            ),
          );
        }

        if (timeline.isNotEmpty) {
          var time = 0;
          for (var i = 0; i < timeline.length; i++) {
            final item = timeline[i];
            time = int.tryParse(item.getAttribute('t') ?? '') ?? time;
            final length = int.tryParse(item.getAttribute('d') ?? '') ?? 0;
            var repeat = int.tryParse(item.getAttribute('r') ?? '0') ?? 0;
            if (length <= 0 || repeat < -1) {
              throw const FormatException('无效的 DASH 时间线');
            }
            if (repeat == -1) {
              final end = i + 1 < timeline.length
                  ? int.tryParse(timeline[i + 1].getAttribute('t') ?? '')
                  : (seconds * scale).ceil() + offset;
              if (end == null || end <= time) {
                throw const FormatException('未能确认 DASH 时间线终点');
              }
              repeat = ((end - time) / length).ceil() - 1;
            }
            if (repeat > 20000) throw const FormatException('DASH 分片数量过多');
            for (var j = 0; j <= repeat; j++) {
              add(time, length);
              time += length;
            }
          }
        } else {
          final length = int.tryParse(setting('duration') ?? '') ?? 0;
          if (length <= 0) throw const FormatException('缺少 DASH 分片时长');
          final count = (seconds * scale / length).ceil();
          if (count > 20000) throw const FormatException('DASH 分片数量过多');
          for (var i = 0; i < count; i++) {
            add(offset + i * length, length);
          }
        }
        if (segments.fold<double>(0, (a, s) => a + s.seconds) + .25 < seconds) {
          throw const FormatException('DASH 时间线不完整');
        }
      } else {
        if (base == Uri.parse(source.url) || base.path.endsWith('/')) {
          throw const FormatException('缺少完整的 DASH 轨道地址');
        }
        segments.add(WebMediaDashSegment(base, seconds));
      }
      result.add(
        WebMediaDashTrack(
          source.copyWith(
            representationId: '$adaptationIndex:$id',
            audioGroup: 'dash:${source.url}',
            requiresAudio:
                type == 'video' &&
                root.descendants.any(
                  (e) =>
                      e.getAttribute('mimeType')?.startsWith('audio/') ==
                          true ||
                      e.getAttribute('contentType') == 'audio',
                ),
            duration: Duration(milliseconds: (seconds * 1000).round()),
            metadata: source.metadata.copyWith(
              mimeType: mime,
              hasVideo: type == 'video',
              hasAudio: type == 'audio',
              width: int.tryParse(attr('width') ?? ''),
              height: int.tryParse(attr('height') ?? ''),
              videoCodec: type == 'video' ? attr('codecs') : null,
              audioCodec: type == 'audio' ? attr('codecs') : null,
            ),
          ),
          segments,
          initialization: init,
        ),
      );
    }
  }
  if (result.isEmpty) throw const FormatException('清单没有可下载的音视频轨道');
  return result;
}
