/// A stable reading anchor within a message, independent of viewport pixels.
class AiMessageBookmark {
  const AiMessageBookmark(this.messageId, this.alignment, this.fraction);
  final String messageId;
  final double alignment;
  final double fraction;
}

class AiChatReadingPosition {
  AiChatReadingPosition({
    required this.bookmark,
    required this.atEnd,
    required this.followOutput,
    required Set<String> expandedReasoning,
  }) : expandedReasoning = Set.unmodifiable(expandedReasoning);

  final AiMessageBookmark? bookmark;
  final bool atEnd;
  final bool followOutput;
  final Set<String> expandedReasoning;
}

/// In-memory view state belongs to the live video conversation, not its widget.
/// Explicit new/history navigation starts a fresh visit at the end. A view
/// remount within that visit restores its reading position. Owner and visit
/// checks reject late geometry from a hidden/replaced/fullscreen sibling view.
class AiChatReadingState {
  String? conversationId;
  int visit = 0;
  AiChatReadingPosition? position;
  Object? _owner;

  void openConversation(String id) {
    conversationId = id;
    visit++;
    position = null;
  }

  void claim(Object owner) => _owner = owner;

  bool isOwnedBy(Object owner) => identical(owner, _owner);

  void save(Object owner, int expectedVisit, AiChatReadingPosition value) {
    if (!identical(owner, _owner) || expectedVisit != visit) return;
    position = value;
  }
}
