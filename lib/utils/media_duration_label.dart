String formatMediaDurationLabel(int milliseconds) {
  if (milliseconds <= 0) return '';
  final seconds = milliseconds ~/ 1000;
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final tail = (seconds % 60).toString().padLeft(2, '0');
  if (seconds < 3600) return '$minutes:$tail';
  final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
  final remainder = ((seconds ~/ 60) % 60).toString().padLeft(2, '0');
  return '$hours:$remainder:$tail';
}
