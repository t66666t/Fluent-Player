import Flutter
import Foundation
import UIKit
import os

/// System-owned model downloads. Completed files remain staged until Dart
/// verifies the immutable catalog hash and publishes an installed receipt.
final class ModelDownloadBridge: NSObject, URLSessionDownloadDelegate {
  static let prefix = "com.example.video_player_app.models."
  private let defaultsKey = "modelBackgroundTransfers.v1"
  private var channel: FlutterMethodChannel?
  private var workChannel: FlutterMethodChannel?
  private var pending: [String: FlutterResult] = [:]
  private var pausing = Set<String>()
  private var targets: [String: [String: Any]] = [:]
  private var sessions: [String: URLSession] = [:]
  private var backgroundCompletions: [String: () -> Void] = [:]
  private var inference = 0
  private var workLease = UIBackgroundTaskIdentifier.invalid

  override init() {
    super.init()
    targets = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
    _ = session(direct: false)
    _ = session(direct: true)
    NotificationCenter.default.addObserver(self, selector: #selector(backgroundChanged), name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(backgroundChanged), name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  func register(_ messenger: FlutterBinaryMessenger) {
    let download = FlutterMethodChannel(name: "com.example.video_player_app/model_downloads", binaryMessenger: messenger)
    channel = download
    download.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any], let key = args["key"] as? String else {
        result(FlutterError(code: "ARGUMENTS", message: "Invalid model transfer", details: nil)); return
      }
      if call.method == "download" {
        guard let address = args["url"] as? String, let url = URL(string: address), url.scheme == "https",
              let destination = args["destination"] as? String, self.safeDestination(destination) != nil else {
          result(FlutterError(code: "ARGUMENTS", message: "Invalid model download path or URL", details: nil)); return
        }
        self.attach(key: key, url: url, destination: destination, direct: args["direct"] as? Bool ?? false, result: result)
      } else if call.method == "pause" {
        self.pause(key: key, result: result)
      } else { result(FlutterMethodNotImplemented) }
    }
    let work = FlutterMethodChannel(name: "com.example.video_player_app/model_tasks", binaryMessenger: messenger)
    workChannel = work
    work.setMethodCallHandler { [weak self] call, result in
      if call.method == "deviceInfo" {
        result(["memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "availableMemoryBytes": os_proc_available_memory()]); return
      }
      guard call.method == "setActive" else { result(FlutterMethodNotImplemented); return }
      self?.inference = (call.arguments as? [String: Any])?["inference"] as? Int ?? 0
      self?.backgroundChanged()
      result(nil)
    }
  }

  func handleEvents(identifier: String, completion: @escaping () -> Void) {
    backgroundCompletions[identifier] = completion
    _ = session(direct: identifier.hasSuffix("direct"))
  }

  private func session(direct: Bool) -> URLSession {
    let identifier = Self.prefix + (direct ? "direct" : "system")
    if let existing = sessions[identifier] { return existing }
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 20
    if direct { config.connectionProxyDictionary = [:] }
    let value = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    sessions[identifier] = value
    return value
  }

  private func persist() { UserDefaults.standard.set(targets, forKey: defaultsKey) }
  private func safeDestination(_ raw: String) -> URL? {
    // Rebase a background task restored after an app-container path change.
    var path = raw
    if let range = path.range(of: "/Library/") { path = NSHomeDirectory() + String(path[range.lowerBound...]) }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
    return url.path.hasPrefix(home) ? url : nil
  }
  private func target(_ key: String) -> URL? {
    guard let path = targets[key]?["destination"] as? String else { return nil }
    return safeDestination(path)
  }

  private func attach(key: String, url: URL, destination: String, direct: Bool, result: @escaping FlutterResult) {
    if pending[key] != nil { result(FlutterError(code: "BUSY", message: "Model transfer already attached", details: nil)); return }
    let old = targets[key]
    let value = session(direct: direct)
    pending[key] = result
    targets[key] = ["destination": destination, "url": url.absoluteString, "session": value.configuration.identifier ?? ""]
    persist()
    if old?["completed"] as? Bool == true, old?["url"] as? String == url.absoluteString,
       let staged = target(key), FileManager.default.fileExists(atPath: staged.path) {
      finish(key); return
    }
    for other in sessions.values where other !== value {
      other.getAllTasks { tasks in
        for task in tasks where task.taskDescription == key { task.cancel() }
      }
    }
    value.getAllTasks { tasks in
      DispatchQueue.main.async {
        if let existing = tasks.first(where: { $0.taskDescription == key && $0.originalRequest?.url == url && ($0.state == .running || $0.state == .suspended) }) {
          self.targets[key] = ["destination": destination, "url": url.absoluteString, "taskId": existing.taskIdentifier, "session": value.configuration.identifier ?? ""]
          self.persist(); existing.resume(); return
        }
        for task in tasks where task.taskDescription == key { task.cancel() }
        self.targets[key] = ["destination": destination, "url": url.absoluteString, "session": value.configuration.identifier ?? ""]
        guard let target = self.target(key) else { self.finish(key, error: "Invalid destination"); return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resumeURL = target.appendingPathExtension("resume")
        let task: URLSessionDownloadTask
        if old?["url"] as? String == url.absoluteString, let data = try? Data(contentsOf: resumeURL) {
          task = value.downloadTask(withResumeData: data)
        } else { task = value.downloadTask(with: url) }
        task.taskDescription = key
        self.targets[key]?["taskId"] = task.taskIdentifier
        self.persist(); task.resume()
      }
    }
  }

  private func current(_ session: URLSession, _ task: URLSessionTask, _ key: String) -> Bool {
    return (targets[key]?["taskId"] as? Int) == task.taskIdentifier
      && (targets[key]?["session"] as? String) == session.configuration.identifier
      && (targets[key]?["url"] as? String) == task.originalRequest?.url?.absoluteString
  }
  private func finish(_ key: String, error: String? = nil) {
    let callback = pending.removeValue(forKey: key)
    if let error = error { callback?(FlutterError(code: "MODEL_DOWNLOAD", message: error, details: nil)) }
    else { callback?(nil) }
  }
  private func pause(key: String, result: @escaping FlutterResult) {
    if !pausing.insert(key).inserted { result(nil); return }
    let group = DispatchGroup()
    for session in sessions.values {
      group.enter()
      session.getAllTasks { tasks in
        for task in tasks where task.taskDescription == key {
          if let download = task as? URLSessionDownloadTask {
            group.enter()
            download.cancel { data in
              DispatchQueue.main.async {
                if self.current(session, download, key), let data = data, let target = self.target(key) {
                  try? data.write(to: target.appendingPathExtension("resume"), options: .atomic)
                }
                group.leave()
              }
            }
          }
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      self.pausing.remove(key); self.finish(key, error: "已暂停"); result(nil)
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let key = downloadTask.taskDescription, current(session, downloadTask, key) else { return }
    channel?.invokeMethod("progress", arguments: ["key": key, "received": totalBytesWritten])
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let key = downloadTask.taskDescription, current(session, downloadTask, key), let destination = target(key) else { return }
    guard let response = downloadTask.response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
      finish(key, error: "下载源返回错误状态"); return
    }
    do {
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
      try FileManager.default.moveItem(at: location, to: destination)
      try? FileManager.default.removeItem(at: destination.appendingPathExtension("resume"))
      targets[key]?["completed"] = true; persist()
      if !pausing.contains(key) { finish(key) }
    } catch { finish(key, error: error.localizedDescription) }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error = error as NSError?, let key = task.taskDescription, current(session, task, key) else { return }
    if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let destination = target(key) {
      try? data.write(to: destination.appendingPathExtension("resume"), options: .atomic)
    } else if !pausing.contains(key), let destination = target(key) {
      try? FileManager.default.removeItem(at: destination.appendingPathExtension("resume"))
    }
    if !pausing.contains(key) { finish(key, error: error.localizedDescription) }
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else { return }
    backgroundCompletions.removeValue(forKey: identifier)?()
  }
  @objc private func backgroundChanged() {
    if inference > 0 && UIApplication.shared.applicationState != .active && workLease == .invalid {
      workLease = UIApplication.shared.beginBackgroundTask(withName: "Local subtitle checkpoint") { [weak self] in
        self?.workChannel?.invokeMethod("interrupted", arguments: nil)
        self?.endLease()
      }
    } else if inference == 0 || UIApplication.shared.applicationState == .active { endLease() }
  }
  private func endLease() {
    if workLease != .invalid { UIApplication.shared.endBackgroundTask(workLease); workLease = .invalid }
  }
}
