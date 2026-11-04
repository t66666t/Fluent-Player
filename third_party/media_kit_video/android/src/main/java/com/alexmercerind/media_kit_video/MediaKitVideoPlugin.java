/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import androidx.annotation.NonNull;

import java.util.HashMap;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * MediaKitVideoPlugin
 */
public class MediaKitVideoPlugin implements FlutterPlugin, MethodCallHandler {
    private MethodChannel channel;
    private VideoOutputManager videoOutputManager;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "com.alexmercerind/media_kit_video");
        channel.setMethodCallHandler(this);

        videoOutputManager = new VideoOutputManager(flutterPluginBinding.getTextureRegistry());

    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "VideoOutputManager.Create": {
                final long handle = Long.parseLong(call.argument("handle"));
                final VideoOutputManager owner = videoOutputManager;
                final MethodChannel outputChannel = channel;
                if (owner != null && outputChannel != null) {
                    owner.create(handle, (id, wid, width, height) -> {
                        // Old output callbacks cannot reach a reattached engine.
                        if (channel != outputChannel || videoOutputManager != owner) return;
                        outputChannel.invokeMethod("VideoOutput.Resize", new HashMap<String, Object>() {{
                            put("handle", handle);
                            put("id", id);
                            put("wid", wid);
                            put("rect", new HashMap<String, Object>() {{
                                put("left", 0);
                                put("top", 0);
                                put("width", width);
                                put("height", height);
                            }});
                        }});
                    });
                }
                result.success(null);
                break;
            }
            case "VideoOutputManager.SetSurfaceSize": {
                final long handle = Long.parseLong(call.argument("handle"));
                final int width = Integer.parseInt(call.argument("width"));
                final int height = Integer.parseInt(call.argument("height"));
                final VideoOutputManager owner = videoOutputManager;
                if (owner != null) owner.setSurfaceSize(handle, width, height);
                result.success(null);
                break;
            }
            case "VideoOutputManager.Dispose": {
                final long handle = Long.parseLong(call.argument("handle"));
                final VideoOutputManager owner = videoOutputManager;
                if (owner != null) owner.dispose(handle);
                result.success(null);
                break;
            }
            case "Utils.IsEmulator": {
                result.success(Utils.isEmulator());
                break;
            }
            default: {
                result.notImplemented();
                break;
            }
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        final MethodChannel previousChannel = channel;
        final VideoOutputManager previousOwner = videoOutputManager;
        try {
            if (previousChannel != null) previousChannel.setMethodCallHandler(null);
        } finally {
            try {
                // Keep the old outbound channel available for the final wid=0
                // notifications, then revoke it even if teardown fails.
                if (previousOwner != null) previousOwner.disposeAll();
            } finally {
                if (videoOutputManager == previousOwner) videoOutputManager = null;
                if (channel == previousChannel) channel = null;
            }
        }
    }
}
