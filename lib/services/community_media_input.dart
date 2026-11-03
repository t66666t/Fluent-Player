/// Media processing in this edition operates on user-imported local files.
/// Normal online playback and model/font resources use their existing paths.
void requireCommunityLocalMedia(String path) {
  final value = path.trim();
  if (value.isEmpty) throw const FormatException('请选择本地媒体文件');
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return;
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'file') return;
  if (value.contains('://') || (uri != null && uri.scheme.isNotEmpty)) {
    throw UnsupportedError('开源版不下载远程媒体作为处理素材，请先导入本地文件');
  }
}
