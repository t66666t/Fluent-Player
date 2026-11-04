/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Locale;

import io.flutter.view.TextureRegistry;

public class VideoOutputManager {
    private static final String TAG = "VideoOutputManager";

    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final TextureRegistry textureRegistryReference;
    private final Object lock = new Object();
    private boolean disposed;

    VideoOutputManager(TextureRegistry textureRegistryReference) {
        this.textureRegistryReference = textureRegistryReference;
    }

    public void create(long handle, TextureUpdateCallback textureUpdateCallback) {
        synchronized (lock) {
            if (disposed) return;
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.create: %d", handle));
            if (!videoOutputs.containsKey(handle)) {
                final VideoOutput videoOutput = new VideoOutput(textureRegistryReference, textureUpdateCallback);
                videoOutputs.put(handle, videoOutput);
            }
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.dispose: %d", handle));
            // Revoke ownership before disposal can publish a callback.
            final VideoOutput output = videoOutputs.remove(handle);
            if (output != null) disposeOutput(output);
        }
    }

    public void setSurfaceSize(long handle, int width, int height) {
        synchronized (lock) {
            if (disposed) return;
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceSize: %d %d %d", handle, width, height));
            if (videoOutputs.containsKey(handle)) {
                videoOutputs.get(handle).setSurfaceSize(width, height);
            }
        }
    }

    // Engine teardown is also an ownership boundary when Dart has not had an
    // opportunity to dispose every player. No application method is added.
    void disposeAll() {
        synchronized (lock) {
            if (disposed) return;
            disposed = true;
            final ArrayList<VideoOutput> outputs = new ArrayList<>(videoOutputs.values());
            videoOutputs.clear();
            for (VideoOutput output : outputs) disposeOutput(output);
        }
    }

    private static void disposeOutput(VideoOutput output) {
        try {
            output.dispose();
        } catch (Throwable e) {
            // One failed native output must not skip the remaining owners.
            Log.e(TAG, "dispose", e);
        }
    }
}
