enum PlaybackMode {
  sequential('顺序播放'),
  shuffle('随机播放'),
  repeatOne('单集循环');

  const PlaybackMode(this.label);

  final String label;

  PlaybackMode get next => values[(index + 1) % values.length];
}
