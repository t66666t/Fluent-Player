import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/ocr_subtitle_manager.dart';
import '../services/subtitle_stream_source.dart';
import '../services/transcription_manager.dart';

SubtitleStreamSource? lookupSubtitleStreams(BuildContext context) {
  try {
    return context.read<SubtitleStreamSource>();
  } on ProviderNotFoundException {
    /* Standalone tools retain their source. */
  }
  try {
    return context.read<TranscriptionManager>();
  } on ProviderNotFoundException {
    /* OCR-only screens need no ASR manager. */
  }
  try {
    return context.read<OcrSubtitleManager>();
  } on ProviderNotFoundException {
    return null;
  }
}
