"""Exercise production Android video-output Java with deterministic JVM shims.

No Gradle, emulator, JNI library or dependency installation is involved. These
checks validate ownership and callback ordering, not Android rendering/inference.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


STUBS = {
    "android/util/Log.java": """package android.util;
public final class Log {
  public static int i(String tag, String text) { return 0; }
  public static int e(String tag, String text, Throwable error) { return 0; }
}
""",
    "android/os/Looper.java": """package android.os;
public final class Looper {
  private static final Looper MAIN = new Looper();
  public static Looper getMainLooper() { return MAIN; }
}
""",
    "android/os/Handler.java": """package android.os;
import java.util.*;
public final class Handler {
  private static final List<Runnable> pending = new ArrayList<>();
  public static final List<Long> delays = new ArrayList<>();
  public Handler(Looper looper) {}
  public boolean postDelayed(Runnable task, long delay) {
    pending.add(task); delays.add(delay); return true;
  }
  public static int pendingCount() { return pending.size(); }
  public static void drain() {
    List<Runnable> batch = new ArrayList<>(pending); pending.clear();
    for (Runnable task : batch) task.run();
  }
  public static void reset() { pending.clear(); delays.clear(); }
}
""",
    "android/view/Surface.java": """package android.view;
public final class Surface {
  public int releases;
  public void release() { releases++; }
}
""",
    "androidx/annotation/NonNull.java": """package androidx.annotation;
public @interface NonNull {}
""",
    "io/flutter/view/TextureRegistry.java": """package io.flutter.view;
import android.view.Surface;
public interface TextureRegistry {
  SurfaceProducer createSurfaceProducer();
  interface SurfaceProducer {
    interface Callback { void onSurfaceAvailable(); void onSurfaceCleanup(); }
    long id(); int getWidth(); int getHeight(); void setSize(int width, int height);
    Surface getSurface(); void setCallback(Callback callback); void release();
  }
}
""",
    "io/flutter/plugin/common/BinaryMessenger.java": """package io.flutter.plugin.common;
public interface BinaryMessenger {}
""",
    "io/flutter/plugin/common/MethodCall.java": """package io.flutter.plugin.common;
import java.util.Map;
public final class MethodCall {
  public final String method;
  private final Map<String, Object> arguments;
  public MethodCall(String method, Map<String, Object> arguments) {
    this.method = method; this.arguments = arguments;
  }
  @SuppressWarnings("unchecked")
  public <T> T argument(String key) { return (T) arguments.get(key); }
}
""",
    "io/flutter/plugin/common/MethodChannel.java": """package io.flutter.plugin.common;
import java.util.*;
public final class MethodChannel {
  public static final List<MethodChannel> instances = new ArrayList<>();
  public static boolean failNextHandlerClear;
  public final List<Object> events = new ArrayList<>();
  public MethodCallHandler handler;
  public MethodChannel(BinaryMessenger messenger, String name) { instances.add(this); }
  public void setMethodCallHandler(MethodCallHandler value) {
    handler = value;
    if (value == null && failNextHandlerClear) {
      failNextHandlerClear = false; throw new IllegalStateException("channel detach failed");
    }
  }
  public void invokeMethod(String method, Object arguments) { events.add(arguments); }
  public interface MethodCallHandler { void onMethodCall(MethodCall call, Result result); }
  public interface Result { void success(Object value); void notImplemented(); }
}
""",
    "io/flutter/embedding/engine/plugins/FlutterPlugin.java": """package io.flutter.embedding.engine.plugins;
import io.flutter.view.TextureRegistry;
import io.flutter.plugin.common.BinaryMessenger;
public interface FlutterPlugin {
  void onAttachedToEngine(FlutterPluginBinding binding);
  void onDetachedFromEngine(FlutterPluginBinding binding);
  final class FlutterPluginBinding {
    private final TextureRegistry textures;
    private final BinaryMessenger messenger = new BinaryMessenger() {};
    public FlutterPluginBinding(TextureRegistry textures) { this.textures = textures; }
    public TextureRegistry getTextureRegistry() { return textures; }
    public BinaryMessenger getBinaryMessenger() { return messenger; }
  }
}
""",
    "com/alexmercerind/mediakitandroidhelper/MediaKitAndroidHelper.java": """package com.alexmercerind.mediakitandroidhelper;
