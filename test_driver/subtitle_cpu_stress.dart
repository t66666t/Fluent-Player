import 'dart:io';

// A disposable, separate CPU worker for the native scroll benchmark. The driver
// retains its Process handle and always terminates it in the test's finally.
void main() {
  stdout.writeln('ready');
  var value = 17;
  var batch = 0;
  while (true) {
    for (var i = 0; i < 800000; i++) {
      value = ((value * 1664525) + i + 1013904223) & 0x7fffffff;
    }
    // Observable output keeps the optimizer from eliminating the CPU work.
    if (++batch % 256 == 0) stderr.writeln(value);
  }
}
