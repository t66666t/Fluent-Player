import Flutter
import GameController
import Darwin
import os
import MediaPlayer
import UIKit
import Darwin
import UserNotifications
import workmanager_apple

private final class HardwareKeyboardPresenceBridge {
  private var channel: FlutterMethodChannel?
  private var observers: [NSObjectProtocol] = []
  private var lastConnected: Bool?

  func register(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.example.video_player_app/keyboard_presence", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "isKeyboardConnected" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let connected = GCKeyboard.coalesced != nil
      self?.lastConnected = connected
      result(connected)
    }
    for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        // Read after GameController finishes the change. Disconnecting one of
        // several keyboards must keep hints available for the remaining ones.
        DispatchQueue.main.async { [weak self] in self?.publish() }
      })
    }
  }

  private func publish() {
    let connected = GCKeyboard.coalesced != nil
    guard connected != lastConnected else { return }
    lastConnected = connected
    channel?.invokeMethod("keyboardChanged", arguments: connected)
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}

private final class ModelResourceBridge: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var warnedAt: Date?
  func register(_ messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "com.example.video_player_app/model_resources/events", binaryMessenger: messenger).setStreamHandler(self)
    FlutterMethodChannel(name: "com.example.video_player_app/model_resources", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "start": self.start(); result(nil)
      case "stop": self.stop(); result(nil)
      case "snapshot": result(self.snapshot())
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func start() {
    guard observers.isEmpty else { return }
    for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sink?(["changed": true]) })
    }
    observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
      self?.warnedAt = Date(); self?.sink?(["memoryPressure": "critical"])
    })
  }
  private func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll(); warnedAt = nil
  }
  private func snapshot() -> [String: Any] {
    let process = ProcessInfo.processInfo
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    let thermal: String
    switch process.thermalState {
    case .nominal: thermal = "normal"
    case .fair: thermal = "warm"
    case .serious: thermal = "moderate"
    case .critical: thermal = "severe"
    @unknown default: thermal = "unknown"
    }
    var data: [String: Any] = ["processors": process.activeProcessorCount,
      "memoryBytes": process.physicalMemory, "availableMemoryBytes": os_proc_available_memory(),
      "memoryScope": "application", "thermal": thermal, "thermalSupported": true,
      "powerSaving": process.isLowPowerModeEnabled,
      "memoryPressure": warnedAt.map { Date().timeIntervalSince($0) < 10 } == true ? "critical" : "normal",
      "workerBytes": 0, "workerMemoryComplete": true,
      "environment": process.operatingSystemVersionString]
    if status == KERN_SUCCESS { data["processBytes"] = vm.phys_footprint }
    return data
  }
  deinit { stop() }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private let imeChannelName = "com.example.video_player_app/ime_gate"
  private let modelDownloads = ModelDownloadBridge()
  private let mediaCacheDownloads = MediaCacheDownloadBridge()
  private let asrAcceleration = AsrAccelerationBridge()
  private let qwenAsr = QwenAsrBridge()
  private let cohereAsr = QwenAsrBridge(component: "cohere_asr", symbolPrefix: "fluent_cohere", label: "Cohere")
  private let parakeetJapanese = QwenAsrBridge(component: "parakeet_ja", symbolPrefix: "fluent_parakeet_ja", label: "Parakeet")
  private let modelResources = ModelResourceBridge()
  private let hardwareKeyboardPresence = HardwareKeyboardPresenceBridge()
  private let shareChannelName = "com.example.video_player_app/share_intent"
  private let shareEventChannelName = "com.example.video_player_app/share_intent_events"
  private let ytDlpChannelName = "com.example.video_player_app/yt_dlp"
  private let mediaNotificationChannelName =
    "com.example.video_player_app/media_notification"
  private let ytDlpEventChannelName = "com.example.video_player_app/yt_dlp_events"
  private var pendingSharedItems: [Any] = []
  private var shareEventSink: FlutterEventSink?
  /// Kept alive while the Open In menu is visible. Releasing it dismisses the menu.
  private var openInMenuController: UIDocumentInteractionController?
  fileprivate var ytDlpEventSink: FlutterEventSink?
  private let mediaExtensions: Set<String> = [
    ".mp4", ".mov", ".avi", ".mkv", ".flv", ".webm", ".wmv", ".3gp", ".m4v", ".ts",
    ".rmvb", ".mpg", ".mpeg", ".f4v", ".m2ts", ".mts", ".vob", ".ogv", ".divx",
    ".mp3", ".m4a", ".wav", ".flac", ".ogg", ".aac", ".wma", ".opus", ".m4b", ".aiff",
  ]
  private let archiveSuffixes: [String] = [
    ".zip", ".tar", ".tgz", ".tar.gz", ".tbz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz",
  ]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: (Bundle.main.bundleIdentifier ?? "cn.teezy.fluentplayer.standard") + ".podcasts.refresh",
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    UNUserNotificationCenter.current().delegate = self
    if let controller = window?.rootViewController as? FlutterViewController {
      hardwareKeyboardPresence.register(controller.binaryMessenger)
      registerClipboardRevision(controller: controller)
      registerImeGateChannel(controller: controller)
      modelDownloads.register(controller.binaryMessenger)
      mediaCacheDownloads.register(controller.binaryMessenger)
      asrAcceleration.register(controller.binaryMessenger)
      qwenAsr.register(controller.binaryMessenger)
      cohereAsr.register(controller.binaryMessenger)
      parakeetJapanese.register(controller.binaryMessenger)
      modelResources.register(controller.binaryMessenger)
      registerShareChannels(controller: controller)
      registerYtDlpChannels(controller: controller)
      registerMediaNotificationChannel(controller: controller)
      registerProgressSyncNetworkChannel(controller: controller)
      registerOpenWithChannel(controller: controller)
      registerStoragePathsChannel(controller: controller)
    }
    application.beginReceivingRemoteControlEvents()
    NSLog("AppDelegate: iOS remote control events enabled for control center")
    if let launchUrl = launchOptions?[.url] as? URL {
      _ = handleIncomingUrls([launchUrl])
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleIncomingUrls([url]) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(_ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void) {
    if identifier.hasPrefix(ModelDownloadBridge.prefix) {
      modelDownloads.handleEvents(identifier: identifier, completion: completionHandler)
    } else if identifier.hasPrefix(MediaCacheDownloadBridge.prefix) {
      mediaCacheDownloads.handleEvents(identifier: identifier, completion: completionHandler)
    } else {
      super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    shareEventSink = events
    if !pendingSharedItems.isEmpty {
      events(pendingSharedItems)
      pendingSharedItems.removeAll()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    shareEventSink = nil
    return nil
  }

  /// Clears Control Center / lock screen without stopping playback.
  /// audio_service keeps its command center, so the next real state update
  /// turns the controls back on.
  private func registerClipboardRevision(controller: FlutterViewController) {
    var bytes = [CChar](repeating: 0, count: 128)
    var length = bytes.count
    let hasBootID = sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0
    let bootID = hasBootID ? String(cString: bytes) : ""
    let persistent = !bootID.isEmpty
    let scope = persistent ? bootID : UUID().uuidString
    let channel = FlutterMethodChannel(
      name: "com.example.video_player_app/clipboard_revision",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "getRevision" else {
        result(FlutterMethodNotImplemented); return
      }
      result([
        "token": "ios/\(scope)/\(UIPasteboard.general.changeCount)",
        "persistent": persistent,
      ])
    }
  }

  private func registerStoragePathsChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "com.example.video_player_app/storage_paths",
      binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup",
        let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterMethodNotImplemented); return
      }
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let roots = [support.standardizedFileURL.path, documents.standardizedFileURL.path]
      let suffix = Array(url.pathComponents.suffix(3))
      let modelDirectory = url.lastPathComponent == "local_models"
      let downloadDirectory = suffix.count == 3 && suffix[0] == "downloads"
        && ["web", "douyin", "bilibili", "yt_dlp"].contains(suffix[1])
        && ["files", "tasks"].contains(suffix[2])
      guard roots.contains(where: { url.path.hasPrefix($0 + "/") }),
        modelDirectory || downloadDirectory else {
        result(FlutterError(code: "INVALID_PATH", message: "Expected app support download directory", details: nil)); return
      }
      do {
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values); result(nil)
      } catch { result(FlutterError(code: "BACKUP_ATTRIBUTE", message: error.localizedDescription, details: nil)) }
    }
  }

  private func registerMediaNotificationChannel(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: mediaNotificationChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { call, result in
      if call.method == "suppress" {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
          center.playCommand,
          center.pauseCommand,
          center.togglePlayPauseCommand,
          center.stopCommand,
          center.nextTrackCommand,
          center.previousTrackCommand,
          center.changePlaybackPositionCommand,
          center.skipForwardCommand,
          center.skipBackwardCommand,
        ]
        for command in commands {
          command.isEnabled = false
        }
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerProgressSyncNetworkChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.example.video_player_app/progress_sync_network",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "availableBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String, !path.isEmpty
      else {
        result(nil)
        return
      }
      do {
        let values = try URL(fileURLWithPath: path, isDirectory: true).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        result(values.volumeAvailableCapacityForImportantUsage.map { max(0, $0) })
      } catch {
        result(nil)
      }
    }
  }

  /// Presents Open In for the file that was already written.
  ///
  /// Quick Look (`presentPreview`) reads the video to build a preview and only
  /// reports completion after the user dismisses it, so a large export looks
  /// stuck. Open In lists other apps from the file extension and returns as
  /// soon as the menu is on screen.
  private func registerOpenWithChannel(controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.example.video_player_app/open_with",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self, weak controller] call, result in
      guard call.method == "openFile" || call.method == "shareFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self, let controller = controller else {
        result(false)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        !path.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARGS", message: "missing path", details: nil))
        return
      }
      if call.method == "shareFile" {
        self.shareSourceMediaFile(path: path, args: args, controller: controller, result: result)
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(false)
        return
      }
      let presenter = self.frontViewController(from: controller)
      let fileUrl = URL(fileURLWithPath: path)
      let document = UIDocumentInteractionController(url: fileUrl)
      self.openInMenuController = document
      let bounds = presenter.view.bounds
      let anchor = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
      let presented = document.presentOpenInMenu(from: anchor, in: presenter.view, animated: true)
      if presented {
        result(true)
        return
      }
      self.openInMenuController = nil
      let activity = UIActivityViewController(activityItems: [fileUrl], applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = anchor
        popover.permittedArrowDirections = []
      }
      presenter.present(activity, animated: true, completion: nil)
      result(true)
    }
  }

  /// UIActivityViewController receives the original file URL. No Data(contentsOf:),
  /// temporary export, or media preview must precede presenting the share sheet.
  private func shareSourceMediaFile(
    path: String,
    args: [String: Any],
    controller: FlutterViewController,
    result: @escaping FlutterResult
  ) {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      result(FlutterError(code: "INVALID_ARGS", message: "invalid source path", details: nil))
      return
    }
    let fileUrl = URL(fileURLWithPath: path, isDirectory: false)
    let scoped = fileUrl.startAccessingSecurityScopedResource()
    DispatchQueue.global(qos: .userInitiated).async { [weak self, weak controller] in
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      let readable = FileManager.default.isReadableFile(atPath: path)
      DispatchQueue.main.async {
        guard exists, !isDirectory.boolValue, readable,
          let self = self, let controller = controller
        else {
          if scoped { fileUrl.stopAccessingSecurityScopedResource() }
          result(FlutterError(
            code: exists && !isDirectory.boolValue ? "SOURCE_PERMISSION_DENIED" : "SOURCE_MISSING",
            message: "source file is unavailable", details: nil
          ))
          return
        }
        let presenter = self.frontViewController(from: controller)
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else {
          if scoped { fileUrl.stopAccessingSecurityScopedResource() }
          result(false)
          return
        }
        let activity = UIActivityViewController(activityItems: [fileUrl], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
          // External provider access stays alive until sharing or cancellation
          // finishes. Dismissing the sheet is not reported as an error.
          if scoped { fileUrl.stopAccessingSecurityScopedResource() }
        }
        if let popover = activity.popoverPresentationController {
          let bounds = presenter.view.bounds
          var anchor = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
          if let x = args["originX"] as? Double, let y = args["originY"] as? Double,
            let width = args["originWidth"] as? Double, let height = args["originHeight"] as? Double,
            x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0
          {
            let converted = controller.view.convert(
              CGRect(x: x, y: y, width: width, height: height), to: presenter.view
            ).intersection(bounds)
            if !converted.isNull, !converted.isEmpty { anchor = converted }
          }
          popover.sourceView = presenter.view
          popover.sourceRect = anchor
          popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true) { result(true) }
      }
    }
  }

  private func frontViewController(from controller: UIViewController) -> UIViewController {
    var current = controller
    while let presented = current.presentedViewController {
      current = presented
    }
    return current
  }

  private func registerImeGateChannel(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: imeChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak controller] call, result in
      if call.method == "setTextInputActive" {
        let active = (call.arguments as? Bool) ?? false
        if !active {
          controller?.view.endEditing(true)
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerShareChannels(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: shareChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result([])
        return
      }
      if call.method == "getInitialSharedMedia" {
        result(self.pendingSharedItems)
        self.pendingSharedItems.removeAll()
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: shareEventChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(self)
  }

  private func registerYtDlpChannels(controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: ytDlpChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "getYtDlpBinaryStatus":
        result(self.getYtDlpBinaryStatus())
      case "importYoutubeCookies":
        let args = call.arguments as? [String: Any]
        let filePath = args?["filePath"] as? String
        result(self.importYoutubeCookies(filePath))
      case "saveYoutubeSessionConfig":
        let args = call.arguments as? [String: Any]
        self.saveYoutubeSessionConfig(args?["config"])
        result(true)
      case "loadYoutubeSessionConfig":
        result(self.loadYoutubeSessionConfig())
      case "resolveYoutubeMeta":
        result(
          FlutterError(
            code: "YT_DLP_UNSUPPORTED",
            message: "yt-dlp process execution is not supported on iOS",
            details: nil
          )
        )
      case "startYoutubeDownload":
        result(false)
      case "pauseYoutubeDownload":
        result(false)
      case "cancelYoutubeDownload":
        result(false)
      case "removeYoutubeTask":
        result(false)
      case "getYoutubeTaskStatus":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: ytDlpEventChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(_YtDlpStreamProxy(owner: self))
  }

  private func handleIncomingUrls(_ urls: [URL]) -> Bool {
    let supportedUrls = urls.filter {
      isFluentPackPath($0.path) || isMediaPath($0.path) || isArchivePath($0.path)
    }
    if supportedUrls.isEmpty {
      return false
    }

    // File-provider URLs may point to very large archives. Copying them in
    // application(_:open:) blocks iOS's main thread and can make the app look
    // frozen or be terminated by the watchdog, so materialize them off-main.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let items = supportedUrls.compactMap { self.makeIncomingItem($0) }
      guard !items.isEmpty else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let sink = self.shareEventSink {
          sink(items)
        } else {
          self.pendingSharedItems.append(contentsOf: items)
        }
      }
    }
    return true
  }

  private func isMediaPath(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ext.isEmpty {
      return false
    }
    return mediaExtensions.contains(".\(ext)")
  }

  private func isArchivePath(_ path: String) -> Bool {
    let lower = path.lowercased()
    return archiveSuffixes.contains { lower.hasSuffix($0) }
  }

  private func isFluentPackPath(_ path: String) -> Bool {
    return path.lowercased().hasSuffix(".fluentpack")
  }

  private func makeIncomingItem(_ url: URL) -> Any? {
    let isFluentPack = isFluentPackPath(url.path)
    let isArchive = !isFluentPack && isArchivePath(url.path)
    guard isFluentPack || isArchive || isMediaPath(url.path) else { return nil }
    let cacheDirectoryName = isFluentPack
      ? "picked_fluentpacks"
      : (isArchive ? "picked_archives" : "incoming_media")
    guard let path = copyIncomingFileToCache(url, directoryName: cacheDirectoryName) else {
      return nil
    }
    if isFluentPack {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      return [
        "kind": "fluentpack",
        "displayName": url.lastPathComponent,
        "sizeBytes": size,
        "path": path,
        "ownedTemporaryCopy": true,
      ] as [String: Any]
    }
    if !isArchive {
      return path
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    return [
      "kind": "archive",
      "displayName": url.lastPathComponent,
      "sizeBytes": size,
      "path": path,
    ] as [String: Any]
  }

  private func copyIncomingFileToCache(_ url: URL, directoryName: String) -> String? {
    guard url.isFileURL else { return nil }
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let fileManager = FileManager.default
    // Match path_provider's temporary directory so Dart can promote incoming
    // media before the system purges this provider copy. Older tmp copies are
    // still recognized by the shared Dart cache-root resolver.
    guard let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return nil
    }
    let incomingDir = cacheRoot.appendingPathComponent(directoryName, isDirectory: true)
    if !fileManager.fileExists(atPath: incomingDir.path) {
      do {
        try fileManager.createDirectory(at: incomingDir, withIntermediateDirectories: true)
      } catch {
        return nil
      }
    }
    let originalName = url.lastPathComponent
    let fallbackName = "incoming_\(Int(Date().timeIntervalSince1970 * 1000))"
    let safeName = originalName.isEmpty ? fallbackName : originalName
    let targetUrl = incomingDir.appendingPathComponent("\(UUID().uuidString)_\(safeName)")
    // A File Provider may need to download or coordinate the source first.
    // Read under its security scope without modifying the external original.
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableUrl in
      do {
        try fileManager.copyItem(at: readableUrl, to: targetUrl)
      } catch {
        copyError = error
      }
    }
    if coordinationError != nil || copyError != nil {
      try? fileManager.removeItem(at: targetUrl)
      return nil
    }
    return targetUrl.path
  }

  private func getYtDlpBinaryStatus() -> [String: Any?] {
    let fileManager = FileManager.default
    let ytDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("yt_dlp", isDirectory: true)
    let ytDlpPath = ytDir?.appendingPathComponent("yt-dlp").path
    let ffmpegPath = ytDir?.appendingPathComponent("ffmpeg").path
    let ytReady = ytDlpPath != nil && fileManager.fileExists(atPath: ytDlpPath!)
    let ffmpegReady = ffmpegPath != nil && fileManager.fileExists(atPath: ffmpegPath!)
    return [
      "ytDlpReady": ytReady,
      "ffmpegReady": ffmpegReady,
      "ytDlpVersion": nil,
      "ffmpegVersion": nil,
      "ytDlpPath": ytReady ? ytDlpPath : nil,
      "ffmpegPath": ffmpegReady ? ffmpegPath : nil,
    ]
  }

  private func importYoutubeCookies(_ filePath: String?) -> String? {
    guard let filePath = filePath, !filePath.isEmpty else { return nil }
    let sourceUrl = URL(fileURLWithPath: filePath)
    let fileManager = FileManager.default
    guard let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let targetDir = baseDir.appendingPathComponent("yt_dlp/cookies", isDirectory: true)
    do {
      if !fileManager.fileExists(atPath: targetDir.path) {
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
      }
      let targetUrl = targetDir.appendingPathComponent("cookies.txt")
      if fileManager.fileExists(atPath: targetUrl.path) {
        try fileManager.removeItem(at: targetUrl)
      }
      try fileManager.copyItem(at: sourceUrl, to: targetUrl)
      return targetUrl.path
    } catch {
      return nil
    }
  }

  private func saveYoutubeSessionConfig(_ config: Any?) {
    guard let config else { return }
    guard JSONSerialization.isValidJSONObject(config) else { return }
    do {
      let data = try JSONSerialization.data(withJSONObject: config, options: [])
      UserDefaults.standard.set(data, forKey: "yt_dlp_session_config_raw")
    } catch {
    }
  }

  private func loadYoutubeSessionConfig() -> [String: Any]? {
    guard let data = UserDefaults.standard.data(forKey: "yt_dlp_session_config_raw") else {
      return nil
    }
    do {
      return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    } catch {
      return nil
    }
  }
}