import java.util.*;
public final class MediaKitAndroidHelper {
  public static final Map<Long, Object> live = new HashMap<>();
  public static final List<Long> created = new ArrayList<>();
  public static final List<Long> deleted = new ArrayList<>();
  private static long sequence = 100;
  public static Long nextValue;
  public static boolean failCreate, throwCreate;
  public static long newGlobalObjectRef(Object object) {
    if (throwCreate) { throwCreate = false; throw new IllegalStateException("new ref failed"); }
    if (failCreate) { failCreate = false; return 0; }
    long value = nextValue == null ? ++sequence : nextValue;
    nextValue = null;
    if (live.put(value, object) != null) throw new AssertionError("reused a live handle");
    created.add(value); return value;
  }
  public static void deleteGlobalObjectRef(long value) {
    deleted.add(value);
    if (live.remove(value) == null) throw new AssertionError("double delete " + value);
  }
  public static void reset() {
    live.clear(); created.clear(); deleted.clear(); nextValue = null;
    failCreate = throwCreate = false;
  }
}
""",
    "com/alexmercerind/media_kit_video/Utils.java": """package com.alexmercerind.media_kit_video;
final class Utils { static boolean isEmulator() { return false; } }
""",
    "com/alexmercerind/media_kit_video/SurfaceReferenceAudit.java": r"""
package com.alexmercerind.media_kit_video;
import android.os.Handler;
import android.view.Surface;
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper;
import io.flutter.view.TextureRegistry;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import io.flutter.plugin.common.*;
import java.lang.reflect.Method;
import java.lang.reflect.Field;
import java.util.*;

public final class SurfaceReferenceAudit {
  private static int passed, failed;
  private static final class Producer implements TextureRegistry.SurfaceProducer {
    final long id;
    int width = 1, height = 1, releases, gets, sizeChanges;
    boolean released, cleanupOnRelease, throwRelease, throwGet;
    Surface surface = new Surface();
    Callback callback;
    Producer(long id) { this.id = id; }
    public long id() { return id; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public void setSize(int w, int h) {
      if (released) throw new IllegalStateException("resizing released producer");
      width = w; height = h; sizeChanges++; surface = new Surface();
    }
    public Surface getSurface() {
      gets++;
      if (released || throwGet) throw new IllegalStateException("surface unavailable");
      return surface;
    }
    public void setCallback(Callback value) { callback = value; }
    public void release() {
      releases++; released = true;
      if (cleanupOnRelease && callback != null) callback.onSurfaceCleanup();
      if (throwRelease) throw new IllegalStateException("producer release failed");
      surface.release();
    }
  }
  private static final class Registry implements TextureRegistry {
    final List<Producer> producers = new ArrayList<>();
    public SurfaceProducer createSurfaceProducer() {
      Producer value = new Producer(producers.size() + 1);
      producers.add(value); return value;
    }
    Producer first() { return producers.get(0); }
  }
  private static final class Events implements TextureUpdateCallback {
    final List<Long> wids = new ArrayList<>();
    int width, height;
    boolean failAvailable, failCleanup;
    public void onTextureUpdate(long id, long wid, int width, int height) {
      this.width = width; this.height = height; wids.add(wid);
      if (wid == 0 ? failCleanup : failAvailable) throw new IllegalStateException("callback failed");
    }
    long last() { return wids.get(wids.size() - 1); }
  }
  private static void check(boolean value, String reason) {
    if (!value) throw new AssertionError(reason);
  }
  private static void balanced() {
    check(MediaKitAndroidHelper.live.isEmpty(), "native references still live: " + MediaKitAndroidHelper.live.keySet());
    check(MediaKitAndroidHelper.created.size() == MediaKitAndroidHelper.deleted.size(), "unbalanced create/delete attempts");
    for (long delay : Handler.delays) check(delay == 5000, "changed five-second retirement grace");
  }
  private static void closeAll(VideoOutputManager manager) throws Exception {
    Method close = VideoOutputManager.class.getDeclaredMethod("disposeAll");
    close.setAccessible(true); close.invoke(manager);
  }
  private static void run(String name, Checked body) {
    Handler.reset(); MediaKitAndroidHelper.reset(); MethodChannel.instances.clear();
    MethodChannel.failNextHandlerClear = false;
    try { body.run(); passed++; System.out.println("PASS " + name); }
    catch (Throwable error) { failed++; System.out.println("FAIL " + name + ": " + error); }
    finally { Handler.reset(); MediaKitAndroidHelper.reset(); }
  }
  private interface Checked { void run() throws Exception; }
  private static final MethodChannel.Result RESULT = new MethodChannel.Result() {
    public void success(Object value) {}
    public void notImplemented() { throw new AssertionError("unexpected notImplemented"); }
  };
  private static void call(MediaKitVideoPlugin plugin, String method, long handle) {
    Map<String, Object> arguments = new HashMap<>();
    arguments.put("handle", Long.toString(handle));
    arguments.put("width", "640"); arguments.put("height", "360");
    plugin.onMethodCall(new MethodCall(method, arguments), RESULT);
  }
  @SuppressWarnings("unchecked")
  private static TextureUpdateCallback capturedCallback(MediaKitVideoPlugin plugin, long handle) throws Exception {
    Field ownerField = MediaKitVideoPlugin.class.getDeclaredField("videoOutputManager");
    ownerField.setAccessible(true);
    Field outputsField = VideoOutputManager.class.getDeclaredField("videoOutputs");
    outputsField.setAccessible(true);
    Map<Long, VideoOutput> outputs = (Map<Long, VideoOutput>) outputsField.get(ownerField.get(plugin));
    Field callbackField = VideoOutput.class.getDeclaredField("textureUpdateCallback");
    callbackField.setAccessible(true);
    return (TextureUpdateCallback) callbackField.get(outputs.get(handle));
  }

