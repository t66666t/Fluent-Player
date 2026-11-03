/// Describes where a subtitle track came from.
///
/// [sidecar] is the dedicated type for an external subtitle file discovered
/// next to its video. It is intentionally distinct from an embedded stream,
/// an app-managed file, and a manually selected external file.
enum SubtitleSourceType {
  embedded,
  sidecar,
  managed,
  external;

  String get displayName => switch (this) {
    SubtitleSourceType.embedded => '内嵌字幕',
    SubtitleSourceType.sidecar => '伴随字幕',
    SubtitleSourceType.managed => '应用管理字幕',
    SubtitleSourceType.external => '外部字幕',
  };
}