// CoreML stays disabled until a combination is in the signed validation list.
// This bridge uses the app's existing ORT symbols; it never downloads native code.
private final class QwenAsrBridge {
  private let component: String
  private let symbolPrefix: String
  private let label: String
  init(component: String = "qwen_asr", symbolPrefix: String = "fluent_qwen", label: String = "Qwen") {
    self.component = component
    self.symbolPrefix = symbolPrefix
    self.label = label
  }
  private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
  private typealias Request = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
  private typealias Control = @convention(c) (UnsafeMutableRawPointer?) -> Void
  private final class Session {
    let handle: UnsafeMutableRawPointer
    let queue: DispatchQueue
    init(_ handle: UnsafeMutableRawPointer, _ owner: String) {
      self.handle = handle
      self.queue = DispatchQueue(label: "fluent.qwen.\(owner)", qos: .userInitiated)
    }
  }
  private var sessions: [String: Session] = [:]
  private var channel: FlutterMethodChannel?
  private var create: Create?
  private var request: Request?
  private var cancel: Control?
  private var destroy: Control?

  func register(_ messenger: FlutterBinaryMessenger) {
    let label = self.label
    channel = FlutterMethodChannel(name: "com.example.video_player_app/\(component)", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any],
            let owner = args["owner"] as? String, !owner.isEmpty else {
        result(["ok": false, "error": "无效的 \(label) 音频所有者"]); return
      }
      if call.method == "close" {
        if let session = self.sessions.removeValue(forKey: owner) {
          self.cancel?(session.handle)
          let release = self.destroy
          session.queue.async {
            release?(session.handle)
            DispatchQueue.main.async { result(nil) }
          }
          return
        }
        result(nil); return
      }
      guard call.method == "request" else { result(FlutterMethodNotImplemented); return }
      if args["op"] as? String == "open" {
        if self.create == nil, let library = dlopen(nil, RTLD_NOW),
           let c = dlsym(library, "\(self.symbolPrefix)_create"),
           let r = dlsym(library, "\(self.symbolPrefix)_request"),
           let k = dlsym(library, "\(self.symbolPrefix)_cancel"),
           let d = dlsym(library, "\(self.symbolPrefix)_destroy") {
          self.create = unsafeBitCast(c, to: Create.self)
          self.request = unsafeBitCast(r, to: Request.self)
          self.cancel = unsafeBitCast(k, to: Control.self)
          self.destroy = unsafeBitCast(d, to: Control.self)
        }
        if self.sessions[owner] == nil {
          guard let handle = self.create?() else {
            result(["ok": false, "error": "当前安装未提供匹配的 \(label) 原生音频组件"]); return
          }
          self.sessions[owner] = Session(handle, owner)
        }
        result(["ok": true]); return
      }
      guard let session = self.sessions[owner], let invoke = self.request else {
        result(["ok": false, "error": "\(label) 音频组件已关闭"]); return
      }
      guard let data = try? JSONSerialization.data(withJSONObject: args),
            let input = String(data: data, encoding: .utf8) else {
        result(["ok": false, "error": "无效的音频请求"]); return
      }
      // All inference and destruction for an owner run on the same queue.
      // Only the explicitly thread-safe cancellation flag crosses queues.
      session.queue.async {
        let value: Any = input.withCString { pointer in
          guard let response = invoke(session.handle, pointer),
                let output = String(validatingUTF8: response)?.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: output) else {
            return ["ok": false, "error": "\(label) 原生音频返回无效结果"]
          }
          return parsed
        }
        DispatchQueue.main.async { result(value) }
      }
    }
  }
}

