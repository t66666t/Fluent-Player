/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.Locale;
import java.util.Objects;

import io.flutter.view.TextureRegistry;

public class VideoOutput implements TextureRegistry.SurfaceProducer.Callback {
    private static final String TAG = "VideoOutput";
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final Handler handler = new Handler(Looper.getMainLooper());

    // JNI handle values can be reused after deletion. Ownership belongs to
    // this acquisition, rather than a process-wide history of numeric handles.
    private static final class SurfaceReference {
        final long value;
        private boolean retired;
        private boolean deleted;

        SurfaceReference(long value) {
            this.value = value;
        }

        synchronized void retire() {
            if (retired) return;
            retired = true;
            // Preserve the existing grace while the asynchronous Dart/native
            // output handoff stops using the old Surface reference.
            handler.postDelayed(this::delete, 5000);
        }

        private synchronized void delete() {
            if (deleted) return;
            deleted = true;
            deleteGlobalObjectRef(value);
        }
    }

    static {
        try {
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }
    }

    private long id = 0;
    private long wid = 0;
    private SurfaceReference currentReference;
    private boolean outputNotified;
    private boolean disposed;
    private long outputRevision;

    private final TextureUpdateCallback textureUpdateCallback;

    private final TextureRegistry.SurfaceProducer surfaceProducer;

    private final Object lock = new Object();

    VideoOutput(TextureRegistry textureRegistryReference, TextureUpdateCallback textureUpdateCallback) {
        this.textureUpdateCallback = textureUpdateCallback;

        surfaceProducer = textureRegistryReference.createSurfaceProducer();
        surfaceProducer.setCallback(this);
    }

    public void dispose() {
        synchronized (lock) {
            if (disposed) return;
            disposed = true;
            clearOutput();
            try {
                // SurfaceProducer owns its Surface. Asking for one here can
                // create a new reader during teardown, or release it twice.
                surfaceProducer.release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose", e);
            }
        }
    }

    public void setSurfaceSize(int width, int height) {
        setSurfaceSize(width, height, false);
    }

    private void setSurfaceSize(int width, int height, boolean force) {
        synchronized (lock) {
            if (disposed) return;
            try {
                if (!force && surfaceProducer.getWidth() == width && surfaceProducer.getHeight() == height) {
                    return;
                }
                surfaceProducer.setSize(width, height);
                onSurfaceAvailable();
            } catch (Throwable e) {
                Log.e(TAG, "setSurfaceSize", e);
            }
        }
    }

    @Override
    public void onSurfaceAvailable() {
        synchronized (lock) {
            if (disposed) return;
            Log.i(TAG, "onSurfaceAvailable");
            final long nextId;
            final long nextWid;
            final int width;
            final int height;
            try {
                nextId = surfaceProducer.id();
                width = surfaceProducer.getWidth();
                height = surfaceProducer.getHeight();
                nextWid = newGlobalObjectRef(surfaceProducer.getSurface());
            } catch (Throwable e) {
                // Nothing was acquired, so the previous binding still owns
                // its reference until a later available/cleanup callback.
                Log.e(TAG, "onSurfaceAvailable", e);
                return;
            }
            final SurfaceReference previous = currentReference;
            final long previousId = id;
            final long previousWid = wid;
            final boolean previouslyNotified = outputNotified;
            final SurfaceReference next = nextWid == 0 ? null : new SurfaceReference(nextWid);
            final long previousRevision = outputRevision;
            final long revision = ++outputRevision;
            currentReference = next;
            id = nextId;
            wid = nextWid;
            outputNotified = true;
            try {
                // A failed NewGlobalRef still publishes wid=0 as before.
                textureUpdateCallback.onTextureUpdate(id, wid, width, height);
            } catch (Throwable e) {
                // Failed publication must not orphan either acquisition or
                // roll back over a reentrant cleanup/dispose/newer binding.
                if (!disposed && outputRevision == revision) {
                    currentReference = previous;
                    id = previousId;
                    wid = previousWid;
                    outputNotified = previouslyNotified;
                    // Restore the enclosing transaction's token too: nested
                    // failed publications must still be able to roll back.
                    outputRevision = previousRevision;
                    retire(next);
                } else {
                    retire(previous);
                }
                Log.e(TAG, "onSurfaceAvailable callback", e);
                return;
            }
            retire(previous);
        }
    }

    @Override
    public void onSurfaceCleanup() {
        synchronized (lock) {
            Log.i(TAG, "onSurfaceCleanup");
            clearOutput();
        }
    }

    private void clearOutput() {
        final SurfaceReference previous = currentReference;
        final boolean notify = outputNotified || previous != null;
        currentReference = null;
        wid = 0;
        outputNotified = false;
        ++outputRevision;
        if (!notify) return;
        try {
            textureUpdateCallback.onTextureUpdate(id, 0, surfaceProducer.getWidth(), surfaceProducer.getHeight());
        } catch (Throwable e) {
            Log.e(TAG, "onSurfaceCleanup callback", e);
        } finally {
            retire(previous);
        }
    }

    private static void retire(SurfaceReference reference) {
        if (reference != null) reference.retire();
    }

    private static long newGlobalObjectRef(Object object) {
        Log.i(TAG, String.format(Locale.ENGLISH, "newGlobalRef: object = %s", object));
        try {
            return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long ref) {
        Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d", ref));
        try {
            deleteGlobalObjectRef.invoke(null, ref);
        } catch (Throwable e) {
            Log.e(TAG, "deleteGlobalObjectRef", e);
        }
    }
}
