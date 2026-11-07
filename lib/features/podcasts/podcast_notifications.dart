import 'package:video_player_app/utils/app_branding.dart';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'podcast_store.dart';

class PodcastNotifications {
  final plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void> initialize({void Function(String)? onOpen}) async {
    if (_ready) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: '查看播客'),
        windows: WindowsInitializationSettings(
          appName: kAppDisplayName,
          appUserModelId: '$kApplicationId.podcasts',
          guid: '44d07412-f8b2-4b6b-a864-82b965b8f2fd',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload != null) onOpen?.call(response.payload!);
      },
    );
    _ready = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      onOpen?.call(payload);
    }
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (Platform.isAndroid) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          true;
    }
    if (Platform.isIOS) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    if (Platform.isMacOS) {
      return await plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return true;
  }

  Future<void> deliver(PodcastStore store) async {
    if (!_ready) await initialize();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final notice in store.list('notice')) {
      groups.putIfAbsent(notice['channelId'], () => []).add(notice);
    }
    for (final entry in groups.entries) {
      final settings = store.effective(entry.key);
      if (!settings.flag('notify') ||
          store.channel(entry.key)?.active != true ||
          store.preferences.flag('pauseAllUpdates')) {
        for (final notice in entry.value) {
          store.remove('notice', notice['episodeId']);
        }
        continue;
      }
      if (settings.quietAt(DateTime.now())) continue;
      final channel = store.channel(entry.key);
      if (channel == null || !channel.active) continue;
      final lease = 'notify:${entry.key}',
          owner =
              '${DateTime.now().microsecondsSinceEpoch}:${identityHashCode(this)}';
      final acquired = store.transaction(() {
        final old = store.read('lease', lease);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (old != null && (old['until'] as int) > now) return false;
        store.write('lease', lease, {'owner': owner, 'until': now + 60000});
        return true;
      });
      if (!acquired) continue;
      try {
        final sound = settings.flag('notificationSound');
        await plugin.show(
          id: entry.key.codeUnits.fold<int>(
            0,
            (n, c) => (n * 31 + c) & 0x7fffffff,
          ),
          title: '${channel.title} · ${entry.value.length} 集更新',
          body: entry.value.take(3).map((n) => n['title']).join(' · '),
          payload: entry.key,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              sound ? 'podcast_updates_sound' : 'podcast_updates_quiet',
              sound ? '播客更新（声音）' : '播客更新',
              importance: Importance.low,
              priority: Priority.low,
              playSound: sound,
              enableVibration: false,
              onlyAlertOnce: true,
            ),
            iOS: DarwinNotificationDetails(
              presentSound: sound,
              presentBanner: true,
            ),
            macOS: DarwinNotificationDetails(presentSound: sound),
            linux: const LinuxNotificationDetails(),
            windows: const WindowsNotificationDetails(),
          ),
        );
        store.transaction(() {
          for (final notice in entry.value) {
            store.write('notified', notice['episodeId'], {
              'at': DateTime.now().millisecondsSinceEpoch,
            });
            store.remove('notice', notice['episodeId']);
          }
        });
      } finally {
        if (store.read('lease', lease)?['owner'] == owner) {
          store.remove('lease', lease);
        }
      }
    }
  }
}
