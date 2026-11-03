/// 歌词行状态枚举
enum LyricLineStatus { current, played, upcoming }

/// 歌词行数据模型
///
/// 用于 Apple Music 风格歌词展示的三态渲染：
/// - [LyricLineStatus.current]: 当前行，白色加粗放大高亮
/// - [LyricLineStatus.played]: 已播放行，灰色淡化
/// - [LyricLineStatus.upcoming]: 未播行，更浅灰色淡化
class MusicLyricLine {
  final String text;
  final Duration startTime;
  final Duration? endTime;
  final int index;

  const MusicLyricLine({
    required this.text,
    required this.startTime,
    this.endTime,
    required this.index,
  });
}
