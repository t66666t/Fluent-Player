import Cocoa
import FlutterMacOS
import MediaPlayer
import Carbon
import Darwin

class MainFlutterWindow: NSWindow {
  private let imeChannelName = "com.example.video_player_app/ime_gate"
  private var textInputActive = false
  private var keyMonitor: Any?
  private var desktopMedia: DesktopMediaBridge?
  private var clipboardRevisionChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerClipboardRevision(flutterViewController.engine.binaryMessenger)
    desktopMedia = DesktopMediaBridge(flutterViewController.engine.binaryMessenger)
    let channel = FlutterMethodChannel(
      name: imeChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setTextInputActive" {
        self?.setTextInputActive((call.arguments as? Bool) ?? false)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      guard let self = self, !self.textInputActive else { return event }
      self.suppressIme()
      return event
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reapplyImeGate),
      name: NSWindow.didBecomeKeyNotification,
      object: self
    )
    setTextInputActive(false)

    super.awakeFromNib()
  }

  @objc private func reapplyImeGate() {
    setTextInputActive(textInputActive)
  }

  private func registerClipboardRevision(_ messenger: FlutterBinaryMessenger) {
    var bytes = [CChar](repeating: 0, count: 128)
    var length = bytes.count
    let hasBootID = sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0
    let bootID = hasBootID ? String(cString: bytes) : ""
    let persistent = !bootID.isEmpty
    let scope = persistent ? bootID : UUID().uuidString
    let channel = FlutterMethodChannel(
      name: "com.example.video_player_app/clipboard_revision", binaryMessenger: messenger)
    clipboardRevisionChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "getRevision" else {
        result(FlutterMethodNotImplemented); return
      }
      result([
        "token": "macos/\(getuid())/\(scope)/\(NSPasteboard.general.changeCount)",
        "persistent": persistent,
      ])
    }
  }

  private func setTextInputActive(_ active: Bool) {
    textInputActive = active
    if active {
      NSTextInputContext.current?.activate()
      contentViewController?.view.inputContext?.activate()
    } else {
      suppressIme()
    }
  }

  /// Letter keys must not enter marked text unless a text field is editing.
  /// Flutter's text client is a descendant of the Flutter view; move key
  /// focus back to that view so shortcuts stay raw in either input mode.
  private func suppressIme() {
    NSTextInputContext.current?.discardMarkedText()
    guard let flutterView = contentViewController?.view else { return }
    if let responder = firstResponder as? NSView,
       responder !== flutterView,
       responder.isDescendant(of: flutterView) {
      makeFirstResponder(flutterView)
    }
    flutterView.inputContext?.discardMarkedText()
    flutterView.inputContext?.deactivate()
  }
}

/// macOS uses Now Playing and Remote Command Center, not a Windows-style tray.
private final class DesktopMediaBridge {
  private let channel: FlutterMethodChannel
  private var state: [String: Any] = [:]
  private var targets: [(MPRemoteCommand, Any)] = []
  private var hotkeys: [EventHotKeyRef] = []
  private var eventHandler: EventHandlerRef?
  private var hotkeyIdentity = ""
  private var artworkIdentity = ""
  private var artwork: MPMediaItemArtwork?
  private var error = ""

  init(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.example.video_player_app/desktop_media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "initialize": self.installCommands(); result(self.status)
      case "update":
        self.state = call.arguments as? [String: Any] ?? [:]
        self.update(); result(self.status)
      case "dispose": self.state = [:]; self.update(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    releaseHotkeys()
    if let handler = eventHandler { RemoveEventHandler(handler) }
    for (command, target) in targets { command.removeTarget(target) }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    channel.setMethodCallHandler(nil)
  }

  private func flag(_ name: String) -> Bool { state[name] as? Bool ?? false }
  private var status: [String: Any] {
    ["systemMedia": true, "taskbar": false, "globalHotkeys": true,
     "hotkeysRegistered": hotkeys.count == 3, "error": error]
  }
  private func send(_ command: String, source: String = "system") {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.flag("active"), self.flag("canPlay") else { return }
      guard self.flag(source == "hotkey" ? "hotkeysEnabled" : "systemEnabled") else { return }
      if source == "hotkey" && self.hotkeys.count != 3 { return }
      if command == "previous" && !self.flag("canPrevious") { return }
      if command == "next" && !self.flag("canNext") { return }
      self.channel.invokeMethod("command", arguments: ["command": command, "source": source])
    }
  }

