# Android request timeout host audit

Run from the repository root:

```powershell
./tool/android_request_timeout_audit.ps1 -Phase final
```

The runner compiles the actual `AsrAccelerationBridge`, `QwenAsrBridge`,
`QwenWorkerWatchdog` and `RequestTimeouts`, then drives their method handlers,
service connection callbacks and reply messengers with a deterministic main
queue. It also runs the production timeout helper's JUnit tests. It uses the
existing cached Kotlin compiler, JUnit, Hamcrest and Android build JDK. It does
not invoke Flutter, Gradle, a device or a native model.

Host substitutes live in this directory, outside Android application/test
source sets. JSON strings are host transport tokens; malformed-token replies
exercise the bridge's error path but do not validate JSON syntax. Process
termination only records the requested PID. PCM descriptors check a fixture
file's existence; they do not exercise Binder FD transfer.

Evidence is written under
`build/android-resource-audit-20261101/timeouts/<phase>/`: frozen compile inputs,
source SHA-256 manifest, compiler output and JUnit output. The `-Phase` argument
labels the evidence directory. `-Before` substitutes the two original bridge
files saved under `build/android-resource-audit-20261101/before/`, enabling the
same tests to reproduce the old behavior without changing the workspace:

```powershell
./tool/android_request_timeout_audit.ps1 -Phase before-final -Before
```

The standalone audit cannot establish Android SDK compatibility, actual process
death ordering, native inference performance or device energy consumption.
