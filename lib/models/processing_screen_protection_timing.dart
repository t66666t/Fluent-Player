/// Shared limits for the persisted preference and both settings entry points.
abstract final class ProcessingScreenProtectionTiming {
  static const defaultSeconds = 15;
  static const minSeconds = 1;
  static const maxSeconds = 86400;

  static int normalize(int seconds) => seconds.clamp(minSeconds, maxSeconds);
}
