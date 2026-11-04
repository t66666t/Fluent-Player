import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

const podcastBackgroundTask = 'com.example.video_player_app.podcasts.refresh';
@pragma('vm:entry-point')
void podcastBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    // Previously scheduled OS callbacks can outlive the feature's removal.
    // Acknowledge them without opening stores, fetching feeds or resuming media.
    return true;
  });
}

Future<void> configurePodcastBackground(String root, bool enabled) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    // This name is scoped to this application's WorkManager/BGTaskScheduler.
    // Never register new work, including when an old caller passes enabled.
    await Workmanager().cancelByUniqueName(podcastBackgroundTask);
  } catch (_) {
    // Unsupported or unavailable plugins must not reactivate the retired job.
  }
}
