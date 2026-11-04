import 'package:flutter/foundation.dart';

/// Current binding, rather than a record that an output existed in the past.
@immutable
class VideoOutputState {
  const VideoOutputState({required this.generation, required this.available});

  final int generation;
  final bool available;
}
