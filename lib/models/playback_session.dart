enum PlaybackSessionPhase {
  idle,
  resolving,
  releasingOld,
  preparingSource,
  initializingTransport,
  transportReady,
  videoOutputDeferred,
  controllerMountable,
  ready,
  missing,
  failed,
  stopped,
}

class PlaybackSessionSnapshot {
  const PlaybackSessionSnapshot({
    required this.generation,
    required this.itemId,
    required this.phase,
    required this.desiredPlaying,
    required this.controllerGeneration,
    required this.hasVideoOutput,
    this.error,
  });

  const PlaybackSessionSnapshot.idle()
    : generation = 0,
      itemId = null,
      phase = PlaybackSessionPhase.idle,
      desiredPlaying = false,
      controllerGeneration = 0,
      hasVideoOutput = false,
      error = null;

  final int generation;
  final String? itemId;
  final PlaybackSessionPhase phase;
  final bool desiredPlaying;
  final int controllerGeneration;
  final bool hasVideoOutput;
  final String? error;

  bool get isTerminal =>
      phase == PlaybackSessionPhase.ready ||
      phase == PlaybackSessionPhase.missing ||
      phase == PlaybackSessionPhase.failed ||
      phase == PlaybackSessionPhase.stopped ||
      phase == PlaybackSessionPhase.idle;

  bool get isControllerMountable =>
      phase == PlaybackSessionPhase.controllerMountable ||
      phase == PlaybackSessionPhase.ready;

  PlaybackSessionSnapshot copyWith({
    PlaybackSessionPhase? phase,
    bool? desiredPlaying,
    int? controllerGeneration,
    bool? hasVideoOutput,
    String? error,
    bool clearError = false,
  }) {
    return PlaybackSessionSnapshot(
      generation: generation,
      itemId: itemId,
      phase: phase ?? this.phase,
      desiredPlaying: desiredPlaying ?? this.desiredPlaying,
      controllerGeneration: controllerGeneration ?? this.controllerGeneration,
      hasVideoOutput: hasVideoOutput ?? this.hasVideoOutput,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
