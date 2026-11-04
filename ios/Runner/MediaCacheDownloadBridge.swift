import Flutter
import Foundation
import UIKit

/// Background requests belong to URLSession; the Dart queue remains the only
/// owner of media publication. This registry contains identity and sandbox
/// paths, never cookies, signed URLs or proxy passwords.
final class MediaCacheDownloadBridge: NSObject, URLSessionDownloadDelegate {
  static let prefix = "com.example.video_player_app.media-cache."
  private let defaultsKey = "mediaCacheBackgroundTransfers.v1"
  private var channel: FlutterMethodChannel?
  private var records: [String: [String: Any]] = [:]
  private var callbacks: [String: FlutterResult] = [:]
  private var sessions: [String: URLSession] = [:]
  private var completions: [String: () -> Void] = [:]
  private var pausing = Set<String>()
  private var progressTimes: [String: TimeInterval] = [:]

  override init() {
    super.init()
    records = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
    _ = session(direct: false)
    _ = session(direct: true)
  }
  func register(_ messenger: FlutterBinaryMessenger) {
    let value = FlutterMethodChannel(name: "com.example.video_player_app/media_cache_transfers", binaryMessenger: messenger)
    channel = value
    value.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "ARGUMENTS", message: "Invalid media cache transfer", details: nil)); return
      }
      if call.method == "forgetDirectory" || call.method == "pauseDirectory" {
        guard let path = args["directory"] as? String, let directory = self.safePath(path) else {
          result(FlutterError(code: "ARGUMENTS", message: "Invalid cache directory", details: nil)); return
        }
        self.finishDirectory(directory, forget: call.method == "forgetDirectory", result: result); return
      }
      guard let key = args["key"] as? String else { result(FlutterMethodNotImplemented); return }
      if call.method == "pause" { self.pause(key, result); return }
      guard call.method == "download", let identity = args["identity"] as? String,
            let address = args["url"] as? String, let url = URL(string: address),
            ["https", "http"].contains(url.scheme ?? ""),
            let rawPath = args["destination"] as? String, let destination = self.safePath(rawPath) else {
        result(FlutterError(code: "ARGUMENTS", message: "Invalid cache destination or source", details: nil)); return
      }
      self.download(key: key, identity: identity, url: url, destination: destination,
                    headers: args["headers"] as? [String: String] ?? [:],
                    direct: args["direct"] as? Bool ?? false, result: result)
    }
  }
  func handleEvents(identifier: String, completion: @escaping () -> Void) {
    completions[identifier] = completion
    _ = session(direct: identifier.hasSuffix("direct"))
  }
  private func session(direct: Bool) -> URLSession {
    let identifier = Self.prefix + (direct ? "direct" : "system")
    if let existing = sessions[identifier] { return existing }
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 7 * 24 * 60 * 60
    config.httpMaximumConnectionsPerHost = 4
    if direct { config.connectionProxyDictionary = [:] }
    let value = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    sessions[identifier] = value
    return value
  }
  private func persist() { UserDefaults.standard.set(records, forKey: defaultsKey) }
  private func safePath(_ raw: String) -> URL? {
    var path = raw
    // Sandbox container UUIDs change across installations and app upgrades.
    for marker in ["/Library/", "/Documents/"] {
      if let range = path.range(of: marker) { path = NSHomeDirectory() + String(path[range.lowerBound...]); break }
    }
    let value = URL(fileURLWithPath: path).standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
    guard value.path.hasPrefix(home), value.pathComponents.contains(where: { $0.hasPrefix("cache_") }) else { return nil }
    return value
  }
  private func destination(_ key: String) -> URL? {
    guard let path = records[key]?["destination"] as? String else { return nil }
    return safePath(path)
  }
  private func finish(_ key: String, receipt: [String: Any]? = nil, error: String? = nil) {
    guard let callback = callbacks.removeValue(forKey: key) else { return }
    if let error = error { callback(FlutterError(code: "CACHE_DOWNLOAD", message: error, details: nil)) }
    else { callback(receipt ?? [:]) }
  }
  private func download(key: String, identity: String, url: URL, destination: URL,
                        headers: [String: String], direct: Bool, result: @escaping FlutterResult) {
    guard callbacks[key] == nil else {
      result(FlutterError(code: "BUSY", message: "This transfer is already attached", details: nil)); return
    }
    let receiptURL = destination.appendingPathExtension("receipt.json")
    if let data = try? Data(contentsOf: receiptURL),
       let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       receipt["identity"] as? String == identity,
       let expected = receipt["bytes"] as? NSNumber,
       let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
       let actual = attrs[.size] as? NSNumber, expected == actual {
      result(receipt); return
    }
    callbacks[key] = result
    let previous = records[key]
    let value = session(direct: direct)
    records[key] = ["destination": destination.path, "identity": identity,
                    "session": value.configuration.identifier ?? ""]
    persist()
    value.getAllTasks { all in
      DispatchQueue.main.async {
        guard self.callbacks[key] != nil else { return }
        if previous?["identity"] as? String == identity,
           let existing = all.first(where: { $0.taskDescription == key && $0.originalRequest?.url == url &&
             ($0.state == .running || $0.state == .suspended) }) {
          self.records[key]?["taskId"] = existing.taskIdentifier
          self.persist(); existing.resume(); return
        }
        for task in all where task.taskDescription == key { task.cancel() }
        for other in self.sessions.values where other !== value {
          other.getAllTasks { tasks in for task in tasks where task.taskDescription == key { task.cancel() } }
        }
        do { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { self.finish(key, error: "缓存存储目录不可用"); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let resumeURL = destination.appendingPathExtension("resume")
        let transfer: URLSessionDownloadTask
        if previous?["identity"] as? String == identity,
           let data = try? Data(contentsOf: resumeURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
           let oldRequest = plist["NSURLSessionResumeInfoOriginalRequest"] as? Data,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURLRequest.self, from: oldRequest),
           decoded.url == url {
          transfer = value.downloadTask(withResumeData: data)
        } else { transfer = value.downloadTask(with: request) }
        transfer.taskDescription = key
        self.records[key]?["taskId"] = transfer.taskIdentifier
        self.persist(); transfer.resume()
      }
    }
  }
  private func current(_ session: URLSession, _ task: URLSessionTask, _ key: String) -> Bool {
    (records[key]?["taskId"] as? Int) == task.taskIdentifier &&
      (records[key]?["session"] as? String) == session.configuration.identifier
  }
  private func finishDirectory(_ directory: URL, forget: Bool, result: @escaping FlutterResult) {
    let prefix = directory.path + "/"
    let keys = records.keys.filter { destination($0)?.path.hasPrefix(prefix) == true }
    let group = DispatchGroup()
    for key in keys {
      group.enter()
      pause(key) { _ in
        if forget {
          self.records.removeValue(forKey: key)
          self.progressTimes.removeValue(forKey: key)
        }
        group.leave()
      }
    }
    group.notify(queue: .main) { self.persist(); result(nil) }
  }
  private func pause(_ key: String, _ result: @escaping FlutterResult) {
    guard pausing.insert(key).inserted else { result(nil); return }
    let group = DispatchGroup()
    for session in sessions.values {
      group.enter()
      session.getAllTasks { tasks in
        for task in tasks where task.taskDescription == key {
          guard let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
          group.enter()
          download.cancel { data in
            DispatchQueue.main.async {
              if self.current(session, download, key), let data = data, let target = self.destination(key) {
                try? data.write(to: target.appendingPathExtension("resume"), options: .atomic)
              }
              group.leave()
            }
          }
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      self.pausing.remove(key)
      self.finish(key, error: "下载已暂停，断点已保留")
      result(nil)
    }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let key = downloadTask.taskDescription, current(session, downloadTask, key) else { return }
    let now = Date.timeIntervalSinceReferenceDate
    guard now - (progressTimes[key] ?? 0) >= 0.25 else { return }
    progressTimes[key] = now
    var args: [String: Any] = ["key": key, "received": totalBytesWritten]
    if totalBytesExpectedToWrite > 0 { args["total"] = totalBytesExpectedToWrite }
    channel?.invokeMethod("progress", arguments: args)
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let key = downloadTask.taskDescription, current(session, downloadTask, key),
          let target = destination(key), let response = downloadTask.response as? HTTPURLResponse else { return }
    let status = response.statusCode
    guard status == 200 || status == 206 else {
      finish(key, receipt: ["status": status, "retryAfter": response.value(forHTTPHeaderField: "Retry-After") ?? ""]); return
    }
    do {
      let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
      let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
      guard bytes > 0 else { finish(key, error: "下载结果为空"); return }
      if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
      try FileManager.default.moveItem(at: location, to: target)
      let receipt: [String: Any] = ["identity": records[key]?["identity"] ?? "", "status": status,
        "bytes": bytes, "etag": response.value(forHTTPHeaderField: "ETag") ?? "",
        "range": response.value(forHTTPHeaderField: "Content-Range") ?? "",
        "encoding": response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity"]
      try JSONSerialization.data(withJSONObject: receipt).write(to: target.appendingPathExtension("receipt.json"), options: .atomic)
      try? FileManager.default.removeItem(at: target.appendingPathExtension("resume"))
      if !pausing.contains(key) { finish(key, receipt: receipt) }
    } catch { finish(key, error: "缓存文件保存失败，已有断点将保留") }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error = error as NSError?, let key = task.taskDescription, current(session, task, key) else { return }
    if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let target = destination(key) {
      try? data.write(to: target.appendingPathExtension("resume"), options: .atomic)
    }
    if !pausing.contains(key) { finish(key, error: "系统下载已中断，断点已保留") }
  }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else { return }
    completions.removeValue(forKey: identifier)?()
  }
}
