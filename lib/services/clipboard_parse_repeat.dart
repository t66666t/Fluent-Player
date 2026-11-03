/// Compares one handled clipboard update, never a history of previously seen
/// URLs. Missing platform metadata falls back to content equality.
bool shouldSkipClipboardParse({
  required String fingerprint,
  required String? handledFingerprint,
  required String? updateToken,
  required String? handledUpdateToken,
}) {
  if (fingerprint != handledFingerprint) return false;
  return updateToken == null ||
      handledUpdateToken == null ||
      updateToken == handledUpdateToken;
}
