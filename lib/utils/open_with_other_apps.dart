import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reveal_in_file_manager.dart';

/// Same channel on Android and iOS. Desktop never calls it.
const MethodChannel openWithOtherAppsChannel = MethodChannel(
  'com.example.video_player_app/open_with',
);

enum ExternalOpenStrategy {
  /// Explorer / Finder / xdg-open select the file without reading it.
  revealInFileManager,

  /// Hand the existing file to the system "open with" sheet.
  openFileDirectly,
}

class ExternalOpenPlan {
  const ExternalOpenPlan({required this.strategy, required this.path});

  final ExternalOpenStrategy strategy;

  /// Always the file the user already exported. Never a staged copy.
  final String path;
}

/// Chooses how "用其他应用打开" should run.
///
/// Phones must not open the parent folder and must not copy the video into
/// another directory first. A folder intent has no extension, so Android
/// treats it as `*/*` and grants read access to every installed app before
/// the sheet can appear. Copying a finished video that already lives outside
/// the app sandbox has the same effect: the sheet waits on the copy.
ExternalOpenPlan planExternalOpen({
  required String path,
  required bool isAndroid,
  required bool isIOS,
}) {
  final ExternalOpenStrategy strategy = (isAndroid || isIOS)
      ? ExternalOpenStrategy.openFileDirectly
      : ExternalOpenStrategy.revealInFileManager;
  return ExternalOpenPlan(strategy: strategy, path: path);
}

/// Opens [path] with another app, or reveals it on desktop.
///
/// Returns false when the platform cannot present a chooser. The caller
/// shows the error; this function does not copy or rewrite [path].
Future<bool> openWithOtherApps(String path) async {
  if (kIsWeb) return false;
  final ExternalOpenPlan plan = planExternalOpen(
    path: path,
    isAndroid: Platform.isAndroid,
    isIOS: Platform.isIOS,
  );
  if (plan.strategy == ExternalOpenStrategy.revealInFileManager) {
    return revealInFileManager(plan.path);
  }
  try {
    final bool? opened = await openWithOtherAppsChannel.invokeMethod<bool>(
      'openFile',
      <String, String>{'path': plan.path},
    );
    return opened ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
