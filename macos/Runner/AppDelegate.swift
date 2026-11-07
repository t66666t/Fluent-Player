import Cocoa
import FlutterMacOS
import Darwin

private final class ModelResourceBridge: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var source: DispatchSourceMemoryPressure?
  private var pressure = "normal"
  func register(_ messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "com.example.video_player_app/model_resources/events", binaryMessenger: messenger).setStreamHandler(self)
    FlutterMethodChannel(name: "com.example.video_player_app/model_resources", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "start": self.start(); result(nil)
      case "stop": self.stop(); result(nil)
      case "snapshot": result(self.snapshot((call.arguments as? [String: Any])?["pids"] as? [Int] ?? []))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func start() {
    guard source == nil else { return }
    for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sink?(["changed": true]) })
    }
    let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    memory.setEventHandler { [weak self] in
      guard let self = self, let memory = self.source else { return }
      self.pressure = memory.data.contains(.critical) ? "critical" : memory.data.contains(.warning) ? "warning" : "normal"
      self.sink?(["memoryPressure": self.pressure])
    }
    source = memory; memory.resume()
  }
  private func stop() {
    source?.cancel(); source = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll(); pressure = "normal"
  }
  private func integer(_ name: String) -> Int? {
    var value = 0, size = MemoryLayout<Int>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }
  private func resident(_ pid: Int32) -> UInt64? {
    var task = proc_taskinfo()
    let count = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
    return count == Int32(MemoryLayout<proc_taskinfo>.size) ? task.pti_resident_size : nil
  }
  private func snapshot(_ pids: [Int]) -> [String: Any] {
    let process = ProcessInfo.processInfo
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, host_flavor_t(HOST_VM_INFO64), $0, &count) }
    }
    var data: [String: Any] = ["processors": process.activeProcessorCount,
      "memoryBytes": process.physicalMemory, "memoryScope": "estimate",
      "powerSaving": process.isLowPowerModeEnabled, "thermalSupported": true,
      "memoryPressure": pressure, "environment": process.operatingSystemVersionString]
    switch process.thermalState {
    case .nominal: data["thermal"] = "normal"
    case .fair: data["thermal"] = "warm"
    case .serious: data["thermal"] = "moderate"
    case .critical: data["thermal"] = "severe"
    @unknown default: data["thermal"] = "unknown"
    }
    if let physical = integer("hw.physicalcpu") { data["physicalProcessors"] = physical }
    if status == KERN_SUCCESS, let page = integer("hw.pagesize") {
      data["availableMemoryBytes"] = (UInt64(vm.free_count) + UInt64(vm.inactive_count)) * UInt64(page)
    }
    var footprint = task_vm_info_data_t()
    var footprintCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let footprintStatus = withUnsafeMutablePointer(to: &footprint) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(footprintCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &footprintCount) }
    }
    if footprintStatus == KERN_SUCCESS { data["processBytes"] = footprint.phys_footprint }
    else if let own = resident(getpid()) { data["processBytes"] = own }
    var bytes: UInt64 = 0
    var complete = true
    for pid in Set(pids) {
      if let value = resident(Int32(pid)) { bytes += value } else { complete = false }
    }
    data["workerBytes"] = bytes; data["workerMemoryComplete"] = complete
    return data
  }
  deinit { stop() }
}

private struct MacYtDlpChannelError: Error {
  let code: String
  let message: String
  let details: Any?

