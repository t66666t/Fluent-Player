import 'package:flutter/widgets.dart';

import '../../models/video_item.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_draft_binding.dart';
import 'ai_chat_settings.dart';
import 'ai_video_context.dart';

/// The chat for one video, borrowed by whichever panel is on screen.
class AiChatSession {
  AiChatSession({required this.controller, required this.input})
    : _draftBinding = AiChatDraftBinding.retain(controller, input);

  final AiChatController controller;

  /// Draft text survives closing the sidebar and rotating the player.
  final TextEditingController input;
  final AiChatDraftBinding _draftBinding;

  void dispose() {
    _draftBinding.release();
    controller.dispose();
    input.dispose();
  }
}

/// Process-lifetime AI chats, one per video.
///
/// Closing the sidebar, switching portrait/landscape, or leaving the player
/// only detaches the view. Generation keeps running until the app shuts down
/// or the user presses stop. [shutdown] is safe to call more than once.
class AiChatSessions {
  AiChatSessions();

  static final AiChatSessions instance = AiChatSessions();

  final Map<String, AiChatSession> _byVideoId = {};

  /// Returns the live session for [video], creating it the first time.
  AiChatSession retain({
    required VideoItem video,
    required AiVideoContextLoader Function() createLoader,
  }) {
    final existing = _byVideoId[video.id];
    if (existing != null) {
      existing.controller.adoptVideo(video);
      return existing;
    }
    final session = AiChatSession(
      controller: AiChatController(video: video, contextLoader: createLoader()),
      input: TextEditingController(),
    );
    _byVideoId[video.id] = session;
    return session;
  }

  /// Pushes API changes made outside the chat into every live conversation.
  void adoptSettings(AiChatSettings settings) {
    for (final session in _byVideoId.values) {
      session.controller.adoptSettings(settings);
    }
  }

  Future<void> flushPreferencesForTrial() async {
    for (final session in List.of(_byVideoId.values)) {
      await session.controller.flushPreferencesForTrial();
    }
  }

  void adoptPreferenceFields(Map<String, dynamic> fields) {
    for (final session in _byVideoId.values) {
      final current = session.controller.settings;
      session.controller.adoptSettings(
        AiChatSettings.fromJson({...current.toJson(), ...fields}).copyWith(
          apiKey: current.apiKey,
          apiProfiles: current.apiProfiles,
          requestInputTokens: current.requestInputTokens,
        ),
      );
    }
  }

  /// Stops every in-flight reply. Used when the process is going away.
  void shutdown() {
    final sessions = _byVideoId.values.toList();
    _byVideoId.clear();
    for (final session in sessions) {
      session.dispose();
    }
  }

  /// Installs a controller the test already owns. [shutdown] disposes it.
  @visibleForTesting
  void holdForTesting(AiChatController controller) {
    final previous = _byVideoId.remove(controller.video.id);
    previous?._draftBinding.release();
    previous?.input.dispose();
    _byVideoId[controller.video.id] = AiChatSession(
      controller: controller,
      input: TextEditingController(),
    );
  }
}
