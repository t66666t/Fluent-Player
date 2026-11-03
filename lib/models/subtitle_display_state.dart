import '../widgets/subtitle_overlay.dart';

/// 字幕显示状态数据类。
///
/// 封装字幕叠加层渲染所需的全部数据。通过 [ValueNotifier] 持有后，
/// 字幕更新仅触发 [SubtitleDisplayLayer] 局部重建，而非整页 setState。
class SubtitleDisplayState {
  /// 当前需要渲染的字幕条目列表。
  final List<SubtitleOverlayEntry> entries;

  const SubtitleDisplayState({this.entries = const <SubtitleOverlayEntry>[]});

  /// 空状态（无字幕）。
  static const SubtitleDisplayState empty = SubtitleDisplayState();

  bool get isEmpty => entries.isEmpty;
}
