/// Typed subtitle-search failures. Each kind maps to one recovery action so
/// the UI does not offer a retry that would repeat a deterministic failure.
enum SubtitleFailureStage {
  resolve,
  download,
  inspect,
  extract,
  decode,
  parse,
  match,
  commit,
}

enum SubtitleFailureKind {
  network,
  timeout,
  cancelled,
  verification,
  htmlOrJson,
  empty,
  unsupported,
  encrypted,
  badPassword,
  missingVolume,
  damaged,
  truncated,
  limit,
  encodingUncertain,
  entryParse,
  imageSubtitle,
  noSubtitle,
  conflict,
}

enum SubtitleRecovery {
  none,
  retryDownload,
  openDetail,
  enterPassword,
  chooseVolume,
  switchEncoding,
  continueOthers,
}

class SubtitleFailure implements Exception {
  const SubtitleFailure({
    required this.stage,
    required this.kind,
    required this.message,
    this.detail = '',
    this.retryable = false,
    this.recovery = SubtitleRecovery.none,
  });

  final SubtitleFailureStage stage;
  final SubtitleFailureKind kind;
  final String message;
  final String detail;
  final bool retryable;
  final SubtitleRecovery recovery;

  @override
  String toString() => message;
}
