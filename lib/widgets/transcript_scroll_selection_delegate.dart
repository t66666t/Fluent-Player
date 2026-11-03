import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reapplies the dragged edge after the transcript scrolls under a stationary
/// finger. Flutter updates handles on pointer movement; a timer-driven scroll
/// otherwise moves the text while leaving the selected range behind.
class TranscriptScrollSelectionDelegate
    extends StaticSelectionContainerDelegate {
  SelectionEdgeUpdateEvent? _lastEdge;

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    _lastEdge = event;
    return super.handleSelectionEdgeUpdate(event);
  }

  void followScroll() {
    final edge = _lastEdge;
    if (edge != null) {
      dispatchSelectionEvent(edge);
    }
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _lastEdge = null;
    return super.handleClearSelection(event);
  }
}