private final class AsrAccelerationBridge {
  private typealias Request = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
  private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private let queue = DispatchQueue(label: "com.example.video_player_app.asr-acceleration")
  private let defaults = UserDefaults.standard
  private let pendingKey = "asr-gpu-in-flight-v1"
  private let failedKey = "asr-gpu-interrupted-v1"
  private var channel: FlutterMethodChannel?
  private var currentSignature = ""
  private var nativeCpuLoaded = false

  private var hardware: String {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(cString: bytes)
  }

  init() {
    if let interrupted = UserDefaults.standard.string(forKey: "asr-gpu-in-flight-v1") {
      var failed = UserDefaults.standard.stringArray(forKey: "asr-gpu-interrupted-v1") ?? []
      if !failed.contains(interrupted) { failed.append(interrupted) }
      UserDefaults.standard.set(Array(failed.suffix(16)), forKey: "asr-gpu-interrupted-v1")
      UserDefaults.standard.removeObject(forKey: "asr-gpu-in-flight-v1")
    }
  }
  func register(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.example.video_player_app/asr_acceleration", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterMethodNotImplemented); return }
      if call.method == "environment" {
        let bundle = Bundle.main
        let attributes = bundle.executableURL.flatMap {
          try? FileManager.default.attributesOfItem(atPath: $0.path)
        }
        result([self.hardware,
          bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
          (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
          (attributes?[.size] as? NSNumber)?.int64Value ?? 0] as [Any])
        return
      }
      if call.method == "close" {
        self.queue.async {
          _ = self.execute(["op": "close"])
          self.defaults.removeObject(forKey: self.pendingKey)
          self.currentSignature = ""
          self.nativeCpuLoaded = false
          DispatchQueue.main.async { result(nil) }
        }
        return
      }
      guard call.method == "request", let message = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented); return
      }
      self.queue.async {
        let reply = self.handle(message)
        DispatchQueue.main.async { result(reply) }
      }
    }
  }
  private func handle(_ message: [String: Any]) -> [String: Any] {
    let operation = message["op"] as? String ?? ""
    if operation == "open" { return ["ok": true] }
    // The new CTC CPU adapter uses the same static component, without asking
    // CoreML to run. Keep the signed GPU-combination gates below unchanged.
    if operation == "load" {
      nativeCpuLoaded = false
      if message["backend"] as? String == "cpu",
         message["engine"] as? String == "firered2",
         message["floatWeights"] as? Bool != true {
        defaults.removeObject(forKey: pendingKey)
        currentSignature = ""
        let reply = execute(message)
        nativeCpuLoaded = reply["ok"] as? Bool == true
        return reply
      }
    }
    if operation == "decode" && nativeCpuLoaded {
      let reply = execute(message)
      if reply["ok"] as? Bool != true {
        nativeCpuLoaded = false
        _ = execute(["op": "close"])
      }
      return reply
    }
    if operation == "close" || operation == "unload" { nativeCpuLoaded = false }
    if operation == "capabilities" || operation == "load" {
      let capabilities = execute(["op": "capabilities"])
      guard capabilities["ok"] as? Bool == true else { return capabilities }
      let records = Bundle.main.object(forInfoDictionaryKey: "FluentValidatedAsrGpuCombinations") as? [[String: String]] ?? []
      let runtime = capabilities["runtime"] as? String ?? ""
      let identity = message["identity"] as? String ?? ""
      let matching = records.filter {
        $0["modelIdentity"] == identity && $0["hardware"] == hardware &&
        $0["osMajor"] == String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) &&
        $0["runtime"] == runtime && !runtime.isEmpty
      }
      if operation == "capabilities" {
        guard !matching.isEmpty else {
          return ["ok": true, "devices": [], "reason": "当前 iOS 模型／设备组合尚未通过真机验证，使用 CPU"]
        }
        return capabilities
      }
      let weights = message["weightsIdentity"] as? String ?? ""
      guard matching.contains(where: { $0["weightsIdentity"] == weights }) else {
        return ["ok": false, "error": "当前 iOS 权重／设备组合尚未通过真机验证，使用 CPU"]
      }
      let signature = identity + ":" + weights + ":" + hardware + ":" + runtime + ":" +
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ":" +
        ProcessInfo.processInfo.operatingSystemVersionString
      if (defaults.stringArray(forKey: failedKey) ?? []).contains(signature) {
        return ["ok": false, "error": "上次硬件加速未正常结束，此组合已停用并回退 CPU"]
      }
      currentSignature = signature
    }
    if operation == "load" {
      defaults.set(currentSignature, forKey: pendingKey)
      // Flush before entering native code, so a fatal driver failure cannot
      // create an automatic crash loop after the next application launch.
      defaults.synchronize()
    }
    if operation == "decode" && currentSignature.isEmpty {
      return ["ok": false, "error": "CoreML 模型尚未通过检查并加载"]
    }
    let reply = execute(message)
    if reply["ok"] as? Bool != true {
      _ = execute(["op": "close"])
      defaults.removeObject(forKey: pendingKey)
      currentSignature = ""
    }
    return reply
  }
  private func execute(_ message: [String: Any]) -> [String: Any] {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      return ["ok": false, "error": "当前安装没有经过验证的 CoreML 转录组件，使用 CPU"]
    }
    defer { dlclose(handle) }
    guard let rawRequest = dlsym(handle, "FluentAsrRequest"),
      let rawFree = dlsym(handle, "FluentAsrFree"),
      let data = try? JSONSerialization.data(withJSONObject: message),
      let text = String(data: data, encoding: .utf8) else {
      return ["ok": false, "error": "当前安装没有经过验证的 CoreML 转录组件，使用 CPU"]
    }
    let request = unsafeBitCast(rawRequest, to: Request.self)
    let free = unsafeBitCast(rawFree, to: Free.self)
    guard let output = text.withCString({ request($0) }) else {
      return ["ok": false, "error": "CoreML 转录组件未返回结果"]
    }
    defer { free(output) }
    guard let bytes = String(cString: output).data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      return ["ok": false, "error": "CoreML 返回无效结果"]
    }
    return decoded
  }
}

private final class _YtDlpStreamProxy: NSObject, FlutterStreamHandler {
  weak var owner: AppDelegate?

  init(owner: AppDelegate) {
    self.owner = owner
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    owner?.ytDlpEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    owner?.ytDlpEventSink = nil
    return nil
  }
}
