/// Where a progress-bar preview image is allowed to come from.
enum SeekPreviewSource {
  officialStoryboard,
  localFrames,
  remoteFrames,
  unavailable,
}

class SeekPreviewDecision {
  const SeekPreviewDecision(this.source);

  final SeekPreviewSource source;

  /// Time text stays visible either way. The image well is hidden when false.
  bool get showsImage => source != SeekPreviewSource.unavailable;
}

/// Baidu's file listing thumbnail is a cover, not a timed sprite sheet.
///
/// No same-account playback capture in this change proved an official
/// storyboard URL, so cloud preview does not invent one. Remote random-access
/// frame grabs stay off until a measured budget exists.
SeekPreviewDecision decideSeekPreview({
  required bool audio,
  required bool bilibili,
  required bool bilibiliSpritesReady,
  required bool cloudDrive,
  required bool cloudLocalFramesReady,
  bool remoteRandomAccessEnabled = false,
}) {
  if (audio) return const SeekPreviewDecision(SeekPreviewSource.unavailable);
  if (bilibili) {
    return SeekPreviewDecision(
      bilibiliSpritesReady
          ? SeekPreviewSource.officialStoryboard
          : SeekPreviewSource.unavailable,
    );
  }
  if (cloudDrive) {
    // The current local extractor walks a whole keyframe index, and this
    // round did not show that it stays inside the hover budget. Remote frame
    // grabs are also out. Cloud progress preview keeps the time and hides
    // the image well, including when a full local copy already exists.
    return const SeekPreviewDecision(SeekPreviewSource.unavailable);
  }
  return const SeekPreviewDecision(SeekPreviewSource.localFrames);
}
