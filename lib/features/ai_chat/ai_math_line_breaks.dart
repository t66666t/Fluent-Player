/// Chooses complete-term lines, minimizing the number of lines first, then
/// uneven whitespace and the cost of breaking at less natural operators.
/// [penalties] describes the break BEFORE each corresponding term.
List<int> planAiMathLines({
  required List<double> widths,
  required List<int> penalties,
  required double maxWidth,
  required double indent,
}) {
  assert(widths.length == penalties.length);
  final count = widths.length;
  final lines = List.filled(count + 1, count + 1);
  final costs = List.filled(count + 1, double.infinity);
  final next = List.filled(count, count);
  lines[count] = 0;
  costs[count] = 0;
  for (var start = count - 1; start >= 0; start--) {
    // Do not introduce horizontal scrolling just to indent a wide term.
    final inset =
        start > 0 && penalties[start] >= 0 && widths[start] + indent <= maxWidth
        ? indent
        : 0;
    final available = maxWidth - inset;
    var width = 0.0;
    for (var end = start + 1; end <= count; end++) {
      width += widths[end - 1];
      if (end > start + 1 && width > available + .001) break;
      // A single indivisible term may exceed the viewport; it must remain
      // reachable by horizontal scrolling, on a line of its own.
      final slack = ((available - width) / available).clamp(0.0, 1.0);
      final cost =
          costs[end] +
          slack * slack * 1000 +
          (end < count ? penalties[end] : 0);
      final lineCount = lines[end] + 1;
      if (lineCount < lines[start] ||
          (lineCount == lines[start] && cost < costs[start])) {
        lines[start] = lineCount;
        costs[start] = cost;
        next[start] = end;
      }
    }
  }
  final starts = <int>[];
  for (var index = 0; index < count; index = next[index]) {
    starts.add(index);
  }
  return starts;
}
