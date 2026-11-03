package com.example.video_player_app

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
// androidx.media:media still ships this type under the legacy package.
// The AndroidX name androidx.media.session.MediaSessionCompat does not exist.
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Hides audio_service's media notification without stopping playback.
 *
 * Publishing an idle processing state makes audio_service call stop(), which
 * destroys the service. The next show then has no instance to attach to.
 *
 * [suppress] is for "notification off AND headset controls off": it leaves
 * the foreground and deactivates the session so lock-screen controls go away.
 *
 * [conceal] is for "notification off BUT headset controls on". It removes the
 * shade notification and keeps the session active. Deactivating the session
 * made headphone play/pause stop arriving after the first press, and some
 * devices then paused the player when the activity resumed.
 *
 * [armShow] makes the next playing update look like a transition into
 * playback so audio_service recreates the foreground notification. The
 * playing flag is not cleared by [conceal], or the headset toggle would
 * freeze on "not playing".
 */
object MediaNotificationGate {
    private const val CHANNEL = "com.example.video_player_app/media_notification"

    // audio_service hard-codes this id. proguard-rules.pro preserves the
    // reflected AudioService fields below when Release minification is enabled.
    private const val NOTIFICATION_ID = 1124
    private const val MEDIA_CHANNEL_ID = "com.example.video_player_app.media_playback"

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "readAvailability" -> result.success(readAvailability(context))
                "openSystemSettings" -> result.success(openSystemSettings(context))
                "suppress" -> result.success(suppress(context.applicationContext))
                "conceal" -> result.success(conceal(context.applicationContext))
                "holdPlaying" -> result.success(holdPlaying())
                "armShow" -> result.success(armShow())
                else -> result.notImplemented()
            }
        }
    }

    private fun readAvailability(context: Context): Map<String, Any> {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(MEDIA_CHANNEL_ID)
        } else null
        // MediaSession notifications are exempt from POST_NOTIFICATIONS.
        // A disabled media channel is a separate, explicit user choice.
        return mapOf(
            "channelBlocked" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                channel?.importance == NotificationManager.IMPORTANCE_NONE),
            "ordinaryNotificationsAllowed" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
        )
    }

    private fun openSystemSettings(context: Context): Boolean {
        return try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                manager.getNotificationChannel(MEDIA_CHANNEL_ID) != null) {
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, MEDIA_CHANNEL_ID)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(android.net.Uri.parse("package:${context.packageName}"))
            }
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (error: Exception) {
            android.util.Log.w("MediaNotificationGate", "open notification settings failed", error)
            false
        }
    }

    fun suppress(context: Context): Boolean {
        return try {
            val service = audioServiceInstance() as? Service ?: return false
            // The next real "playing" update must look like a transition into
            // playback, or Android will not recreate the foreground notification.
            setBoolean(service, "playing", false)
            setBoolean(service, "notificationCreated", false)
            deactivateSession(service)
            removeForegroundNotification(context, service)
            true
        } catch (error: Throwable) {
            android.util.Log.w("MediaNotificationGate", "suppress failed", error)
            false
        }
    }

    fun conceal(context: Context): Boolean {
        return try {
            val service = audioServiceInstance() as? Service ?: return false
            // Leave `playing` alone. Forcing it false made every later
            // headset click look like "play" and become a no-op.
            setBoolean(service, "notificationCreated", false)
            activateSession(service)
            removeForegroundNotification(context, service)
            true
        } catch (error: Throwable) {
            android.util.Log.w("MediaNotificationGate", "conceal failed", error)
            false
        }
    }

    /**
     * Keeps audio_service from treating the next state as a fresh play.
     *
     * That transition calls startForeground and would either flash the
     * notification or throw if the app is already in the background.
     * The following setState still writes the real play/pause state.
     */
    fun holdPlaying(): Boolean {
        return try {
            val service = audioServiceInstance() as? Service ?: return false
            setBoolean(service, "playing", true)
            setBoolean(service, "notificationCreated", false)
            true
        } catch (error: Throwable) {
            android.util.Log.w("MediaNotificationGate", "holdPlaying failed", error)
            false
        }
    }

    fun armShow(): Boolean {
        return try {
            val service = audioServiceInstance() as? Service ?: return false
            setBoolean(service, "playing", false)
            setBoolean(service, "notificationCreated", false)
            true
        } catch (error: Throwable) {
            android.util.Log.w("MediaNotificationGate", "armShow failed", error)
            false
        }
    }

    private fun removeForegroundNotification(context: Context, service: Service) {
        ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(NOTIFICATION_ID)
    }

    private fun audioServiceInstance(): Any? {
        val clazz = Class.forName("com.ryanheise.audioservice.AudioService")
        val field = clazz.getDeclaredField("instance")
        field.isAccessible = true
        return field.get(null)
    }

    private fun setBoolean(target: Any, name: String, value: Boolean) {
        val field = target.javaClass.getDeclaredField(name)
        field.isAccessible = true
        field.setBoolean(target, value)
    }

    private fun session(service: Service): MediaSessionCompat? {
        val field = service.javaClass.getDeclaredField("mediaSession")
        field.isAccessible = true
        return field.get(service) as? MediaSessionCompat
    }

    private fun activateSession(service: Service) {
        val session = session(service) ?: return
        if (!session.isActive) {
            session.isActive = true
        }
    }

    private fun deactivateSession(service: Service) {
        val session = session(service) ?: return
        if (session.isActive) {
            session.isActive = false
        }
    }
}
