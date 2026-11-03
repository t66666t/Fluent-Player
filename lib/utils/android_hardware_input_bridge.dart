import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'tooltip_hover_policy.dart';

typedef AndroidHardwareKeyListener =
    void Function(AndroidHardwareKeyMessage message);

class AndroidHardwareKeyMessage {
  const AndroidHardwareKeyMessage({
    required this.logicalKey,
    required this.physicalKey,
    required this.isDown,
    required this.isRepeat,
    required this.eventTime,
    required this.hasBlockingModifier,
    this.isShiftPressed = false,
  });

  final LogicalKeyboardKey logicalKey;
  final PhysicalKeyboardKey physicalKey;
  final bool isDown;
  final bool isRepeat;
  final Duration eventTime;
  final bool hasBlockingModifier;

  /// Shift is not a blocking modifier; it chords with arrows for speed steps.
  final bool isShiftPressed;

  KeyEvent toKeyEvent() {
    if (!isDown) {
      return KeyUpEvent(
        physicalKey: physicalKey,
        logicalKey: logicalKey,
        timeStamp: eventTime,
      );
    }
    if (isRepeat) {
      return KeyRepeatEvent(
        physicalKey: physicalKey,
        logicalKey: logicalKey,
        timeStamp: eventTime,
      );
    }
    return KeyDownEvent(
      physicalKey: physicalKey,
      logicalKey: logicalKey,
      timeStamp: eventTime,
    );
  }
}

