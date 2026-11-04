enum DanmakuType { scroll, top, bottom }

class DanmakuItem {
  final int index;
  final Duration startTime;
  final Duration duration;
  final String text;
  final DanmakuType type;
  final int colorValue;
  final double sourceY;

  const DanmakuItem({
    required this.index,
    required this.startTime,
    required this.duration,
    required this.text,
    required this.type,
    required this.colorValue,
    required this.sourceY,
  });
}

class DanmakuDocument {
  final List<DanmakuItem> items;
  final double referenceWidth;
  final double referenceHeight;

  const DanmakuDocument({
    required this.items,
    this.referenceWidth = 1920,
    this.referenceHeight = 1080,
  });
}