  public static void main(String[] args) {
    run("replacement retires every previous reference with original grace", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(320, 180); out.setSurfaceSize(640, 360); out.setSurfaceSize(1280, 720);
      check(MediaKitAndroidHelper.created.size() == 3, "missing normal replacement callbacks");
      check(Handler.pendingCount() == 2, "overwritten references were not scheduled");
      check(MediaKitAndroidHelper.live.size() == 3, "references deleted before grace");
      Handler.drain(); check(MediaKitAndroidHelper.live.size() == 1, "replacement ownership not bounded");
      out.dispose(); Handler.drain(); balanced();
    });
    run("same size preserves callback and allocation counts", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); long wid = e.last(); out.setSurfaceSize(640, 360);
      check(e.wids.size() == 1 && e.last() == wid, "same-size rebind");
      check(e.width == 640 && e.height == 360, "visible dimensions changed");
      out.dispose(); Handler.drain(); balanced();
    });
    run("duplicate cleanup and dispose retire exactly once", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); out.onSurfaceCleanup(); out.onSurfaceCleanup(); out.dispose(); out.dispose();
      check(Handler.pendingCount() == 1, "duplicate retirement scheduled");
      check(e.wids.size() == 2 && e.last() == 0, "cleanup emitted repeated unavailable callbacks");
      check(r.first().releases == 1, "producer disposed repeatedly");
      Handler.drain(); balanced();
    });
    run("numeric JNI handles can be reused after retirement", () -> {
      Registry r = new Registry(); VideoOutput out = new VideoOutput(r, new Events());
      out.setSurfaceSize(640, 360); long first = MediaKitAndroidHelper.created.get(0);
      out.onSurfaceCleanup(); Handler.drain();
      MediaKitAndroidHelper.nextValue = first;
      out.onSurfaceAvailable(); out.onSurfaceCleanup(); Handler.drain(); out.dispose();
      check(Collections.frequency(MediaKitAndroidHelper.deleted, first) == 2, "reused handle skipped deletion");
      balanced();
    });
    for (boolean throwsCreate : new boolean[]{false, true}) {
      run("failed new reference clears output and retires old; throws=" + throwsCreate, () -> {
        Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
        out.setSurfaceSize(640, 360);
        MediaKitAndroidHelper.failCreate = !throwsCreate; MediaKitAndroidHelper.throwCreate = throwsCreate;
        out.onSurfaceAvailable(); check(e.last() == 0, "failed acquisition did not publish unavailable");
        Handler.drain(); check(MediaKitAndroidHelper.live.isEmpty(), "failed acquisition orphaned old reference");
        out.dispose(); Handler.drain(); balanced();
      });
    }
    run("surface acquisition exception preserves the existing owner", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); long original = e.last(); r.first().throwGet = true;
      try { out.onSurfaceAvailable(); } catch (IllegalStateException expected) {}
      check(e.last() == original && MediaKitAndroidHelper.live.size() == 1, "existing owner lost before acquisition");
      r.first().throwGet = false; out.dispose(); Handler.drain(); balanced();
    });
    run("replacement callback failure cannot orphan either reference", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); long previous = e.last(); e.failAvailable = true;
      try { out.onSurfaceAvailable(); } catch (IllegalStateException expected) {}
      Handler.drain();
      check(MediaKitAndroidHelper.live.size() == 1 && MediaKitAndroidHelper.live.containsKey(previous), "failed publication retired the still-bound owner");
      e.failAvailable = false; out.dispose(); Handler.drain(); balanced();
    });
    for (boolean unavailable : new boolean[]{false, true}) {
      run("nested failed publications restore the successful binding; zero=" + unavailable, () -> {
        Registry r = new Registry(); VideoOutput[] out = new VideoOutput[1];
        boolean[] fail = {false}, nested = {false}; long[] binding = {0};
        out[0] = new VideoOutput(r, (id, wid, width, height) -> {
          if (!fail[0]) { binding[0] = wid; return; }
          if (!nested[0]) {
            nested[0] = true;
            MediaKitAndroidHelper.failCreate = unavailable;
            out[0].onSurfaceAvailable();
            nested[0] = false;
            throw new IllegalStateException("outer publication failed");
          }
          throw new IllegalStateException("inner publication failed");
        });
        out[0].setSurfaceSize(640, 360); long original = binding[0];
        fail[0] = true; MediaKitAndroidHelper.failCreate = unavailable;
        out[0].onSurfaceAvailable(); fail[0] = false; Handler.drain();
        check(binding[0] == original, "failed callback changed simulated native binding");
        check(MediaKitAndroidHelper.live.size() == 1 && MediaKitAndroidHelper.live.containsKey(original), "nested rollback retired the sole successful binding");
        out[0].dispose(); Handler.drain(); balanced();
      });
    }
    run("successful inner publication cannot be rolled back by outer failure", () -> {
      Registry r = new Registry(); VideoOutput[] out = new VideoOutput[1];
      boolean[] reenter = {false}, nested = {false}; long[] binding = {0};
      out[0] = new VideoOutput(r, (id, wid, width, height) -> {
        if (reenter[0] && !nested[0]) {
          nested[0] = true; out[0].onSurfaceAvailable(); nested[0] = false;
          throw new IllegalStateException("outer publication failed after inner success");
        }
        binding[0] = wid;
      });
      out[0].setSurfaceSize(640, 360); long original = binding[0];
      reenter[0] = true; out[0].onSurfaceAvailable(); reenter[0] = false; Handler.drain();
      check(binding[0] != original && MediaKitAndroidHelper.live.size() == 1 && MediaKitAndroidHelper.live.containsKey(binding[0]), "outer rollback replaced/deleted a newer successful binding");
      out[0].dispose(); Handler.drain(); balanced();
    });
    run("inner cleanup cannot be undone by outer publication failure", () -> {
      Registry r = new Registry(); VideoOutput[] out = new VideoOutput[1];
      boolean[] reenter = {false}; long[] binding = {0};
      out[0] = new VideoOutput(r, (id, wid, width, height) -> {
        if (reenter[0] && wid != 0) {
          out[0].onSurfaceCleanup();
          throw new IllegalStateException("outer publication failed after cleanup");
        }
        binding[0] = wid;
      });
      out[0].setSurfaceSize(640, 360); reenter[0] = true;
      out[0].onSurfaceAvailable(); reenter[0] = false; Handler.drain();
      check(binding[0] == 0 && MediaKitAndroidHelper.live.isEmpty(), "outer failure resurrected a cleaned-up binding");
      out[0].dispose(); Handler.drain(); balanced();
    });
    run("cleanup callback failure still retires the taken reference", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); e.failCleanup = true;
      try { out.onSurfaceCleanup(); } catch (IllegalStateException expected) {}
      Handler.drain(); check(MediaKitAndroidHelper.live.isEmpty(), "callback failure skipped retirement");
      e.failCleanup = false; out.dispose(); Handler.drain(); balanced();
    });
    run("producer owns Surface and disposal never acquires one", () -> {
      Registry r = new Registry(); VideoOutput out = new VideoOutput(r, new Events());
      out.setSurfaceSize(640, 360); int gets = r.first().gets; Surface surface = r.first().surface;
      out.dispose(); check(r.first().gets == gets, "dispose requested a fresh Surface");
      check(surface.releases == 1, "Surface released by both producer and output");
      Handler.drain(); balanced();
    });
    run("release exceptions and reentrant cleanup remain idempotent", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); r.first().cleanupOnRelease = true; r.first().throwRelease = true;
      out.dispose(); out.dispose();
      check(r.first().releases == 1 && Handler.pendingCount() == 1, "reentrant disposal repeated work");
      Handler.drain(); balanced();
    });
    run("late availability and resize cannot resurrect disposed output", () -> {
      Registry r = new Registry(); Events e = new Events(); VideoOutput out = new VideoOutput(r, e);
      out.setSurfaceSize(640, 360); out.dispose(); Handler.drain();
      int created = MediaKitAndroidHelper.created.size(), gets = r.first().gets, events = e.wids.size();
      try { r.first().callback.onSurfaceAvailable(); } catch (IllegalStateException expected) {}
      out.setSurfaceSize(1280, 720); out.onSurfaceCleanup();
      check(MediaKitAndroidHelper.created.size() == created && r.first().gets == gets, "late event acquired a Surface");
      check(e.wids.size() == events, "late event published output"); balanced();
    });
    run("manager close survives output exceptions and rejects late operations", () -> {
      Registry r = new Registry(); VideoOutputManager manager = new VideoOutputManager(r);
      Events first = new Events(); manager.create(1, first); manager.create(2, new Events());
      manager.setSurfaceSize(1, 640, 360); manager.setSurfaceSize(2, 640, 360);
      first.failCleanup = true; r.first().throwRelease = true;
      closeAll(manager); closeAll(manager); manager.dispose(1); manager.setSurfaceSize(2, 10, 10); manager.create(3, new Events());
      check(r.producers.size() == 2, "closed manager created an output");
      for (Producer p : r.producers) check(p.releases == 1, "manager skipped/repeated output disposal");
      Handler.drain(); balanced();
    });
    run("engine detach releases outputs without Dart dispose", () -> {
      Registry r = new Registry(); MediaKitVideoPlugin plugin = new MediaKitVideoPlugin();
      FlutterPluginBinding binding = new FlutterPluginBinding(r); plugin.onAttachedToEngine(binding);
      call(plugin, "VideoOutputManager.Create", 1); call(plugin, "VideoOutputManager.SetSurfaceSize", 1);
      call(plugin, "VideoOutputManager.Create", 2); call(plugin, "VideoOutputManager.SetSurfaceSize", 2);
      plugin.onDetachedFromEngine(binding); plugin.onDetachedFromEngine(binding);
      check(MethodChannel.instances.get(0).handler == null, "engine method handler remains attached");
      for (Producer p : r.producers) check(p.releases == 1, "engine left output alive");
      Handler.drain(); balanced();
      call(plugin, "VideoOutputManager.Dispose", 1);
    });
    run("channel detachment exception cannot skip output teardown", () -> {
      Registry r = new Registry(); MediaKitVideoPlugin plugin = new MediaKitVideoPlugin();
      FlutterPluginBinding binding = new FlutterPluginBinding(r); plugin.onAttachedToEngine(binding);
      call(plugin, "VideoOutputManager.Create", 1); call(plugin, "VideoOutputManager.SetSurfaceSize", 1);
      MethodChannel.failNextHandlerClear = true;
      try { plugin.onDetachedFromEngine(binding); } catch (IllegalStateException expected) {}
      plugin.onDetachedFromEngine(binding); Handler.drain(); balanced();
      check(r.first().releases == 1, "channel exception skipped/repeated producer release");
      call(plugin, "VideoOutputManager.Create", 2);
      check(r.producers.size() == 1, "detachment failure left an active owner");
    });
    run("old engine callbacks never target a reattached engine", () -> {
      Registry old = new Registry(); MediaKitVideoPlugin plugin = new MediaKitVideoPlugin();
      FlutterPluginBinding before = new FlutterPluginBinding(old); plugin.onAttachedToEngine(before);
      call(plugin, "VideoOutputManager.Create", 1); call(plugin, "VideoOutputManager.SetSurfaceSize", 1);
      TextureUpdateCallback queued = capturedCallback(plugin, 1);
      plugin.onDetachedFromEngine(before); Handler.drain();
      Registry next = new Registry(); FlutterPluginBinding after = new FlutterPluginBinding(next);
      plugin.onAttachedToEngine(after); call(plugin, "VideoOutputManager.Create", 2); call(plugin, "VideoOutputManager.SetSurfaceSize", 2);
      MethodChannel current = MethodChannel.instances.get(1); int events = current.events.size();
      try { old.first().callback.onSurfaceAvailable(); } catch (IllegalStateException expected) {}
      old.first().callback.onSurfaceCleanup();
      // Model a callback already past the output's disposed guard when the
      // old engine detached; the plugin's own identity guard is independent.
      queued.onTextureUpdate(1, 9999, 640, 360);
      check(current.events.size() == events, "old callback reached new engine");
      plugin.onDetachedFromEngine(after); Handler.drain(); balanced();
    });
    System.out.println("RESULT passed=" + passed + " failed=" + failed);
    if (failed != 0) System.exit(1);
  }
}
""",
}


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/android-resource-audit-20261101/surfaces/current"))
    parser.add_argument("--jdk", type=Path, default=Path("D:/Android Studio/jbr"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = output / "shims"
    classes = output / "classes"
    classes.mkdir(exist_ok=True)
    java_files = []
    for name, source in STUBS.items():
        destination = sources / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(source, encoding="utf-8")
        java_files.append(destination)
    production = root / "third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video"
    java_files.extend(production / name for name in (
        "VideoOutput.java", "VideoOutputManager.java", "MediaKitVideoPlugin.java", "TextureUpdateCallback.java",
    ))
    suffix = ".exe" if sys.platform == "win32" else ""
    javac = args.jdk / "bin" / f"javac{suffix}"
    java = args.jdk / "bin" / f"java{suffix}"
    compiler = str(javac) if javac.exists() else shutil.which("javac")
    runtime = str(java) if java.exists() else shutil.which("java")
    if not compiler or not runtime:
        raise SystemExit("A JDK with javac/java is required; no packages will be installed.")
    compile_result = subprocess.run(
        [compiler, "-J-Duser.language=en", "-J-Duser.country=US", "-encoding", "UTF-8", "-d", str(classes), *map(str, java_files)],
        cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    (output / "javac.log").write_text(compile_result.stdout + compile_result.stderr, encoding="utf-8")
    if compile_result.returncode:
        print(compile_result.stdout + compile_result.stderr)
        return compile_result.returncode
    result = subprocess.run(
        [runtime, "-cp", str(classes), "com.alexmercerind.media_kit_video.SurfaceReferenceAudit"],
        cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    log = result.stdout + result.stderr
    (output / "results.log").write_text(log, encoding="utf-8")
    (output / "result.json").write_text(json.dumps({
        "exitCode": result.returncode,
        "productionSources": [str(path.relative_to(root)) for path in java_files if path.is_relative_to(production)],
        "sourceSha256": {
            str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [*java_files[-4:], Path(__file__).resolve()]
        },
        "validation": "JVM ownership/callback shims; not Android/JNI/rendering validation",
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(log, end="")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
