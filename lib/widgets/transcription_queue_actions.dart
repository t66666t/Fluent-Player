import 'package:flutter/material.dart';

import '../screens/batch_subtitle_screen.dart';
import '../services/transcription_media_selection.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../theme/app_tokens.dart';
import 'desktop_button_click_region.dart';
import 'media_library_tooltip.dart';

export '../services/transcription_media_selection.dart'
    show TranscriptionMediaSelection;

const transcriptionQueueLabel = '批量字幕转录';
const transcriptionQueueIcon = Icons.subtitles_outlined;

class TranscriptionQueueButton extends StatelessWidget {
  const TranscriptionQueueButton({
    super.key,
    required this.onPressed,
    this.compact = false,
    this.height = 48,
  });

  final VoidCallback? onPressed;
  final bool compact;
  final double height;

  @override
  Widget build(BuildContext context) => MediaLibraryTooltip(
    message: transcriptionQueueLabel,
    child: DesktopButtonClickRegion(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: AppTokens.text1,
          backgroundColor: AppTokens.text1.withValues(alpha: 0.045),
          minimumSize: Size(0, height),
          padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: compact
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(transcriptionQueueIcon, size: 18),
                  SizedBox(height: 2),
                  SizedBox(
                    height: 16,
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('转录', maxLines: 1, softWrap: false),
                    ),
                  ),
                ],
              )
            : const FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(transcriptionQueueIcon, size: 20),
                    SizedBox(width: 6),
                    Text(transcriptionQueueLabel, maxLines: 1, softWrap: false),
                  ],
                ),
              ),
      ),
    ),
  );
}

Future<void> openTranscriptionQueue(
  BuildContext context,
  TranscriptionMediaSelection selection, {
  CloudDriveRuntime? cloudRuntime,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    settings: const RouteSettings(name: '/transcription_queue'),
    builder: (_) => BatchSubtitleScreen(
      initialSelection: selection,
      cloudRuntime: cloudRuntime,
    ),
  ),
);
