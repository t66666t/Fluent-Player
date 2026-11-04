plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

// Python is only a build-machine tool for native ASR/OCR staging, not embedded.
fun resolveBuildPython(): String =
    System.getenv("FLUENT_BUILD_PYTHON")?.takeIf { it.isNotBlank() }
        ?: if (System.getProperty("os.name").lowercase().contains("windows")) "python" else "python3"

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties").let {
    if (it.exists()) it else rootProject.file("../.artifacts/community-signing/key.properties")
}
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
// Compatibility jobs may compile a development-signed release explicitly.
// A normal release must never silently acquire the debug signing identity.
val allowDevelopmentSigning = providers.gradleProperty("fluentDevelopmentSigning")
    .map { it == "true" }.getOrElse(false)
// Explicit upgrade path for users already running the old isolated profile APK.
// Keep the normal release package and its original signing key unchanged.
val legacyProfileUpgrade = false // Community must never impersonate the full-edition upgrade package.
val requestsRelease = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (requestsRelease && !keystorePropertiesFile.exists() && !allowDevelopmentSigning && !legacyProfileUpgrade) {
    throw GradleException("社区版 Release 需要独立签名；请先运行 python tool/create_community_signing.py。")
}

kotlin {
    jvmToolchain(21)
}

android {
    sourceSets.getByName("main").jniLibs.srcDir("../../build/generated/asr/jniLibs")
    sourceSets.getByName("main").assets.srcDir("../../build/generated/asr/assets")
    sourceSets.getByName("main").jniLibs.srcDir("../../build/generated/ocr/jniLibs")
    sourceSets.getByName("main").assets.srcDir("../../build/generated/ocr/assets")
    sourceSets.getByName("main").jniLibs.srcDir("../../build/generated/qwen_asr/jniLibs")
    sourceSets.getByName("main").assets.srcDir("../../build/generated/qwen_asr/assets")
    sourceSets.getByName("main").jniLibs.srcDir("../../build/generated/cohere_asr/jniLibs")
    sourceSets.getByName("main").assets.srcDir("../../build/generated/cohere_asr/assets")
    sourceSets.getByName("main").jniLibs.srcDir("../../build/generated/parakeet_ja/jniLibs")
    sourceSets.getByName("main").assets.srcDir("../../build/generated/parakeet_ja/assets")
    namespace = "com.example.video_player_app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // kotlinOptions has been removed, using jvmToolchain instead


    defaultConfig {
        // Preserve this identifier for upgrades and existing user data.
        applicationId = "com.example.video_player_app.community"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // Flutter would otherwise add 32-bit ARM and x86_64. The embedded
            // runtime and its browser impersonation library only ship arm64.
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a")
        }
    }

    lint {
        checkReleaseBuilds = true
        abortOnError = true
    }

    packaging {
        jniLibs {
            // FastRPC loads the matching Hexagon skeleton from a real directory;
            // it cannot read base.apk!/lib paths. Keep all pinned QNN dependencies
            // in Android's managed nativeLibraryDir, without copying at startup.
            useLegacyPackaging = true
            // Preserve vendor binaries and their DSP skeletons exactly as the
            // pinned SDK distributes them. Our wrapper is stripped at build time.
            keepDebugSymbols += setOf("**/libQnn*.so", "**/libocr_qnn.so", "**/libfluent_ocr_accel.so")
        }
    }

    signingConfigs {
        if (legacyProfileUpgrade) {
            create("legacyProfileUpgrade") {
                storeFile = file(providers.gradleProperty("fluentLegacyProfileKeystore").get())
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (legacyProfileUpgrade) {
                applicationIdSuffix = ".sidebar_profile"
                signingConfig = signingConfigs.getByName("legacyProfileUpgrade")
            } else if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else if (allowDevelopmentSigning) {
                signingConfig = signingConfigs.getByName("debug")
            }
            // Standard release: keep Android code and resources intact.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    // Profile builds are diagnostics, with their own installation and data.
    // A signing mismatch must never make a performance run replace the user's
    // normal application. Keep production/debug upgrade identities unchanged.
    buildTypes.configureEach {
        if (name == "profile") applicationIdSuffix = ".sidebar_profile"
    }
}

val stageAsrAcceleration by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(resolveBuildPython(), "tool/stage_android_asr.py")
}
tasks.named("preBuild") { dependsOn(stageAsrAcceleration) }

val stageOcrAcceleration by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(resolveBuildPython(), "tool/stage_android_ocr.py")
}
tasks.named("preBuild") { dependsOn(stageOcrAcceleration) }

val stageQwenAudio by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(resolveBuildPython(), "tool/stage_android_qwen.py")
}
tasks.named("preBuild") { dependsOn(stageQwenAudio) }

val stageCohereAudio by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(resolveBuildPython(), "tool/stage_android_cohere.py")
}
tasks.named("preBuild") { dependsOn(stageCohereAudio) }

val stageParakeetJapanese by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    commandLine(resolveBuildPython(), "tool/stage_android_parakeet_ja.py")
}
tasks.named("preBuild") { dependsOn(stageParakeetJapanese) }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    // audio_service keeps androidx.media as an implementation dependency, so
    // MediaNotificationGate cannot see MediaSessionCompat unless the app
    // depends on it directly. The class still lives in
    // android.support.v4.media.session inside this AndroidX artifact.
    implementation("androidx.media:media:1.7.0")
}



configurations.all {
    resolutionStrategy {
        val media3Version = "1.9.0"
        force("androidx.media3:media3-exoplayer:$media3Version")
        force("androidx.media3:media3-exoplayer-dash:$media3Version")
        force("androidx.media3:media3-exoplayer-hls:$media3Version")
        force("androidx.media3:media3-exoplayer-rtsp:$media3Version")
        force("androidx.media3:media3-exoplayer-smoothstreaming:$media3Version")
        force("androidx.media3:media3-datasource-cronet:$media3Version")
        force("androidx.media3:media3-session:$media3Version")
        force("androidx.media3:media3-extractor:$media3Version")
        force("androidx.media3:media3-common:$media3Version")
        force("androidx.media3:media3-ui:$media3Version")
        force("androidx.media3:media3-container:$media3Version")
        force("androidx.media3:media3-database:$media3Version")
        force("androidx.media3:media3-datasource:$media3Version")
        force("androidx.media3:media3-decoder:$media3Version")
    }
}

flutter {
    source = "../.."
}

// Ensure flutter assets are properly packaged
android.applicationVariants.all {
    val variant = this
    variant.outputs
        .map { it as com.android.build.gradle.internal.api.BaseVariantOutputImpl }
        .forEach { output ->
            output.outputFileName = "app-${variant.buildType.name}.apk"
        }
}
