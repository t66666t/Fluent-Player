import 'package:flutter/painting.dart';

/// Text is separate from file events so a URL cannot become a file import.
enum TextDropPhase { entered, updated, exited, dropped }

class TextDropEvent {
  const TextDropEvent({
    required this.phase,
    required this.location,
    this.text,
    this.urls = const [],
  });

  final TextDropPhase phase;

  /// Window client coordinates, using the same units as file drop events.
  final Offset location;
  final String? text;
  final List<String> urls;
}

typedef RawTextDropListener = bool Function(TextDropEvent event);
