import '../../models/subtitle_model.dart';

class ComposeSubtitleSource {
  final String title;
  final String language;
  final List<SubtitleItem> items;

  const ComposeSubtitleSource({
    required this.title,
    required this.language,
    required this.items,
  });
}

class ComposeSubtitleInput {
  final String path;
  final String title;
  final String language;

  const ComposeSubtitleInput({
    required this.path,
    required this.title,
    required this.language,
  });
}

class VideoProbeInfo {
  final int width;
  final int height;
  final int displayWidth;
  final int displayHeight;
  final int rotation;
  final Duration duration;
  final double frameRate;

  const VideoProbeInfo({
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.rotation,
    required this.duration,
    this.frameRate = 30,
  });
}

class TargetResolution {
  final int width;
  final int height;

  const TargetResolution({required this.width, required this.height});
}

class DisplaySize {
  final int width;
  final int height;

  const DisplaySize({required this.width, required this.height});
}

class ComposeCue {
  final Duration startTime;
  final Duration endTime;
  final String primaryText;
  final String? secondaryText;

  const ComposeCue({
    required this.startTime,
    required this.endTime,
    required this.primaryText,
    required this.secondaryText,
  });
}
