param([string]$JavaPath = '')
$ErrorActionPreference = 'Stop'
if (-not $JavaPath) {
    $candidates = @(
        $(if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java.exe' }),
        'C:\Program Files\Android\Android Studio\jbr\bin\java.exe',
        'D:\Android Studio\jbr\bin\java.exe'
    )
    $JavaPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $JavaPath) { throw 'Supply -JavaPath pointing to the Android build JDK' }
}
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cacheRoot = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
function CachedJar([string]$relative) {
    $file = Get-ChildItem -LiteralPath (Join-Path $cacheRoot $relative) -Recurse -Filter '*.jar' -File |
        Select-Object -First 1
    if (-not $file) { throw "Missing cached Kotlin dependency: $relative" }
    return $file.FullName
}
$compiler = CachedJar 'org.jetbrains.kotlin/kotlin-compiler-embeddable/2.3.21'
$stdlib = CachedJar 'org.jetbrains.kotlin/kotlin-stdlib/2.3.21'
$annotations = CachedJar 'org.jetbrains/annotations/13.0'
$dependencies = @(
    $compiler, $stdlib, $annotations,
    (CachedJar 'org.jetbrains.kotlin/kotlin-reflect/1.6.10'),
    (CachedJar 'org.jetbrains.kotlin/kotlin-daemon-embeddable/2.3.21'),
    (CachedJar 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.9.0'),
    (CachedJar 'org.jetbrains.intellij.deps/trove4j/1.0.20200330')
)
$output = Join-Path $workspace '.artifacts/app-network-routes'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$jar = Join-Path $output 'route-tracker-tests.jar'
& $JavaPath -cp ($dependencies -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -no-stdlib -no-reflect -jvm-target 17 -classpath "$stdlib;$annotations" -d $jar `
    (Join-Path $workspace 'packages/app_network/android/src/main/kotlin/com/example/app_network/NetworkRouteChangeTracker.kt') `
    (Join-Path $workspace 'packages/app_network/android/src/test/kotlin/com/example/app_network/NetworkRouteChangeTrackerTest.kt')
if ($LASTEXITCODE -ne 0) { throw 'Route tracker compilation failed' }
& $JavaPath -cp "$jar;$stdlib" com.example.app_network.NetworkRouteChangeTrackerTestKt
if ($LASTEXITCODE -ne 0) { throw 'Route tracker tests failed' }
