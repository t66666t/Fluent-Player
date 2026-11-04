import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import '../../utils/pgs_parser.dart';
import '../../utils/subtitle_converter.dart';
import '../../utils/subtitle_parser.dart';

class VideoComposeSubtitleService {
  const VideoComposeSubtitleService();

  Future<List<SubtitleItem>> loadSubtitle(String? path) async {
    if (path == null || path.isEmpty) return const <SubtitleItem>[];
    final File file = File(path);
    if (!await file.exists()) return const <SubtitleItem>[];
    final String extension = p.extension(path).toLowerCase();
    if (extension == '.sup') {
      final List<SubtitleItem> parsed = await PgsParser.parse(path);
      parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
      return parsed;
    }
    if (extension == '.idx' || extension == '.sub') {
      final String? converted = await SubtitleConverter.convert(
        inputPath: path,
        targetExtension: '.sup',
      );
      if (converted != null) {
        final List<SubtitleItem> parsed = await PgsParser.parse(converted);
        parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
        return parsed;
      }
    }
    final List<int> bytes = await file.readAsBytes();
    final String content = SubtitleParser.decodeBytes(bytes);
    if (content.isEmpty) return const <SubtitleItem>[];
    final List<SubtitleItem> parsed = SubtitleParser.parse(content);
    parsed.sort(
      (SubtitleItem a, SubtitleItem b) => a.startTime.compareTo(b.startTime),
    );
    return parsed;
  }

  List<SubtitleItem> continuousSubtitles(
    List<SubtitleItem> items,
    Duration totalDuration,
  ) {
    if (items.isEmpty) return items;
    final List<SubtitleItem> result = <SubtitleItem>[];
    for (int i = 0; i < items.length; i++) {
      final SubtitleItem item = items[i];
      Duration end = item.endTime;
      if (i + 1 < items.length) {
        final Duration nextStart = items[i + 1].startTime;
        if (nextStart > end) {
          end = nextStart;
        }
      } else if (totalDuration > end) {
        end = totalDuration;
      }
      result.add(
        SubtitleItem(
          index: item.index,
          startTime: item.startTime,
          endTime: end,
          text: item.text,
          imageLoader: item.imageLoader,
        ),
      );
    }
    return result;
  }

  String buildSrtContent(List<SubtitleItem> items) {
    final StringBuffer sb = StringBuffer();
    int index = 1;
    for (final SubtitleItem item in items) {
      final String text = item.text.replaceAll('\r', '').trim();
      if (text.isEmpty) {
        continue;
      }
      final Duration start = item.startTime;
      final Duration end = item.endTime;
      if (end <= start) {
        continue;
      }
      sb.writeln(index);
      sb.writeln('${_toSrtTime(start)} --> ${_toSrtTime(end)}');
      sb.writeln(text);
      sb.writeln();
      index++;
    }
    return sb.toString();
  }

  String _toSrtTime(Duration duration) {
    final int totalMs = duration.inMilliseconds < 0
        ? 0
        : duration.inMilliseconds;
    final int h = totalMs ~/ 3600000;
    final int m = (totalMs % 3600000) ~/ 60000;
    final int s = (totalMs % 60000) ~/ 1000;
    final int ms = totalMs % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')},${ms.toString().padLeft(3, '0')}';
  }
}