/// Android Activity-level fallback for external keyboards and hover devices.
///
/// Normal Flutter key/pointer delivery remains enabled. This bridge only fills
/// gaps seen with vendor keyboards, desktop modes, and native video surfaces.
class AndroidHardwareInputBridge {
  AndroidHardwareInputBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.video_player_app/hardware_input',
  );
  static final Set<AndroidHardwareKeyListener> _keyListeners =
      <AndroidHardwareKeyListener>{};
  static final Set<int> _nativeMouseDevices = <int>{};
  static final Map<int, Offset> _nativeMousePositions = <int, Offset>{};
  static bool _initialized = false;

  static void addKeyListener(AndroidHardwareKeyListener listener) {
    if (!Platform.isAndroid) return;
    _ensureInitialized();
    _keyListeners.add(listener);
  }

  static void removeKeyListener(AndroidHardwareKeyListener listener) {
    _keyListeners.remove(listener);
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      final rawArguments = call.arguments;
      if (rawArguments is! Map) return;
      final arguments = Map<Object?, Object?>.from(rawArguments);
      if (call.method == 'pointerHover') {
        dispatchNativeHoverForTesting(arguments);
        return;
      }
      if (call.method != 'keyEvent') return;
      final message = decodeKeyForTesting(arguments);
      if (message == null) return;
      for (final listener in List<AndroidHardwareKeyListener>.of(
        _keyListeners,
      )) {
        listener(message);
      }
    });
  }

  /// Re-injects Activity hover using a distinct device id. MouseRegion,
  /// InkWell and Tooltip then receive the same events as on desktop Flutter.
  @visibleForTesting
  static void dispatchNativeHoverForTesting(Map<Object?, Object?> arguments) {
    final action = arguments['action'] as int?;
    final x = (arguments['x'] as num?)?.toDouble();
    final y = (arguments['y'] as num?)?.toDouble();
    if (action == null || x == null || y == null) return;

    final originalDeviceId = arguments['deviceId'] as int? ?? 0;
    final device = 0x70000000 | (originalDeviceId & 0xffff);
    final timestamp = Duration(
      milliseconds: arguments['eventTime'] as int? ?? 0,
    );
    final position = Offset(x, y);

    void ensureAdded() {
      if (!_nativeMouseDevices.add(device)) return;
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          timeStamp: timestamp,
          pointer: device,
          device: device,
          position: position,
          kind: PointerDeviceKind.mouse,
        ),
      );
    }

    switch (action) {
      case 9: // MotionEvent.ACTION_HOVER_ENTER
      case 7: // MotionEvent.ACTION_HOVER_MOVE
        // A parked cursor still emits hover while, and just after, a touch.
        // Drop it until the cursor actually moves.
        if (!TooltipHoverPolicy.acceptHover(position)) {
          _removeNativeMouse(device, timestamp, position);
          return;
        }
        _nativeMousePositions[device] = position;
        ensureAdded();
        GestureBinding.instance.handlePointerEvent(
          PointerHoverEvent(
            timeStamp: timestamp,
            pointer: device,
            device: device,
            position: position,
            kind: PointerDeviceKind.mouse,
          ),
        );
        return;
      case 10: // MotionEvent.ACTION_HOVER_EXIT
        _removeNativeMouse(device, timestamp, position);
        return;
    }
  }

  /// Drops every re-injected mouse so MouseRegions exit when a finger goes down.
  static void releaseParkedNativeMice() {
    final devices = List<int>.of(_nativeMouseDevices);
    for (final device in devices) {
      _removeNativeMouse(
        device,
        Duration.zero,
        _nativeMousePositions[device] ?? Offset.zero,
      );
    }
  }

  static void _removeNativeMouse(
    int device,
    Duration timestamp,
    Offset position,
  ) {
    _nativeMousePositions.remove(device);
    if (!_nativeMouseDevices.remove(device)) return;
    GestureBinding.instance.handlePointerEvent(
      PointerRemovedEvent(
        timeStamp: timestamp,
        pointer: device,
        device: device,
        position: position,
        kind: PointerDeviceKind.mouse,
      ),
    );
  }

  @visibleForTesting
  static AndroidHardwareKeyMessage? decodeKeyForTesting(
    Map<Object?, Object?> arguments,
  ) {
    final keyCode = arguments['keyCode'] as int?;
    if (keyCode == null) return null;
    // Android maps Escape to Back on many tablet keyboards. Leave both to the
    // operating system so the app never produces a duplicate navigation pop.
    if (keyCode == 4 || keyCode == 111) return null;

    final keys = _androidKeyMap[keyCode] ?? _keysFromCharacter(arguments);
    if (keys == null) return null;
    return AndroidHardwareKeyMessage(
      logicalKey: keys.$1,
      physicalKey: keys.$2,
      isDown: arguments['action'] == 0,
      isRepeat: (arguments['repeatCount'] as int? ?? 0) > 0,
      eventTime: Duration(milliseconds: arguments['eventTime'] as int? ?? 0),
      hasBlockingModifier:
          arguments['ctrl'] == true ||
          arguments['alt'] == true ||
          arguments['meta'] == true,
      isShiftPressed: arguments['shift'] == true,
    );
  }

  static (LogicalKeyboardKey, PhysicalKeyboardKey)? _keysFromCharacter(
    Map<Object?, Object?> arguments,
  ) {
    final unicode = arguments['unicodeChar'] as int? ?? 0;
    String character = unicode > 0 && unicode <= 0x10ffff
        ? String.fromCharCode(unicode)
        : (arguments['characters'] as String? ?? '');
    if (character.isEmpty) return null;
    character = String.fromCharCode(character.codeUnitAt(0)).toLowerCase();
    if (character == ' ') {
      return (LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
    }
    final index = character.codeUnitAt(0) - 0x61;
    if (index < 0 || index >= _letterKeys.length) return null;
    return _letterKeys[index];
  }

  static const List<(LogicalKeyboardKey, PhysicalKeyboardKey)> _letterKeys = [
    (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA),
    (LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB),
    (LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC),
    (LogicalKeyboardKey.keyD, PhysicalKeyboardKey.keyD),
    (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
    (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF),
    (LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG),
    (LogicalKeyboardKey.keyH, PhysicalKeyboardKey.keyH),
    (LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
    (LogicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyJ),
    (LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK),
    (LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL),
    (LogicalKeyboardKey.keyM, PhysicalKeyboardKey.keyM),
    (LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN),
    (LogicalKeyboardKey.keyO, PhysicalKeyboardKey.keyO),
    (LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP),
    (LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyQ),
    (LogicalKeyboardKey.keyR, PhysicalKeyboardKey.keyR),
    (LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
    (LogicalKeyboardKey.keyT, PhysicalKeyboardKey.keyT),
    (LogicalKeyboardKey.keyU, PhysicalKeyboardKey.keyU),
    (LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
    (LogicalKeyboardKey.keyW, PhysicalKeyboardKey.keyW),
    (LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX),
    (LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY),
    (LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ),
  ];

  static const Map<int, (LogicalKeyboardKey, PhysicalKeyboardKey)>
  _androidKeyMap = <int, (LogicalKeyboardKey, PhysicalKeyboardKey)>{
    19: (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
    20: (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
    21: (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
    22: (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
    29: (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA),
    30: (LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB),
    31: (LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC),
    32: (LogicalKeyboardKey.keyD, PhysicalKeyboardKey.keyD),
    33: (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
    34: (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF),
    35: (LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG),
    36: (LogicalKeyboardKey.keyH, PhysicalKeyboardKey.keyH),
    37: (LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
    38: (LogicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyJ),
    39: (LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK),
    40: (LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL),
    41: (LogicalKeyboardKey.keyM, PhysicalKeyboardKey.keyM),
    42: (LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN),
    43: (LogicalKeyboardKey.keyO, PhysicalKeyboardKey.keyO),
    44: (LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP),
    45: (LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyQ),
    46: (LogicalKeyboardKey.keyR, PhysicalKeyboardKey.keyR),
    47: (LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
    48: (LogicalKeyboardKey.keyT, PhysicalKeyboardKey.keyT),
    49: (LogicalKeyboardKey.keyU, PhysicalKeyboardKey.keyU),
    50: (LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
    51: (LogicalKeyboardKey.keyW, PhysicalKeyboardKey.keyW),
    52: (LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX),
    53: (LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY),
    54: (LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ),
    62: (LogicalKeyboardKey.space, PhysicalKeyboardKey.space),
    66: (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
    71: (LogicalKeyboardKey.bracketLeft, PhysicalKeyboardKey.bracketLeft),
    72: (LogicalKeyboardKey.bracketRight, PhysicalKeyboardKey.bracketRight),
    76: (LogicalKeyboardKey.slash, PhysicalKeyboardKey.slash),
    131: (LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1),
    141: (LogicalKeyboardKey.f11, PhysicalKeyboardKey.f11),
    160: (LogicalKeyboardKey.numpadEnter, PhysicalKeyboardKey.numpadEnter),
  };
}

/// Removes a duplicate if Android delivers one key through both Flutter and
/// the Activity fallback.
class AndroidHardwareKeyDeduplicator {
  /// Flutter's KeyEvent.timeStamp and Android KeyEvent.eventTime often use
  /// different clocks, and the MethodChannel hop is usually tens of
  /// milliseconds. Matching on those stamps therefore misses real duplicates
  /// and lets toggle shortcuts (B/G) fire twice — once each path — which
  /// looks like the key did nothing.
  static const Duration duplicateArrivalWindow = Duration(milliseconds: 200);

  final List<_AndroidKeyIdentity> _recent = <_AndroidKeyIdentity>[];

  bool shouldDispatch(KeyEvent event, {required bool fromNativeBridge}) {
    final now = DateTime.now();
    _recent.removeWhere(
      (entry) => now.difference(entry.receivedAt) > const Duration(seconds: 1),
    );
    final type = switch (event) {
      KeyDownEvent() => 0,
      KeyRepeatEvent() => 1,
      KeyUpEvent() => 2,
      _ => 3,
    };
    final duplicateIndex = _recent.indexWhere(
      (entry) =>
          entry.logicalKey == event.logicalKey &&
          entry.type == type &&
          entry.fromNativeBridge != fromNativeBridge &&
          now.difference(entry.receivedAt) <= duplicateArrivalWindow,
    );
    if (duplicateIndex >= 0) {
      _recent.removeAt(duplicateIndex);
      return false;
    }
    _recent.add(
      _AndroidKeyIdentity(
        logicalKey: event.logicalKey,
        type: type,
        fromNativeBridge: fromNativeBridge,
        receivedAt: now,
      ),
    );
    return true;
  }
}

class _AndroidKeyIdentity {
  const _AndroidKeyIdentity({
    required this.logicalKey,
    required this.type,
    required this.fromNativeBridge,
    required this.receivedAt,
  });

  final LogicalKeyboardKey logicalKey;
  final int type;
  final bool fromNativeBridge;
  final DateTime receivedAt;
}