  var flutterError: FlutterError {
    FlutterError(code: code, message: message, details: details)
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private let modelResources = ModelResourceBridge()
  private let resolveTimeoutSeconds: TimeInterval = 90
  private let ytDlpChannelName = "com.example.video_player_app/yt_dlp"
  private let ytDlpEventChannelName = "com.example.video_player_app/yt_dlp_events"
  private let ytDlpQueue = DispatchQueue(label: "com.example.video_player_app.macos.yt_dlp")
  fileprivate var ytDlpEventSink: FlutterEventSink?
  private var ytDlpTasks: [String: MacYtDlpTask] = [:]
  private var configuredYtDlpPath: String?
  private var configuredFfmpegPath: String?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      modelResources.register(controller.engine.binaryMessenger)
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func registerYtDlpChannels(controller: FlutterViewController) {}

  private func getYtDlpBinaryStatus() -> [String: Any?] { return [:] }

  private func importYoutubeCookies(_ filePath: String?) -> String? { return nil }

  private func saveYoutubeSessionConfig(_ config: Any?) {}

  private func loadYoutubeSessionConfig() -> [String: Any]? { return nil }

  private func resolveYoutubeMeta(_ args: [String: Any]?) throws -> [String: Any] { return [:] }

  private func startYoutubeDownload(_ args: [String: Any]?) throws -> Bool { return false }

  private func pauseYoutubeDownload(_ taskId: String?) -> Bool { return false }

  private func cancelYoutubeDownload(_ taskId: String?) -> Bool { return false }

  private func removeYoutubeTask(_ taskId: String?) -> Bool { return false }

  private func getYoutubeTaskStatus(_ taskId: String?) -> [String: Any]? { return nil }

  private func handleYtDlpChunk(task: MacYtDlpTask, chunk: String) {}

  private func handleYtDlpLine(task: MacYtDlpTask, line: String) {}

  private func finishYtDlpTask(task: MacYtDlpTask, exitCode: Int32) {}

  private func emitYtDlpEvent(_ payload: [String: Any]) {}

  private func terminateProcessTree(_ process: Process) {
    let pid = process.processIdentifier
    guard pid > 0 else { return }

    // Terminate direct helper processes (notably ffmpeg) before their parent
    // can exit and they are re-parented.
    let childTerminator = Process()
    childTerminator.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    childTerminator.arguments = ["-TERM", "-P", String(pid)]
    try? childTerminator.run()
    process.terminate()

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(150)) {
      guard process.isRunning else { return }
      let childKiller = Process()
      childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
      childKiller.arguments = ["-KILL", "-P", String(pid)]
      try? childKiller.run()
      kill(pid, SIGKILL)
    }
  }

  private func findExecutable(candidates: [String]) -> String? {
    let fileManager = FileManager.default
    let configuredPath = candidates.contains(where: { $0.hasPrefix("yt-dlp") })
      ? configuredYtDlpPath
      : configuredFfmpegPath
    if let configuredPath {
      return fileManager.isExecutableFile(atPath: configuredPath) ? configuredPath : nil
    }
    let appSupportYtDir = appSupportDirectory().appendingPathComponent("yt_dlp", isDirectory: true)
    let bundleResourceDir = Bundle.main.resourceURL
    let bundleExecutableDir = Bundle.main.executableURL?.deletingLastPathComponent()

    let searchRoots: [URL?] = [
      appSupportYtDir,
      bundleExecutableDir,
      bundleResourceDir?.appendingPathComponent("yt_dlp", isDirectory: true),
      bundleResourceDir,
    ]
    for root in searchRoots {
      guard let root else { continue }
      for candidate in candidates {
        let path = root.appendingPathComponent(candidate).path
        if fileManager.isExecutableFile(atPath: path) {
          return path
        }
      }
    }

    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in envPath.split(separator: ":") {
      let base = String(directory)
      for candidate in candidates {
        let path = URL(fileURLWithPath: base).appendingPathComponent(candidate).path
        if fileManager.isExecutableFile(atPath: path) {
          return path
        }
      }
    }
    return nil
  }