  private func installCommands() {
    guard targets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    for (command, name) in [(center.playCommand, "play"), (center.pauseCommand, "pause"),
                            (center.togglePlayPauseCommand, "playPause"), (center.previousTrackCommand, "previous"),
                            (center.nextTrackCommand, "next"), (center.stopCommand, "stop")] {
      command.isEnabled = false
      let target = command.addTarget { [weak self] _ in
        guard let self = self else { return .commandFailed }
        self.send(name)
        return .success
      }
      targets.append((command, target))
    }
  }

  private func releaseHotkeys() {
    for key in hotkeys { UnregisterEventHotKey(key) }
    hotkeys.removeAll()
  }

  private func configureHotkeys() {
    let enabled = flag("active") && flag("canPlay") && flag("hotkeysEnabled")
    let modifiers = state["hotkeyModifiers"] as? String ?? "ctrl+alt"
    let identity = "\(enabled)-\(modifiers)"
    guard identity != hotkeyIdentity else { return }
    hotkeyIdentity = identity
    releaseHotkeys(); error = ""
    guard enabled else { return }
    if eventHandler == nil {
      var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
        guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<DesktopMediaBridge>.fromOpaque(context).takeUnretainedValue()
        var key = EventHotKeyID()
        let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
        guard read == noErr, key.signature == 0x46504d44, key.id < 3 else { return OSStatus(eventNotHandledErr) }
        owner.send(["playPause", "previous", "next"][Int(key.id)], source: "hotkey")
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
      if installed != noErr { error = "Cannot install global shortcut handler (\(installed))."; return }
    }
    let mask = UInt32(controlKey | optionKey) | (modifiers == "ctrl+alt+shift" ? UInt32(shiftKey) : 0)
    for (index, code) in [kVK_Space, kVK_LeftArrow, kVK_RightArrow].enumerated() {
      var ref: EventHotKeyRef?
      let registered = RegisterEventHotKey(UInt32(code), mask, EventHotKeyID(signature: 0x46504d44, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
      guard registered == noErr, let ref = ref else {
        releaseHotkeys(); error = "Global shortcuts are occupied (\(registered)). Choose another modifier set."; return
      }
      hotkeys.append(ref)
    }
  }

  private func update() {
    configureHotkeys()
    let enabled = flag("active") && flag("systemEnabled") && flag("canPlay")
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = enabled
    center.pauseCommand.isEnabled = enabled
    center.togglePlayPauseCommand.isEnabled = enabled
    center.stopCommand.isEnabled = enabled
    center.previousTrackCommand.isEnabled = enabled && flag("canPrevious")
    center.nextTrackCommand.isEnabled = enabled && flag("canNext")
    guard enabled else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      artworkIdentity = ""; artwork = nil
      return
    }
    let path = state["artworkPath"] as? String ?? ""
    if artworkIdentity != path {
      artworkIdentity = path
      artwork = nil
      if let image = NSImage(contentsOfFile: path) {
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    let playing = flag("playing")
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: state["title"] as? String ?? "",
      MPMediaItemPropertyArtist: state["subtitle"] as? String ?? "Fluent Player",
      MPMediaItemPropertyPlaybackDuration: ((state["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: ((state["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? ((state["rate"] as? NSNumber)?.doubleValue ?? 1) : 0,
      MPNowPlayingInfoPropertyMediaType: (state["mediaType"] as? String == "video" ? MPNowPlayingInfoMediaType.video : MPNowPlayingInfoMediaType.audio).rawValue,
    ]
    if let artwork = artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }
}
