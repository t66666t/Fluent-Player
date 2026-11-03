import '../../services/app_storage_service.dart';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:workmanager/workmanager.dart';
import 'podcast_client.dart';
import 'podcast_controller.dart';
import 'podcast_media_store.dart';
import 'podcast_notifications.dart';
import 'podcast_store.dart';

const podcastBackgroundTask = 'com.example.video_player_app.podcasts.refresh';
@pragma('vm:entry-point')
void podcastBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    return AppStorageService.instance.withBackgroundLease(() async {
      final root = (await AppStorageService.instance.featureDirectory(
        'podcasts',
        marker: 'podcasts.sqlite',
      )).path;
      if (!Directory(root).existsSync()) return true;
      final store = PodcastStore.open(p.join(root, 'podcasts.sqlite'));
      final http = PodcastHttp();
      final media = PodcastMediaStore(
        root: Directory(p.join(root, 'media')),
        store: store,
        http: http,
      );
      final controller = PodcastController(
        store: store,
        client: PodcastClient(http: http),
        mediaStore: media,
      );
      try {
        if (!store.preferences.flag('backgroundRefresh') ||
            store.preferences.flag('pauseAllUpdates')) {
          return true;
        }
        await controller.refreshAll(budget: const Duration(seconds: 18));
        await PodcastNotifications().deliver(store);
        await controller.pumpDownloads(budget: const Duration(seconds: 5));
        return true;
      } catch (_) {
        return false;
      } finally {
        await controller.close();
        store.close();
      }
    });
  });
}

Future<void> configurePodcastBackground(String root, bool enabled) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  await Workmanager().initialize(podcastBackgroundDispatcher);
  if (!enabled) {
    await Workmanager().cancelByUniqueName(podcastBackgroundTask);
    return;
  }
  await Workmanager().registerPeriodicTask(
    podcastBackgroundTask,
    podcastBackgroundTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    inputData: {'root': root, 'rootId': 'feature:podcasts', 'version': 2},
  );
}
