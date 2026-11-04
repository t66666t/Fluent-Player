/// Pixel-space subtitle dragging lives in `subtitle_position_geometry.dart`.
///
/// The previous helper converted pointer deltas by `delta / (viewport / 2)`
/// and snapped from an already-zeroed alignment, so slow drags stuck at the
/// center and wide captions lagged the pointer. Callers now use
/// [sampleSubtitleDrag].
library;

export 'subtitle_position_geometry.dart'
    show
        kSubtitleSnapThresholds,
        resolveSubtitlePixelSnap,
        sampleSubtitleDrag,
        SubtitleDragSample,
        SubtitleSnapMemory,
        SubtitleSnapThresholds;
