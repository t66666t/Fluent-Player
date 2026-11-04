// Creates an isolated playback test host. Never installs or operates a device.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/prepare_playback_recovery_audit.dart '
      '[--flutter=<flutter executable>] [--ffmpeg=<ffmpeg executable>]\n'
      'Writes only build/playback-recovery-audit/native_app. '
      'Requires Flutter and FFmpeg; prepares fixtures without installing an app.',
    );
    return;
  }
  final options = <String, String>{};
  for (final arg in args) {
    final match = RegExp(r'^--(flutter|ffmpeg)=(.+)$').firstMatch(arg);
    if (match == null) throw ArgumentError('Unknown argument: $arg');
    options[match[1]!] = match[2]!;
  }
  final root = p.dirname(p.dirname(Platform.script.toFilePath()));
  final output = p.join(root, 'build', 'playback-recovery-audit', 'native_app');
  final marker = File(p.join(output, '.playback-recovery-audit'));
  if (Directory(output).existsSync() && !marker.existsSync()) {
    throw StateError('Refusing to overwrite an unmarked directory: $output');
  }
  final siblingFlutter = p.normalize(
    p.join(
      p.dirname(Platform.resolvedExecutable),
      '..',
      '..',
      '..',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    ),
  );
  final flutter =
      options['flutter'] ??
      (File(siblingFlutter).existsSync() ? siblingFlutter : 'flutter');
  final ffmpeg = options['ffmpeg'] ?? 'ffmpeg';
  Future<void> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory ?? root,
      runInShell: Platform.isWindows && executable.endsWith('.bat'),
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      throw ProcessException(executable, arguments, 'Exit $code', code);
    }
  }

  // Fail before creating anything when the fixture encoder is unavailable.
  await run(ffmpeg, ['-hide_banner', '-version']);
  if (!marker.existsSync()) {
    await run(flutter, [
      'create',
      '--no-pub',
      '--platforms=android,windows',
      '--org=com.fluentplayer.audit',
      '--project-name=playback_recovery_audit',
      output,
    ]);
    await marker.writeAsString('playback-recovery-audit/1\n');
  }
  Future<void> write(String name, String contents) async {
    final file = File(p.join(output, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  final source =
      loadYaml(await File(p.join(root, 'pubspec.yaml')).readAsString()) as Map;
  final overrides = <String, Object?>{};
  for (final entry in (source['dependency_overrides'] as Map).entries) {
    final value = entry.value;
    overrides[entry.key as String] = value is Map && value['path'] is String
        ? {...value, 'path': p.normalize(p.join(root, value['path'] as String))}
        : value;
  }
  await write(
    'pubspec.yaml',
    const JsonEncoder.withIndent('  ').convert({
      'name': 'playback_recovery_audit',
      'publish_to': 'none',
      'version': '1.0.0+1',
      'environment': source['environment'],
      'dependencies': {
        'flutter': {'sdk': 'flutter'},
        'video_player_app': {'path': root},
      },
      'dependency_overrides': overrides,
      'dev_dependencies': {
        'flutter_test': {'sdk': 'flutter'},
        'integration_test': {'sdk': 'flutter'},
      },
      'flutter': {
        'uses-material-design': true,
        'assets': ['assets/'],
      },
      if (source['hooks'] != null) 'hooks': source['hooks'],
    }),
  );
  await File(p.join(root, 'pubspec.lock')).copy(p.join(output, 'pubspec.lock'));
  await write(
    'integration_test/playback_recovery_native_test.dart',
    await File(
      p.join(root, 'integration_test/playback_recovery_native_test.dart'),
    ).readAsString(),
  );
  await write(
    'android/app/src/main/kotlin/com/fluentplayer/audit/playback_recovery_audit/MainActivity.kt',
    '''
package com.fluentplayer.audit.playback_recovery_audit
import com.ryanheise.audioservice.AudioServiceFragmentActivity
class MainActivity : AudioServiceFragmentActivity()
''',
  );
  await write('android/app/src/main/AndroidManifest.xml', r'''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <application android:usesCleartextTraffic="true" android:label="Playback Recovery Audit"
        android:name="${applicationName}" android:icon="@mipmap/ic_launcher">
        <meta-data android:name="io.flutter.embedding.android.EnableHcpp" android:value="true"/>
        <activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTop"
            android:taskAffinity="" android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true" android:windowSoftInputMode="adjustResize">
            <meta-data android:name="io.flutter.embedding.android.NormalTheme" android:resource="@style/NormalTheme"/>
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <meta-data android:name="flutterEmbedding" android:value="2"/>
        <service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">
            <intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
        </receiver>
    </application>
</manifest>
''');
  // Same toolchain as the app. These host-only settings do not alter its build.
  final settings = await File(
    p.join(root, 'android/settings.gradle.kts'),
  ).readAsString();
  await write(
    'android/settings.gradle.kts',
    settings.replaceAll(
      RegExp(r'^.*id\("com\.chaquo\.python"\).*$\n?', multiLine: true),
      '',
    ),
  );
  await File(
    p.join(root, 'android/gradle/wrapper/gradle-wrapper.properties'),
  ).copy(p.join(output, 'android/gradle/wrapper/gradle-wrapper.properties'));
  await write('android/gradle.properties', '''
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G
android.useAndroidX=true
android.newDsl=false
android.builtInKotlin=false
kotlin.incremental=false
kotlin.compiler.execution.strategy=in-process
org.gradle.workers.max=2
''');
  await write('android/app/build.gradle.kts', '''
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "com.fluentplayer.audit.playback_recovery_audit"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.fluentplayer.audit.playback_recovery_audit"
        minSdk = 24
        targetSdk = 36
        ndk { abiFilters.clear(); abiFilters += "arm64-v8a" }
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    // Unused model plugins are transitive dependencies of the app package.
    // This playback-only host never loads those inference runtimes.
    packaging { jniLibs { pickFirsts += "**/libonnxruntime.so" } }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
flutter { source = "../.." }
dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5") }
''');
  final cmakeFile = File(p.join(output, 'windows/CMakeLists.txt'));
  var cmake = await cmakeFile.readAsString();
  if (!cmake.contains('_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS')) {
    cmake = cmake.replaceFirst(
      'project(playback_recovery_audit LANGUAGES CXX)',
      'project(playback_recovery_audit LANGUAGES CXX)\n'
          'add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)',
    );
  }
  // Reconfigure into the test bundle, including after a failed first build.
  if (!cmake.contains('CACHE PATH "Audit bundle" FORCE')) {
    cmake = cmake.replaceFirst(
      'set(INSTALL_BUNDLE_DATA_DIR',
      'set(CMAKE_INSTALL_PREFIX "\${BUILD_BUNDLE_DIR}" CACHE PATH "Audit bundle" FORCE)\n'
          'set(INSTALL_BUNDLE_DATA_DIR',
    );
  }
  await cmakeFile.writeAsString(cmake);
  final assets = p.join(output, 'assets');
  await Directory(assets).create(recursive: true);
  final video = p.join(assets, 'video.mp4');
  final audio = p.join(assets, 'audio.m4a');
  Future<void> encode(List<String> arguments) =>
      run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...arguments]);
  await encode([
    for (final color in ['red', 'green', 'blue']) ...[
      '-f',
      'lavfi',
      '-i',
      'color=c=$color:s=320x180:r=30:d=7',
    ],
    '-filter_complex',
    '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]',
    '-map',
    '[v]',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-g',
    '60',
    '-movflags',
    '+faststart',
    video,
  ]);
  await encode([
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=48000:duration=21',
    '-af',
    'volume=0.01',
    '-c:a',
    'aac',
    '-movflags',
    '+faststart',
    audio,
  ]);
  for (final name in ['local.mp4', 'wide.mkv']) {
    await encode([
      '-i',
      video,
      '-i',
      audio,
      '-c',
      'copy',
      if (name.endsWith('.mp4')) ...['-movflags', '+faststart'],
      p.join(assets, name),
    ]);
  }
  await run(flutter, ['pub', 'get', '--offline'], workingDirectory: output);
  stdout.writeln(
    'Prepared isolated host: $output\n'
    'Android package: com.fluentplayer.audit.playback_recovery_audit\n'
    'No app was installed and no device was accessed.',
  );
}