  private func runProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval? = nil
  ) throws -> (exitCode: Int32, stdoutText: String, stderrText: String, timedOut: Bool) {
    let process = Process()
    process.environment = ProcessInfo.processInfo.environment.filter { !["http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy"].contains($0.key.lowercased()) }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    var timedOut = false
    if let timeout {
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        timedOut = true
        process.terminate()
        process.waitUntilExit()
      }
    } else {
      process.waitUntilExit()
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    return (
      process.terminationStatus,
      output,
      process.terminationStatus == 0 && !timedOut ? "" : output,
      timedOut
    )
  }

  private func buildSessionArgs(_ sessionConfig: [String: Any]?) -> [String] {
    guard let sessionConfig else { return [] }
    var args: [String] = []

    func boolValue(_ key: String) -> Bool {
      sessionConfig[key] as? Bool ?? false
    }

    func stringValue(_ key: String) -> String? {
      (sessionConfig[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func intValue(_ key: String) -> Int? {
      if let value = sessionConfig[key] as? Int {
        return value
      }
      if let value = sessionConfig[key] as? NSNumber {
        return value.intValue
      }
      return nil
    }

    if boolValue("singleVideo") { args.append("--no-playlist") }
    if let referer = stringValue("referer") { args.append(contentsOf: ["--referer", referer]) }
    if boolValue("useCookies"), let cookiesPath = stringValue("cookiesFilePath") {
      args.append(contentsOf: ["--cookies", cookiesPath])
    }
    if boolValue("useCustomUserAgent"), let userAgent = stringValue("userAgent") {
      args.append(contentsOf: ["--add-header", "User-Agent:\(userAgent)"])
    }
    if boolValue("useProxy"), let proxy = stringValue("proxy") {
      args.append(contentsOf: ["--proxy", proxy])
    }
    if let timeout = intValue("socketTimeoutSeconds"), timeout > 0 {
      args.append(contentsOf: ["--socket-timeout", "\(timeout)"])
    }
    if let retries = intValue("retries"), retries > 0 {
      args.append(contentsOf: ["--retries", "\(retries)"])
    }
    if let fragmentRetries = intValue("fragmentRetries"), fragmentRetries > 0 {
      args.append(contentsOf: ["--fragment-retries", "\(fragmentRetries)"])
    }
    if let concurrentFragments = intValue("concurrentFragments"), concurrentFragments > 0 {
      args.append(contentsOf: ["-N", "\(concurrentFragments)"])
    }
    if let rateLimit = stringValue("rateLimit") {
      args.append(contentsOf: ["-r", rateLimit])
    }
    if boolValue("forceIpv4") {
      args.append("-4")
    }
    let extractorParts = buildYoutubeExtractorParts(sessionConfig)
    if !extractorParts.isEmpty {
      args.append(contentsOf: ["--extractor-args", "youtube:\(extractorParts.joined(separator: ";"))"])
    }
    return args
  }

  private func buildYoutubeExtractorParts(_ sessionConfig: [String: Any]) -> [String] { return [:] }

  private func markerOutputPath(_ marker: String, from line: String) -> String? {
    guard let range = line.range(of: marker) else { return nil }
    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).unquoted.nilIfEmpty
  }

  private func resolveFinalOutputPath(_ task: MacYtDlpTask) -> String? {
    let candidates = [task.outputPath] + task.producedPaths
    for candidate in candidates {
      guard let candidate = candidate.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: candidate)
      guard FileManager.default.fileExists(atPath: url.path), !url.isTemporaryYtDlpArtifact else {
        continue
      }
      if !url.isSubtitleSidecar {
        return candidate
      }
    }
    for candidate in candidates {
      guard let candidate = candidate.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: candidate)
      guard FileManager.default.fileExists(atPath: url.path), !url.isTemporaryYtDlpArtifact else {
        continue
      }
      return candidate
    }
    return nil
  }

  private func firstRegexMatch(pattern: String, text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  private func appSupportDirectory() -> URL {
    let fileManager = FileManager.default
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cn.teezy.fluentplayer.standard", isDirectory: true)
  }
}

private final class _MacYtDlpStreamProxy: NSObject, FlutterStreamHandler {
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

private final class MacYtDlpTask {
  let taskId: String
  let outputDir: URL
  let outputTemplate: String
  let process: Process
  let pipe: Pipe
  var status = "queued"
  var progress = 0.0
  var speedText = ""
  var etaText = ""
  var outputPath = ""
  var producedPaths: [String] = []
  var errorCode = ""
  var message = ""
  var terminationReason = ""
  var pendingBuffer = ""
  var logTail: [String] = []

  init(taskId: String, outputDir: URL, outputTemplate: String, process: Process, pipe: Pipe) {
    self.taskId = taskId
    self.outputDir = outputDir
    self.outputTemplate = outputTemplate
    self.process = process
    self.pipe = pipe
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }

  var unquoted: String {
    guard count >= 2, hasPrefix("\""), hasSuffix("\"") else { return self }
    return String(dropFirst().dropLast())
  }
}

private extension URL {
  var isTemporaryYtDlpArtifact: Bool {
    let ext = pathExtension.lowercased()
    return ext == "part" || ext == "ytdl" || ext == "tmp"
  }

  var isSubtitleSidecar: Bool {
    let ext = pathExtension.lowercased()
    return ["srt", "ass", "ssa", "vtt", "lrc", "json3", "srv1", "srv2", "srv3", "ttml"]
      .contains(ext)
  }
}
