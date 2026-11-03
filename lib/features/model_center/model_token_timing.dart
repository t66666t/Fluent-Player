import '../../models/subtitle_model.dart';

/// Retain native token boundaries only when they can be matched to the final
/// text. Normalization can change spelling; never invent an alignment then.
List<SubtitleTimedSpan> alignModelTokens({
  required String text,
  required List<String> tokens,
  required List<double> starts,
  required double cueEnd,
  double offset = 0,
  List<double>? ends,
}) {
  if (tokens.isEmpty ||
      tokens.length != starts.length ||
      (ends != null && ends.length != tokens.length)) {
    return const [];
  }
  for (var i = 0; i < starts.length; i++) {
    if (!starts[i].isFinite ||
        starts[i] < 0 ||
        i > 0 && starts[i] < starts[i - 1]) {
      return const [];
    }
  }
  // A TDT can emit several subwords without advancing its audio frame. A
  // zero-duration token is still recognized text, not a token to discard.
  // Keep the frame group atomic and use its next distinct onset as a bound.
  final nextOnsets = List<double>.filled(starts.length, cueEnd - offset);
  var next = cueEnd - offset;
  for (var i = starts.length - 1; i >= 0; i--) {
    if (i + 1 < starts.length && starts[i + 1] > starts[i]) {
      next = starts[i + 1];
    }
    nextOnsets[i] = next;
  }
  final spans = <SubtitleTimedSpan>[];
  var cursor = 0;
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i].replaceAll('▁', ' ').replaceAll('Ġ', ' ').trim();
    if (token.isEmpty || RegExp(r'^<[^>]+>$').hasMatch(token)) continue;
    final match = RegExp(
      RegExp.escape(token),
      caseSensitive: false,
    ).firstMatch(text.substring(cursor));
    if (match == null) return const [];
    final from = cursor + match.start;
    final to = cursor + match.end;
    cursor = to;
    final begin = starts[i] + offset;
    var finish = ends != null ? ends[i] + offset : nextOnsets[i] + offset;
    if (ends != null && finish.isFinite && (finish - begin).abs() < .000001) {
      finish = nextOnsets[i] + offset;
    }
    if (!begin.isFinite ||
        !finish.isFinite ||
        begin < 0 ||
        finish <= begin ||
        begin >= cueEnd) {
      continue;
    }
    spans.add(
      SubtitleTimedSpan(
        textStart: from,
        textEnd: to,
        startTime: Duration(microseconds: (begin * 1000000).round()),
        endTime: Duration(
          microseconds: (finish.clamp(begin, cueEnd) * 1000000).round(),
        ),
        role: 'token',
      ),
    );
  }
  return spans;
}
