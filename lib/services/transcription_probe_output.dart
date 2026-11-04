import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Process exit and pipe EOF are separate events. Keep collecting metadata
/// after exit, while bounding a pipe retained by an unexpected descendant.
Future<ProcessResult> collectTranscriptionProbeOutput(
  Process process, {
  Duration drainTimeout = const Duration(seconds: 2),
}) async {
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  final stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .listen(
        stdout.write,
        onDone: () {
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!stdoutDone.isCompleted) stdoutDone.completeError(error, stack);
        },
        cancelOnError: true,
      );
  final stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(
        stderr.write,
        onDone: () {
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!stderrDone.isCompleted) stderrDone.completeError(error, stack);
        },
        cancelOnError: true,
      );

  Timer? drainTimer;
  bool finished = false;
  int? exitCode;
  // Install all error handlers before awaiting anything: a pipe can fail while
  // the process is still running, before its exit future completes.
  final completed = Future.wait<void>([
    process.exitCode.then((value) {
      exitCode = value;
      if (finished) return;
      drainTimer = Timer(drainTimeout, () {
        final error = TimeoutException('媒体探测输出未及时关闭', drainTimeout);
        if (!stdoutDone.isCompleted) stdoutDone.completeError(error);
        if (!stderrDone.isCompleted) stderrDone.completeError(error);
      });
    }),
    stdoutDone.future,
    stderrDone.future,
  ], eagerError: true);
  try {
    await completed;
    return ProcessResult(
      process.pid,
      exitCode!,
      stdout.toString(),
      stderr.toString(),
    );
  } catch (_) {
    process.kill();
    rethrow;
  } finally {
    finished = true;
    drainTimer?.cancel();
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}
