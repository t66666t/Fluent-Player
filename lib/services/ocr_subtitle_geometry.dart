import 'dart:math' as math;

/// A long text line needs padding proportional to character height, not to
/// the whole sentence's width. Otherwise undetected side labels enter the
/// recognition crop inside a single box and cannot be filtered separately.
int ocrDetectionHorizontalPadding(int textWidth, int textHeight) => math.max(
  2,
  math.min((textWidth * 0.25).round(), (textHeight * 1.5).round()),
);

/// Detector coordinates in the cropped image, shared by all OCR backends.
class OcrDetectedBox {
  final int left, top, right, bottom;
  final double score;
  // The detector's text bounds before recognition padding, in crop pixels.
  // Padding can overlap a nearby label even when the actual glyphs do not.
  final ({int left, int top, int right, int bottom})? contentBounds;

  const OcrDetectedBox(
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.score, {
    this.contentBounds,
  });

  int get width => right - left;
  int get height => bottom - top;
  double get center => (top + bottom) / 2;
  int get contentLeft => contentBounds?.left ?? left;
  int get contentRight => contentBounds?.right ?? right;
  int get contentHeight => contentBounds == null
      ? height
      : contentBounds!.bottom - contentBounds!.top;
}

/// Per-region geometry in crop-relative coordinates. It is passed per call,
/// never stored on a model session that may be shared by different regions.
class OcrSubtitleGeometry {
  const OcrSubtitleGeometry({required this.height, required this.center});

  final double height, center;

  bool get isValid =>
      height.isFinite &&
      center.isFinite &&
      height > 0 &&
      height <= 1 &&
      center >= 0 &&
      center <= 1;

  bool isSmallOutlier(double candidateHeight, double candidateCenter) =>
      isValid &&
      (candidateHeight < height * 0.5 ||
          (candidateHeight < height * 0.75 &&
              ((candidateCenter - center).abs() > height * 0.75 ||
                  (candidateCenter + candidateHeight / 2 - center - height / 2)
                          .abs() >
                      height * 0.25)));
}

/// A slightly smaller second subtitle row is not a corner label. Require a
/// similar character height, horizontal overlap and a nearby subtitle row.
bool hasOcrSubtitleCompanionRow(
  OcrDetectedBox box,
  Iterable<OcrDetectedBox> boxes,
  double referenceHeight,
) {
  if (box.height < referenceHeight * 0.65) return false;
  return boxes.any((other) {
    if (identical(box, other) || other.height < referenceHeight * 0.75) {
      return false;
    }
    final overlapY =
        math.min(box.bottom, other.bottom) - math.max(box.top, other.top);
    final overlapX =
        math.min(box.right, other.right) - math.max(box.left, other.left);
    return overlapY <= math.min(box.height, other.height) * 0.2 &&
        overlapY >= -referenceHeight * 0.8 &&
        overlapX >= math.min(box.width, other.width) * 0.5;
  });
}

/// A smaller word separated from every subtitle-sized component is a side
/// label even when it shares the subtitle baseline. Nearby lowercase words
/// and horizontally overlapping second rows remain valid. Before recognition,
/// narrow components stay ambiguous to preserve punctuation and short glyphs.
bool isOcrSubtitleSideLabel(
  OcrDetectedBox box,
  Iterable<OcrDetectedBox> boxes,
  double referenceHeight,
) {
  if (referenceHeight <= 0 || box.width < referenceHeight * 0.75) {
    return false;
  }
  var hasSubtitle = false;
  for (final other in boxes) {
    if (identical(box, other) ||
        other.height < referenceHeight * 0.85 ||
        other.height > referenceHeight * 1.2) {
      continue;
    }
    hasSubtitle = true;
    final gap = math.max(
      0,
      math.max(box.contentLeft, other.contentLeft) -
          math.min(box.contentRight, other.contentRight),
    );
    if (box.contentHeight >= other.contentHeight * 0.8 ||
        gap <= other.contentHeight * 0.9) {
      return false;
    }
  }
  return hasSubtitle;
}

/// Removes clear size/position outliers before they can join a subtitle box
/// or consume recognition inference. No extra images or model calls are used.
List<OcrDetectedBox> prepareOcrSubtitleBoxes(
  List<OcrDetectedBox> input,
  int imageHeight, {
  OcrSubtitleGeometry? geometry,
}) {
  if (input.isEmpty || imageHeight <= 0) return input;
  final profile = geometry?.isValid == true ? geometry : null;
  final OcrSubtitleGeometry comparison;
  // Prefer a text-sized body over tall narrow fragments (e.g. a capital I).
  // With no history, only compare against text present in this same crop.
  if (profile != null) {
    comparison = profile;
  } else {
    final bodies = input.where((box) => box.width >= box.height * 1.5);
    final reference = (bodies.isEmpty ? input : bodies).reduce(
      (a, b) => a.height >= b.height ? a : b,
    );
    comparison = OcrSubtitleGeometry(
      height: reference.height / imageHeight,
      center: reference.center / imageHeight,
    );
  }
  final referenceHeight = comparison.height * imageHeight;
  final referenceCenter = comparison.center * imageHeight;

  bool punctuationNearBaseline(OcrDetectedBox box) {
    if (box.width > referenceHeight * 1.25) return false;
    bool near(num baseline) =>
        (box.bottom - baseline).abs() <= referenceHeight * 0.25;
    // Preserve standalone ellipses and small punctuation at the subtitle
    // baseline, including a second row. Width never rejects a short subtitle.
    if (profile != null && near(referenceCenter + referenceHeight / 2)) {
      return true;
    }
    return input.any((other) {
      if (identical(box, other) || other.height < referenceHeight * 0.75) {
        return false;
      }
      final gap = math.max(
        0,
        math.max(box.left, other.left) - math.min(box.right, other.right),
      );
      return gap <= referenceHeight && near(other.bottom);
    });
  }

  final boxes =
      input
          .where(
            (box) =>
                !isOcrSubtitleSideLabel(box, input, referenceHeight) &&
                (!comparison.isSmallOutlier(
                      box.height / imageHeight,
                      box.center / imageHeight,
                    ) ||
                    hasOcrSubtitleCompanionRow(box, input, referenceHeight) ||
                    punctuationNearBaseline(box)),
          )
          .toList()
        ..sort((a, b) => a.top - b.top);
  final result = <OcrDetectedBox>[];
  for (final box in boxes) {
    final index = result.indexWhere((other) {
      final verticalOverlap =
          math.min(other.bottom, box.bottom) - math.max(other.top, box.top);
      final minHeight = math.min(other.height, box.height);
      final maxHeight = math.max(other.height, box.height);
      final heightRatio = minHeight / math.max(1, maxHeight);
      final gap = math.max(
        0,
        math.max(other.left, box.left) - math.min(other.right, box.right),
      );
      return verticalOverlap > minHeight * 0.55 &&
          heightRatio >= 0.5 &&
          // A smaller word on the same baseline can be lowercase text. A
          // smaller label on a different baseline must remain a separate box.
          (heightRatio >= 0.75 ||
              (other.bottom - box.bottom).abs() <= maxHeight * 0.2) &&
          gap <= maxHeight * 2.5;
    });
    if (index < 0) {
      result.add(box);
    } else {
      final other = result[index];
      result[index] = OcrDetectedBox(
        math.min(other.left, box.left),
        math.min(other.top, box.top),
        math.max(other.right, box.right),
        math.max(other.bottom, box.bottom),
        math.max(other.score, box.score),
      );
    }
  }
  return result;
}
