class WebMediaDownloadSize {
  const WebMediaDownloadSize(this.bytes, {this.estimated = false});
  final int bytes;
  final bool estimated;
  String get label => '${estimated ? '约 ' : ''}${formatWebMediaBytes(bytes)}';
}

String formatWebMediaBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
}
