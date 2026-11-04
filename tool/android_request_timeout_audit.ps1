param(
    [ValidatePattern('^[a-z][a-z0-9-]*$')][string]$Phase = 'green',
    [switch]$Before
)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskCache = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
function TaskJar([string]$group, [string]$version = '') {
    $taskJarRoot = Join-Path $taskCache $group
    if ($version) { $taskJarRoot = Join-Path $taskJarRoot $version }
    $taskFile = Get-ChildItem -LiteralPath $taskJarRoot -Recurse -File -Filter '*.jar' | Select-Object -First 1
    if (-not $taskFile) { throw "Missing cached dependency $group $version" }
    return $taskFile.FullName
}
$taskJava = @('D:/Android Studio/jbr/bin/java.exe', 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe') |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $taskJava) { throw 'Android build JDK missing' }
$taskStdlib = TaskJar 'org.jetbrains.kotlin/kotlin-stdlib' '2.3.21'
$taskAnnotations = TaskJar 'org.jetbrains/annotations' '13.0'
$taskJunit = TaskJar 'junit/junit' '4.13.2'
$taskHamcrest = TaskJar 'org.hamcrest/hamcrest-core' '1.3'
$taskCompiler = @(
    (TaskJar 'org.jetbrains.kotlin/kotlin-compiler-embeddable' '2.3.21'),
    $taskStdlib, $taskAnnotations,
    (TaskJar 'org.jetbrains.kotlin/kotlin-script-runtime' '2.3.21'),
    (TaskJar 'org.jetbrains.kotlin/kotlin-reflect' '1.6.10'),
    (TaskJar 'org.jetbrains.kotlin/kotlin-daemon-embeddable' '2.3.21'),
    (TaskJar 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm'),
    (TaskJar 'org.jetbrains.intellij.deps/trove4j')
)
$taskOutput = Join-Path $taskRoot "build/android-resource-audit-20261101/timeouts/$Phase"
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
$taskSources = @(
    (Join-Path $taskRoot 'android/app/src/main/kotlin/com/example/video_player_app/AsrAccelerationBridge.kt'),
    (Join-Path $taskRoot 'android/app/src/main/kotlin/com/example/video_player_app/QwenAsrBridge.kt'),
    (Join-Path $taskRoot 'android/app/src/main/kotlin/com/example/video_player_app/QwenWorkerWatchdog.kt')
)
if ($Before) {
    $taskSources[0] = Join-Path $taskRoot 'build/android-resource-audit-20261101/before/AsrAccelerationBridge.kt'
    $taskSources[1] = Join-Path $taskRoot 'build/android-resource-audit-20261101/before/QwenAsrBridge.kt'
}
$taskHelper = Join-Path $taskRoot 'android/app/src/main/kotlin/com/example/video_player_app/RequestTimeouts.kt'
if (Test-Path -LiteralPath $taskHelper) { $taskSources += $taskHelper }
$taskSources += Get-ChildItem -LiteralPath (Join-Path $taskRoot 'tool/android_request_timeout_audit') -Filter '*.kt' -File |
    Select-Object -ExpandProperty FullName
$taskHelperTest = Join-Path $taskRoot 'android/app/src/test/kotlin/com/example/video_player_app/RequestTimeoutsTest.kt'
if (Test-Path -LiteralPath $taskHelperTest) { $taskSources += $taskHelperTest }
$taskSnapshot = Join-Path $taskOutput 'source'
New-Item -ItemType Directory -Force -Path $taskSnapshot | Out-Null
$taskFrozenSources = @()
$taskSourceRecords = @()
foreach ($taskSource in $taskSources) {
    $taskFrozen = Join-Path $taskSnapshot ([IO.Path]::GetFileName($taskSource))
    Copy-Item -LiteralPath $taskSource -Destination $taskFrozen
    $taskFrozenSources += $taskFrozen
    $taskSourceRecords += @{
        original = $taskSource
        snapshot = $taskFrozen
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $taskFrozen).Hash.ToLowerInvariant()
    }
}
@{
    phase = $Phase
    beforeBridges = [bool]$Before
    sources = $taskSourceRecords
    limits = @(
        'Real production Kotlin bridges with host Android/Flutter transport substitutes.',
        'JSON transport tokens test reply/error branches, not JSON format compatibility.',
        'No Android device, real Binder, native inference or battery measurement.',
        'No Flutter, Gradle, runtime upgrades or downloaded dependencies.'
    )
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskOutput 'sources.json') -Encoding utf8NoBOM
& $taskJava -cp ($taskCompiler -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -no-stdlib -no-reflect -jvm-target 17 -classpath "$taskStdlib;$taskAnnotations;$taskJunit" `
    -d (Join-Path $taskOutput 'classes') @taskFrozenSources *> (Join-Path $taskOutput 'compile.log')
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $taskOutput 'compile.log'); throw 'Host bridge compilation failed' }
$taskTests = @('com.example.video_player_app.RequestBridgeTimeoutTest')
if (Test-Path -LiteralPath $taskHelperTest) { $taskTests += 'com.example.video_player_app.RequestTimeoutsTest' }
& $taskJava "-Drequest.timeout.test.temp=$(Join-Path $taskOutput 'temp')" `
    -cp "$(Join-Path $taskOutput 'classes');$taskStdlib;$taskJunit;$taskHamcrest" `
    org.junit.runner.JUnitCore @taskTests *> (Join-Path $taskOutput 'junit.log')
$taskExit = $LASTEXITCODE
Get-Content (Join-Path $taskOutput 'junit.log')
Write-Output "JUNIT_EXIT=$taskExit"
exit $taskExit
