import 'package:video_player_app/utils/app_branding.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Only public discovery metadata. Media names never appear in discovery.
@immutable
class LanSyncDevice {
  const LanSyncDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.lastSeen,
    required this.publicKeyBase64,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final DateTime lastSeen;
  final String publicKeyBase64;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'publicKey': publicKeyBase64,
  };
}

/// A short authentication string must be compared on both devices before
/// approving. Approvals are authenticated with the handshake's shared key.
class LanPairing {
  LanPairing._({
    required this.id,
    required this.peer,
    required this.code,
    required this.expiresAt,
    required this.key,
    required this.remoteBoot,
  });

  final String id;
  final LanSyncDevice peer;
  final String code;
  final DateTime expiresAt;
  bool localApproved = false;
  bool remoteApproved = false;
  final SecretKey key;
  final String remoteBoot;
  bool _persisting = false;
  bool _complete = false;
}

/// Local-first transport. Callbacks decide which folders a trusted peer may see.
///
/// X25519 identities are stored by the caller. Pairing adds two fresh random
/// challenges and requires mutual approval of a six-digit comparison code.
/// All library data uses AES-256-GCM; the receiver's per-start boot identifier,
/// authenticated direction and sequence window reject replayed requests.
class ProgressSyncLan extends ChangeNotifier {
  ProgressSyncLan({
    required this.deviceId,
    required this.deviceName,
    required List<int> privateKeyBytes,
    required Map<String, String> trustedPeerPublicKeys,
    required this.onTrustChanged,
    required this.onReadChanges,
    required this.onChanges,
    @visibleForTesting String? editionForTesting,
  }) : _edition = editionForTesting ?? kApplicationId,
       _privateKeyBytes = List<int>.of(privateKeyBytes),
       _trusted = Map<String, String>.of(trustedPeerPublicKeys);

  static const defaultPort = kProgressSyncDefaultPort;
  static const discoveryPort = kProgressSyncDiscoveryPort;
  static const discoveryTargetPorts = kProgressSyncDiscoveryTargets;
  static final _group = InternetAddress('239.255.47.79');
  static const _maxBodyBytes = 2 * 1024 * 1024;
  static const _maxBatchBytes = 384 * 1024;
  static const _maxBatchRecords = 250;
  static const _maxSyncPages = 1000;
  static const _maxSnapshotCount = 8;
  static const _maxSnapshotBytes = 32 * 1024 * 1024;
  static const _maxSnapshotTotalBytes = 64 * 1024 * 1024;
  static const _snapshotLifetime = Duration(minutes: 3);
  static const _timeout = Duration(seconds: 8);
  static const _pairLifetime = Duration(minutes: 3);
  static final _random = Random.secure();
  static const _networkChannel = MethodChannel(
    'com.example.video_player_app/progress_sync_network',
  );

  final String deviceId;
  final String deviceName;
  final String _edition;
  final List<int> _privateKeyBytes;
  final Map<String, String> _trusted;
  final FutureOr<void> Function(Map<String, String>) onTrustChanged;
  final Future<List<Map<String, dynamic>>> Function(String peerId)
  onReadChanges;
  final Future<void> Function(String peerId, List<Map<String, dynamic>>)
  onChanges;
  Future<Map<String, dynamic>> Function(
    String peerId,
    String method,
    Map<String, dynamic> payload,
  )?
  onControl;

  final Map<String, LanSyncDevice> _nearby = {};
  final Map<String, LanPairing> _pairings = {};
  final Map<String, String> _errors = {};
  final Set<String> _connected = {};
  final Map<String, _ReplayWindow> _received = {};
  final Map<String, _OutgoingSnapshot> _snapshots = {};
  int _snapshotBytes = 0;
  final Map<String, Future<void>> _syncing = {};
  final Map<String, DateTime> _pairAttemptTimes = {};
  final _cipher = AesGcm.with256bits();
  final _x25519 = X25519();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  SimpleKeyPair? _keyPair;
  String? _publicKey;
  String _boot = '';
  int _sendSequence = 0;
  HttpServer? _server;
  RawDatagramSocket? _udp;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  Timer? _maintenance;
  bool _polling = false;
  bool _disposed = false;
  int _activeRequests = 0;
  int _lifecycle = 0;
  final Map<String, int> _trustGeneration = {};
  Future<void>? _starting;
  DateTime? _lastAnnouncement;
  DateTime? _lastDiscovery;
  List<InternetAddress> _discoveryAddresses = [];

  List<LanSyncDevice> get nearbyDevices => List.unmodifiable(_nearby.values);
  List<LanPairing> get pairings {
    final byDevice = <String, LanPairing>{};
    for (final pairing in _pairings.values) {
      if (!pairing._complete &&
          pairing.expiresAt.isAfter(DateTime.now()) &&
          _trusted[pairing.peer.id] != pairing.peer.publicKeyBase64) {
        byDevice.putIfAbsent(pairing.peer.id, () => pairing);
      }
    }
    return List.unmodifiable(byDevice.values);
  }

  Set<String> get connectedPeers => Set.unmodifiable(_connected);
  Map<String, String> get errors => Map.unmodifiable(_errors);
  int? get port => _server?.port;
  String? get publicKeyBase64 => _publicKey;
  bool get isRunning => _server != null;
  bool isTrustedPeer(String peerId) => _trusted.containsKey(peerId);

  /// Long-lived transfers must not survive a stop or revoke/re-pair cycle.
  (int, int) authorizationEpoch(String peerId) =>
      (_lifecycle, _trustGeneration[peerId] ?? 0);

  Future<void> start({
    InternetAddress? bindAddress,
    bool enableDiscovery = true,
  }) {
    if (_starting != null) return _starting!;
    final future = _start(bindAddress, enableDiscovery);
    _starting = future;
    unawaited(
      future.then<void>(
        (_) {
          _starting = null;
        },
        onError: (Object error, StackTrace stackTrace) {
          _starting = null;
        },
      ),
    );
    return future;
  }

  Future<void> _start(
    InternetAddress? bindAddress,
    bool enableDiscovery,
  ) async {
    if (_disposed) throw StateError('LAN transport is disposed');
    if (_server != null) return;
    if (_privateKeyBytes.length != 32) {
      throw ArgumentError('X25519 private key must contain 32 bytes');
    }
    final lifecycle = _lifecycle;
    _keyPair = await _x25519.newKeyPairFromSeed(_privateKeyBytes);
    _publicKey = base64Encode((await _keyPair!.extractPublicKey()).bytes);
    if (_disposed || lifecycle != _lifecycle) return;
    _boot = _randomToken(24);
    _sendSequence = 0;
    _received.clear();
    _snapshots.clear();
    _snapshotBytes = 0;
    final address = bindAddress ?? InternetAddress.anyIPv4;
    HttpServer server;
    try {
      server = await HttpServer.bind(address, defaultPort, shared: false);
    } on SocketException {
      server = await HttpServer.bind(address, 0, shared: false);
    }
    if (_disposed || lifecycle != _lifecycle) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _server!.idleTimeout = _timeout;
    _server!.listen(
      (request) => unawaited(_handle(request)),
      onError: (_) {
        _errors['network'] = 'serverUnavailable';
        _notify();
      },
    );
    if (enableDiscovery) await _startDiscovery();
    if (_disposed || lifecycle != _lifecycle) return;
    _maintenance = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_maintain());
    });
    _notify();
  }

  Future<void> stop() async {
    _lifecycle++;
    await _setMulticastEnabled(false);
    _maintenance?.cancel();
    _maintenance = null;
    await _udpSubscription?.cancel();
    _udpSubscription = null;
    _udp?.close();
    _udp = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _pairings.clear();
    _connected.clear();
    _nearby.clear();
    _received.clear();
    _snapshots.clear();
    _snapshotBytes = 0;
    _discoveryAddresses = [];
    _lastDiscovery = null;
    _notify();
  }

  Future<void> _startDiscovery() async {
    try {
      await _setMulticastEnabled(true);
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      if (_disposed || _server == null) {
        socket.close();
        return;
      }
      _udp = socket;
      socket.multicastHops = 1;
      _udpSubscription = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          Datagram? datagram;
          while ((datagram = socket.receive()) != null) {
            _receiveAnnouncement(datagram!);
          }
        },
        onError: (_) {
          _errors['discovery'] = 'discoveryUnavailable';
          _notify();
        },
      );
      _errors.remove('discovery');
      await discover();
    } catch (_) {
      _errors['discovery'] = 'discoveryUnavailable';
      // Manual address pairing remains available without multicast permission.
    }
  }

  Future<void> _setMulticastEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod<void>('setMulticastEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // An older host can still use direct-address pairing.
    } on PlatformException {
      _errors['discovery'] = 'discoveryUnavailable';
    }
  }

  Future<void> discover() async {
    if (_server == null || _udp == null) return;
    _lastDiscovery = DateTime.now();
    await _refreshDiscoveryInterfaces();
    _announce('discover');
  }

  Future<void> _refreshDiscoveryInterfaces() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = <InternetAddress>[];
      for (final interface in interfaces) {
        final local = interface.addresses.where(_isLocal).toList();
        if (local.isEmpty) continue;
        try {
          _udp?.joinMulticast(_group, interface);
        } on SocketException {
          // Existing memberships and disconnected adapters are harmless.
        }
        addresses.addAll(local);
      }
      _discoveryAddresses = addresses;
    } catch (_) {
      _errors['discovery'] = 'discoveryUnavailable';
    }
  }

  void _announce(String kind) {
    if (_server == null || _udp == null) return;
    final bytes = utf8.encode(
      jsonEncode({
        ..._hello(),
        'service': 'video-player-progress',
        'kind': kind,
      }),
    );
    var sent = false;
    // The OS default route can point at a VPN rather than the actual Wi-Fi.
    for (final address in _discoveryAddresses) {
      try {
        _udp!.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ),
        );
        for (final targetPort in discoveryTargetPorts) {
          sent |= _udp!.send(bytes, _group, targetPort) > 0;
        }
      } catch (_) {
        // Continue when one adapter disconnects.
      }
    }
    if (sent) {
      _errors.remove('discovery');
      return;
    }
    try {
      for (final targetPort in discoveryTargetPorts) {
        _udp!.send(bytes, _group, targetPort);
      }
    } catch (_) {
      _errors['discovery'] = 'discoveryUnavailable';
    }
  }

  void _receiveAnnouncement(Datagram datagram) {
    if (datagram.data.length > 4096 || !_isLocal(datagram.address)) return;
    try {
      final data = _object(jsonDecode(utf8.decode(datagram.data)));
      if (data['service'] != 'video-player-progress' || data['v'] != 1) return;
      final peer = _device(data, datagram.address.address);
      if (peer.id == deviceId) return;
      _remember(peer);
      if (data['kind'] == 'discover' &&
          (_lastAnnouncement == null ||
              DateTime.now().difference(_lastAnnouncement!) >
                  const Duration(seconds: 1))) {
        _lastAnnouncement = DateTime.now();
        _announce('announce');
      }
    } catch (_) {
      // Discovery datagrams are untrusted and can be unrelated multicast.
    }
  }

  /// Direct address fallback, e.g. 192.168.1.12:47791. No subnet scanning.
  Future<LanSyncDevice> connectAddress(
    String address, {
    int port = defaultPort,
  }) async {
    final uri = Uri.parse(
      address.contains('://') ? address.trim() : 'http://${address.trim()}',
    );
    if (uri.scheme != 'http' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid local address');
    }
    final targetPort = uri.hasPort ? uri.port : port;
    final host = await _resolveLocal(uri.host);
    final hello = await _request(host, targetPort, '/v1/hello');
    final peer = _device(hello, host);
    if (peer.id == deviceId) throw StateError('Cannot connect to this device');
    _remember(peer);
    return peer;
  }

  Future<LanPairing> requestPair(LanSyncDevice peer) async {
    _requireStarted();
    _validateTrust(peer);
    for (final existing in _pairings.values) {
      if (existing.peer.id == peer.id &&
          existing.peer.publicKeyBase64 == peer.publicKeyBase64 &&
          existing.expiresAt.isAfter(DateTime.now())) {
        return existing;
      }
    }
    if (_pairings.length >= 12) throw StateError('Too many pairing requests');
    final id = _randomToken(18);
    final challenge = _randomToken(32);
    final response = await _request(peer.host, peer.port, '/v1/pair', {
      ..._hello(),
      'pairId': id,
      'challenge': challenge,
    });
    final remote = _device(response, peer.host);
    if (remote.id != peer.id ||
        remote.publicKeyBase64 != peer.publicKeyBase64) {
      throw StateError('Peer identity changed');
    }
    final remoteChallenge = _token(response['challenge'], 32);
    final remoteBoot = _token(response['boot'], 24);
    final pairing = await _makePairing(
      id,
      remote,
      challenge,
      remoteChallenge,
      remoteBoot,
    );
    _pairings[id] = pairing;
    _remember(remote);
    _notify();
    return pairing;
  }

  Future<void> approvePair(String id, {String? expectedCode}) async {
    final pairing = _activePair(id);
    if (expectedCode != null && expectedCode != pairing.code) {
      throw StateError('Pairing code does not match');
    }
    pairing.localApproved = true;
    _notify();
    await _exchangePairStatus(pairing);
  }

  Future<void> rejectPair(String id) async {
    final pairing = _pairings.remove(id);
    if (pairing != null) {
      try {
        final envelope = await _seal(
          pairing.peer,
          'pair:$id',
          pairing.remoteBoot,
          {'approved': false, 'rejected': true},
          key: pairing.key,
        );
        await _request(
          pairing.peer.host,
          pairing.peer.port,
          '/v1/pair/status',
          {'pairId': id, ...envelope},
        );
      } catch (_) {
        // Local rejection succeeds even if the other device disappeared.
      }
    }
    _notify();
  }

  Future<void> removePeer(String id) async {
    _trustGeneration[id] = (_trustGeneration[id] ?? 0) + 1;
    final previous = _trusted.remove(id);
    try {
      await onTrustChanged(Map.unmodifiable(_trusted));
    } catch (_) {
      if (previous != null) _trusted[id] = previous;
      rethrow;
    }
    _connected.remove(id);
    _pairings.removeWhere((_, pairing) => pairing.peer.id == id);
    for (final entry in _snapshots.entries.toList()) {
      if (entry.value.peerId == id) _dropSnapshot(entry.key, entry.value);
    }
    _notify();
  }

  Future<void> syncPeer(LanSyncDevice peer) {
    final existing = _syncing[peer.id];
    if (existing != null) return existing;
    final future = _syncPeer(peer);
    _syncing[peer.id] = future;
    unawaited(
      future.then<void>(
        (_) {
          _syncing.remove(peer.id);
        },
        onError: (Object error, StackTrace stackTrace) {
          _syncing.remove(peer.id);
        },
      ),
    );
    return future;
  }

  /// Small authenticated RPC. Bulk files must use the binary transfer channel.
  Future<Map<String, dynamic>> sendControl(
    LanSyncDevice peer,
    String method,
    Map<String, dynamic> payload,
  ) async {
    _requireStarted();
    final lifecycle = _lifecycle, trust = _trustGeneration[peer.id] ?? 0;
    void check() => _requirePeer(peer, lifecycle, trust);
    check();
    _controlMethod(method);
    if (_trusted[peer.id] != peer.publicKeyBase64) {
      throw StateError('Peer has not been paired');
    }
    final hello = await _request(peer.host, peer.port, '/v1/hello');
    final refreshed = _device(hello, peer.host);
    if (refreshed.id != peer.id ||
        refreshed.publicKeyBase64 != _trusted[peer.id]) {
      throw StateError('Peer identity changed');
    }
    final remoteBoot = _token(hello['boot'], 24);
    final key = await _sharedKey(peer, 'control');
    final envelope = await _seal(peer, 'control', remoteBoot, {
      'method': method,
      'payload': payload,
      'port': port,
    }, key: key);
    check();
    final response = await _request(
      peer.host,
      peer.port,
      '/v1/control',
      envelope,
    );
    check();
    final result = await _open(
      peer,
      'control-response',
      response,
      key: key,
      expectedSenderBoot: remoteBoot,
    );
    check();
    if (result['replyTo'] != envelope['nonce']) {
      throw StateError('Unrelated control response');
    }
    _remember(refreshed);
    return _object(result['result']);
  }

  Future<void> _syncPeer(LanSyncDevice peer) async {
    try {
      _requireStarted();
      final lifecycle = _lifecycle, trust = _trustGeneration[peer.id] ?? 0;
      void check() => _requirePeer(peer, lifecycle, trust);
      check();
      if (_trusted[peer.id] != peer.publicKeyBase64) {
        throw StateError('Peer has not been paired');
      }
      final hello = await _request(peer.host, peer.port, '/v1/hello');
      final refreshed = _device(hello, peer.host);
      if (refreshed.id != peer.id ||
          refreshed.publicKeyBase64 != _trusted[peer.id]) {
        throw StateError('Peer identity changed');
      }
      final key = await _sharedKey(peer, 'trusted');
      final changes = _freezeRecords(await onReadChanges(peer.id)).records;
      check();
      final remoteBoot = _token(hello['boot'], 24);
      final syncId = _randomToken(18);
      var sendOffset = 0;
      var readOffset = 0;
      var hasMoreRemote = true;
      for (var page = 0; ; page++) {
        check();
        if (page >= _maxSyncPages) throw StateError('Too many sync pages');
        final outgoing = _batch(changes, sendOffset);
        final envelope = await _seal(peer, 'sync', remoteBoot, {
          'changes': outgoing.records,
          'readOffset': readOffset,
          'syncId': syncId,
          'hasMoreOutgoing': outgoing.nextOffset < changes.length,
        }, key: key);
        check();
        final response = await _request(
          peer.host,
          peer.port,
          '/v1/sync',
          envelope,
        );
        check();
        final plain = await _open(
          peer,
          'sync-response',
          response,
          key: key,
          expectedSenderBoot: remoteBoot,
        );
        check();
        if (plain['replyTo'] != envelope['nonce']) {
          throw StateError('Unrelated sync response');
        }
        final nextOffset = _offset(plain['nextOffset']);
        hasMoreRemote = plain['hasMore'] == true;
        if (hasMoreRemote && nextOffset <= readOffset) {
          throw StateError('Sync pagination did not advance');
        }
        check();
        await onChanges(peer.id, _changes(plain['changes']));
        check();
        sendOffset = outgoing.nextOffset;
        readOffset = nextOffset;
        if (sendOffset >= changes.length && !hasMoreRemote) break;
      }
      check();
      _connected.add(peer.id);
      _errors.remove(peer.id);
      _remember(refreshed);
    } catch (_) {
      _connected.remove(peer.id);
      if (!_disposed && isRunning && isTrustedPeer(peer.id)) {
        _errors[peer.id] = 'syncUnavailable';
      } else {
        _errors.remove(peer.id);
      }
      _notify();
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (_activeRequests >= 12 ||
        !_isLocal(request.connectionInfo?.remoteAddress)) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    _activeRequests++;
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'GET' && request.uri.path == '/v1/hello') {
        await _respond(request, _hello());
        return;
      }
      if (request.method != 'POST') throw const _LanHttpError(404);
      final data = await _readJson(request);
      final remoteHost = request.connectionInfo!.remoteAddress.address;
      switch (request.uri.path) {
        case '/v1/pair':
          final peer = _device(data, remoteHost);
          _validateTrust(peer);
          if (peer.id == deviceId || _pairings.length >= 12) {
            throw const _LanHttpError(429);
          }
          final now = DateTime.now();
          final last = _pairAttemptTimes[remoteHost];
          if (last != null && now.difference(last).inSeconds < 2) {
            throw const _LanHttpError(429);
          }
          _pairAttemptTimes[remoteHost] = now;
          if (_pairAttemptTimes.length > 64) {
            _pairAttemptTimes.remove(_pairAttemptTimes.keys.first);
          }
          final id = _token(data['pairId'], 18);
          if (_pairings.containsKey(id)) throw const _LanHttpError(409);
          final incomingChallenge = _token(data['challenge'], 32);
          final challenge = _randomToken(32);
          final pairing = await _makePairing(
            id,
            peer,
            incomingChallenge,
            challenge,
            _token(data['boot'], 24),
          );
          _pairings[id] = pairing;
          _remember(peer);
          await _respond(request, {..._hello(), 'challenge': challenge});
          _notify();
        case '/v1/pair/status':
          final id = _token(data['pairId'], 18);
          final pairing = _activePair(id);
          final plain = await _open(
            pairing.peer,
            'pair:$id',
            data,
            key: pairing.key,
            expectedSenderBoot: pairing.remoteBoot,
          );
          pairing.remoteApproved |= plain['approved'] == true;
          final rejected = plain['rejected'] == true;
          if (!rejected) await _commitPair(pairing);
          final response = await _seal(
            pairing.peer,
            'pair-response:$id',
            pairing.remoteBoot,
            {'approved': pairing.localApproved, 'replyTo': data['nonce']},
            key: pairing.key,
          );
          if (rejected) _pairings.remove(id);
          await _respond(request, response);
          _notify();
        case '/v1/sync':
          final lifecycle = _lifecycle;
          final peerId = data['from'];
          final publicKey = _trusted[peerId];
          if (publicKey == null) throw const _LanHttpError(403);
          final peer = LanSyncDevice(
            id: peerId as String,
            name: _nearby[peerId]?.name ?? 'Device',
            host: remoteHost,
            port: _nearby[peerId]?.port ?? defaultPort,
            lastSeen: DateTime.now(),
            publicKeyBase64: publicKey,
          );
          final trust = _trustGeneration[peer.id] ?? 0;
          final key = await _sharedKey(peer, 'trusted');
          final plain = await _open(peer, 'sync', data, key: key);
          _requirePeer(peer, lifecycle, trust);
          final response = await _serveSyncPage(peer, data, plain, key);
          _requirePeer(peer, lifecycle, trust);
          await _respond(request, response);
          _requirePeer(peer, lifecycle, trust);
          _connected.add(peer.id);
          _errors.remove(peer.id);
          _notify();
        case '/v1/control':
          final lifecycle = _lifecycle;
          final peerId = data['from'];
          final publicKey = _trusted[peerId];
          if (publicKey == null || onControl == null) {
            throw const _LanHttpError(403);
          }
          final peer = LanSyncDevice(
            id: peerId as String,
            name: _nearby[peerId]?.name ?? 'Device',
            host: remoteHost,
            port: _nearby[peerId]?.port ?? defaultPort,
            lastSeen: DateTime.now(),
            publicKeyBase64: publicKey,
          );
          final trust = _trustGeneration[peer.id] ?? 0;
          final key = await _sharedKey(peer, 'control');
          final plain = await _open(peer, 'control', data, key: key);
          _requirePeer(peer, lifecycle, trust);
          final method = _controlMethod(plain['method']);
          final senderPort = plain['port'];
          if (senderPort is! int || senderPort < 1 || senderPort > 65535) {
            throw const _LanHttpError(400);
          }
          _remember(
            LanSyncDevice(
              id: peer.id,
              name: peer.name,
              host: remoteHost,
              port: senderPort,
              lastSeen: DateTime.now(),
              publicKeyBase64: publicKey,
            ),
          );
          final result = await onControl!(
            peer.id,
            method,
            _object(plain['payload']),
          ).timeout(_timeout);
          _requirePeer(peer, lifecycle, trust);
          final response = await _seal(
            peer,
            'control-response',
            _token(data['senderBoot'], 24),
            {'replyTo': data['nonce'], 'result': result},
            key: key,
          );
          _requirePeer(peer, lifecycle, trust);
          await _respond(request, response);
        default:
          throw const _LanHttpError(404);
      }
    } catch (error) {
      try {
        request.response.statusCode = error is _LanHttpError
            ? error.status
            : 400;
        await request.response.close();
      } catch (_) {
        // A timed-out client may have already disconnected.
      }
    } finally {
      _activeRequests--;
    }
  }

  Future<Map<String, dynamic>> _serveSyncPage(
    LanSyncDevice peer,
    Map<String, dynamic> envelope,
    Map<String, dynamic> plain,
    SecretKey key,
  ) async {
    final lifecycle = _lifecycle, trust = _trustGeneration[peer.id] ?? 0;
    void check() => _requirePeer(peer, lifecycle, trust);
    check();
    final readOffset = _offset(plain['readOffset']);
    final syncId = _token(plain['syncId'], 18);
    final senderBoot = _token(envelope['senderBoot'], 24);
    final hasMoreOutgoing = plain['hasMoreOutgoing'];
    if (hasMoreOutgoing is! bool) throw const _LanHttpError(400);
    final incoming = _changes(plain['changes']);
    _pruneSnapshots();
    final snapshotKey = jsonEncode([peer.id, senderBoot, syncId]);
    var snapshot = _snapshots[snapshotKey];
    final creating = snapshot == null;
    if (creating) {
      if (readOffset != 0) throw const _LanHttpError(409);
      // A fresh pass supersedes an abandoned pass from the same device. A
      // reconnect therefore does not have to wait for the old TTL to expire.
      for (final entry in _snapshots.entries.toList()) {
        if (entry.value.peerId == peer.id) {
          _dropSnapshot(entry.key, entry.value);
        }
      }
      if (_snapshots.length >= _maxSnapshotCount) {
        throw const _LanHttpError(429);
      }
      snapshot = _OutgoingSnapshot(
        peerId: peer.id,
        expiresAt: DateTime.now().add(_snapshotLifetime),
      );
      // Reserve before awaiting callbacks, so concurrent initial requests
      // cannot both allocate snapshots or read a mutable source twice.
      _snapshots[snapshotKey] = snapshot;
    } else if (snapshot.records == null || snapshot.nextOffset != readOffset) {
      throw const _LanHttpError(409);
    }
    try {
      check();
      await onChanges(peer.id, incoming);
      check();
      if (creating) {
        final source = await onReadChanges(peer.id);
        check();
        if (!identical(_snapshots[snapshotKey], snapshot)) {
          throw const _LanHttpError(409);
        }
        final frozen = _freezeRecords(
          source,
          maxBytes: min(
            _maxSnapshotBytes,
            _maxSnapshotTotalBytes - _snapshotBytes,
          ),
        );
        snapshot.records = frozen.records;
        snapshot.bytes = frozen.bytes;
        _snapshotBytes += frozen.bytes;
      }
      if (!identical(_snapshots[snapshotKey], snapshot)) {
        throw const _LanHttpError(409);
      }
      final records = snapshot.records!;
      final batch = _batch(records, readOffset);
      final hasMore = batch.nextOffset < records.length;
      snapshot.nextOffset = batch.nextOffset;
      snapshot.expiresAt = DateTime.now().add(_snapshotLifetime);
      final response = await _seal(peer, 'sync-response', senderBoot, {
        'changes': batch.records,
        'nextOffset': batch.nextOffset,
        'hasMore': hasMore,
        'replyTo': envelope['nonce'],
      }, key: key);
      check();
      // Keep a completed read cursor while the other direction is still
      // uploading. Both directions finishing releases the snapshot at once.
      if (!hasMore && !hasMoreOutgoing) _dropSnapshot(snapshotKey, snapshot);
      return response;
    } catch (_) {
      _dropSnapshot(snapshotKey, snapshot);
      rethrow;
    }
  }

  void _dropSnapshot(String key, _OutgoingSnapshot snapshot) {
    if (!identical(_snapshots[key], snapshot)) return;
    _snapshots.remove(key);
    _snapshotBytes -= snapshot.bytes;
  }

  void _pruneSnapshots() {
    final now = DateTime.now();
    for (final entry in _snapshots.entries.toList()) {
      if (entry.value.expiresAt.isBefore(now)) {
        _dropSnapshot(entry.key, entry.value);
      }
    }
  }

  Future<LanPairing> _makePairing(
    String id,
    LanSyncDevice peer,
    String initiatorChallenge,
    String responderChallenge,
    String remoteBoot,
  ) async {
    final key = await _sharedKey(
      peer,
      'pair:$id:$initiatorChallenge:$responderChallenge',
    );
    // Derive the comparison code independently of the encryption key bytes.
    final bytes = (await Hmac.sha256().calculateMac(
      utf8.encode('video-player-progress/v1/comparison-code'),
      secretKey: key,
    )).bytes;
    final number =
        ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) %
        1000000;
    return LanPairing._(
      id: id,
      peer: peer,
      code: number.toString().padLeft(6, '0'),
      expiresAt: DateTime.now().add(_pairLifetime),
      key: key,
      remoteBoot: remoteBoot,
    );
  }

  Future<void> _commitPair(LanPairing pairing) async {
    if (!pairing.localApproved ||
        !pairing.remoteApproved ||
        pairing._complete ||
        pairing._persisting) {
      return;
    }
    pairing._persisting = true;
    final previous = _trusted[pairing.peer.id];
    _trusted[pairing.peer.id] = pairing.peer.publicKeyBase64;
    try {
      await onTrustChanged(Map.unmodifiable(_trusted));
      pairing._complete = true;
      for (final other in _pairings.values) {
        if (other.peer.id == pairing.peer.id &&
            other.peer.publicKeyBase64 == pairing.peer.publicKeyBase64) {
          other._complete = true;
        }
      }
      _connected.add(pairing.peer.id);
      _errors.remove(pairing.peer.id);
    } catch (_) {
      if (previous == null) {
        _trusted.remove(pairing.peer.id);
      } else {
        _trusted[pairing.peer.id] = previous;
      }
      rethrow;
    } finally {
      pairing._persisting = false;
      _notify();
    }
  }

  Future<void> _exchangePairStatus(LanPairing pairing) async {
    if (pairing.expiresAt.isBefore(DateTime.now())) return;
    final envelope = await _seal(
      pairing.peer,
      'pair:${pairing.id}',
      pairing.remoteBoot,
      {'approved': pairing.localApproved},
      key: pairing.key,
    );
    final response = await _request(
      pairing.peer.host,
      pairing.peer.port,
      '/v1/pair/status',
      {'pairId': pairing.id, ...envelope},
    );
    final plain = await _open(
      pairing.peer,
      'pair-response:${pairing.id}',
      response,
      key: pairing.key,
      expectedSenderBoot: pairing.remoteBoot,
    );
    if (plain['replyTo'] != envelope['nonce']) {
      throw StateError('Unrelated pairing response');
    }
    pairing.remoteApproved |= plain['approved'] == true;
    await _commitPair(pairing);
    _notify();
  }

  Future<void> _maintain() async {
    if (_polling || _server == null) return;
    _polling = true;
    try {
      final now = DateTime.now();
      _pruneSnapshots();
      if (_lastDiscovery == null ||
          now.difference(_lastDiscovery!) >= const Duration(seconds: 15)) {
        await discover();
      }
      final removed = _pairings.length;
      _pairings.removeWhere((_, value) => value.expiresAt.isBefore(now));
      if (_pairings.length != removed) _notify();
      for (final pairing in _pairings.values.toList()) {
        if (pairing._complete) continue;
        try {
          await _exchangePairStatus(pairing);
        } catch (_) {
          // Temporary disappearance is retried until the pairing expires.
        }
      }
      final previousNearbyCount = _nearby.length;
      _nearby.removeWhere((id, device) {
        final expired = now.difference(device.lastSeen).inMinutes >= 2;
        if (expired) _connected.remove(id);
        return expired;
      });
      if (previousNearbyCount != _nearby.length) _notify();
    } finally {
      _polling = false;
    }
  }

  Future<SecretKey> _sharedKey(LanSyncDevice peer, String purpose) async {
    _requireStarted();
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: SimplePublicKey(
        base64Decode(peer.publicKeyBase64),
        type: KeyPairType.x25519,
      ),
    );
    if ((await shared.extractBytes()).every((byte) => byte == 0)) {
      throw StateError('Invalid peer public key');
    }
    final identities = [
      '$deviceId:$_publicKey',
      '${peer.id}:${peer.publicKeyBase64}',
    ]..sort();
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode(jsonEncode(identities)),
      info: utf8.encode('video-player-progress/v2/$_edition/$purpose'),
    );
  }

  Future<Map<String, dynamic>> _seal(
    LanSyncDevice peer,
    String scope,
    String receiverBoot,
    Map<String, dynamic> plain, {
    required SecretKey key,
  }) async {
    final nonce = _cipher.newNonce();
    final header = <String, dynamic>{
      'v': 1,
      'edition': _edition,
      'from': deviceId,
      'to': peer.id,
      'scope': scope,
      'senderBoot': _boot,
      'receiverBoot': receiverBoot,
      'nonce': base64Encode(nonce),
      'sequence': ++_sendSequence,
    };
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(jsonEncode(header)),
    );
    return {
      ...header,
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> _open(
    LanSyncDevice peer,
    String scope,
    Map<String, dynamic> envelope, {
    required SecretKey key,
    String? expectedSenderBoot,
  }) async {
    if (envelope['v'] != 1 ||
        envelope['edition'] != _edition ||
        envelope['from'] != peer.id ||
        envelope['to'] != deviceId ||
        envelope['scope'] != scope ||
        envelope['receiverBoot'] != _boot) {
      throw const _LanHttpError(403);
    }
    final nonce = base64Decode(_token(envelope['nonce'], 12));
    final senderBoot = _token(envelope['senderBoot'], 24);
    final sequence = envelope['sequence'];
    if ((expectedSenderBoot != null && senderBoot != expectedSenderBoot) ||
        sequence is! int ||
        sequence <= 0 ||
        sequence > 9007199254740991) {
      throw const _LanHttpError(403);
    }
    final replayKey = '${peer.id}:$senderBoot';
    final header = {
      'v': 1,
      'edition': _edition,
      'from': envelope['from'],
      'to': deviceId,
      'scope': scope,
      'senderBoot': envelope['senderBoot'],
      'receiverBoot': _boot,
      'nonce': envelope['nonce'],
      'sequence': sequence,
    };
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['ciphertext'] as String),
        nonce: nonce,
        mac: Mac(base64Decode(_token(envelope['mac'], 16))),
      ),
      secretKey: key,
      aad: utf8.encode(jsonEncode(header)),
    );
    // Only authenticated messages can create or advance replay state. The
    // sliding window permits parallel responses without accumulating a nonce
    // for every page over a long-running desktop session. Old sequence numbers
    // remain rejected even after their individual entries leave the window.
    if (!_received.containsKey(replayKey) && _received.length >= 1024) {
      throw const _LanHttpError(429);
    }
    final window = _received.putIfAbsent(replayKey, _ReplayWindow.new);
    if (!window.accept(sequence)) throw const _LanHttpError(409);
    return _object(jsonDecode(utf8.decode(plain)));
  }

  Map<String, dynamic> _hello() => {
    'v': 1,
    'edition': _edition,
    'id': deviceId,
    'name': deviceName.length > 80 ? deviceName.substring(0, 80) : deviceName,
    'port': port,
    'publicKey': _publicKey,
    'boot': _boot,
  };

  LanSyncDevice _device(Map<String, dynamic> data, String host) {
    final id = data['id'];
    final name = data['name'];
    final port = data['port'];
    if (data['v'] != 1 ||
        data['edition'] != _edition ||
        id is! String ||
        !RegExp(r'^[A-Za-z0-9_.:\-]{1,100}$').hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        name.length > 80 ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('Invalid device');
    }
    return LanSyncDevice(
      id: id,
      name: name,
      host: host,
      port: port,
      lastSeen: DateTime.now(),
      publicKeyBase64: _token(data['publicKey'], 32),
    );
  }

  void _remember(LanSyncDevice peer) {
    if (peer.id == deviceId || peer.publicKeyBase64 == _publicKey) return;
    _validateTrust(peer);
    if (_nearby.values.any(
      (other) =>
          other.id != peer.id &&
          _connected.contains(other.id) &&
          _trusted.containsKey(other.id) &&
          other.host == peer.host &&
          other.port == peer.port,
    )) {
      return;
    }
    // Discovery may arrive through several interfaces, and a stale process can
    // advertise another ID for the same identity. Never show it as a new device.
    if (_trusted.entries.any(
      (entry) => entry.key != peer.id && entry.value == peer.publicKeyBase64,
    )) {
      return;
    }
    final duplicateIds = _nearby.values
        .where(
          (other) =>
              other.id != peer.id &&
              (other.publicKeyBase64 == peer.publicKeyBase64 ||
                  (other.host == peer.host &&
                      other.port == peer.port &&
                      !_trusted.containsKey(other.id))),
        )
        .map((other) => other.id)
        .toList();
    for (final id in duplicateIds) {
      _nearby.remove(id);
    }
    if (_nearby.length >= 64 && !_nearby.containsKey(peer.id)) return;
    final previous = _nearby[peer.id];
    _nearby[peer.id] = peer;
    if (duplicateIds.isEmpty &&
        previous?.name == peer.name &&
        previous?.host == peer.host &&
        previous?.port == peer.port &&
        previous?.publicKeyBase64 == peer.publicKeyBase64) {
      return;
    }
    _notify();
  }

  void _validateTrust(LanSyncDevice peer) {
    final trustedKey = _trusted[peer.id];
    if (trustedKey != null && trustedKey != peer.publicKeyBase64) {
      _errors[peer.id] = 'identityChanged';
      _notify();
      throw StateError('Peer identity changed');
    }
  }

  LanPairing _activePair(String id) {
    final pairing = _pairings[id];
    if (pairing == null || pairing.expiresAt.isBefore(DateTime.now())) {
      throw StateError('Pairing expired');
    }
    return pairing;
  }

  Future<Map<String, dynamic>> _request(
    String host,
    int port,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final address = await _resolveLocal(host);
    final client = HttpClient()..connectionTimeout = _timeout;
    client.findProxy = (_) => 'DIRECT';
    try {
      final uri = Uri(scheme: 'http', host: address, port: port, path: path);
      final request = await client
          .openUrl(body == null ? 'GET' : 'POST', uri)
          .timeout(_timeout);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        if (bytes.length > _maxBodyBytes) throw StateError('Sync too large');
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('LAN request rejected: ${response.statusCode}');
      }
      return await _readJson(response);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _readJson(
    Stream<List<int>> stream,
  ) async {
    final bytes = <int>[];
    final completer = Completer<Map<String, dynamic>>();
    final subscription = stream.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (bytes.length + chunk.length > _maxBodyBytes) {
          completer.completeError(const _LanHttpError(413));
        } else {
          bytes.addAll(chunk);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: () {
        if (completer.isCompleted) return;
        try {
          completer.complete(_object(jsonDecode(utf8.decode(bytes))));
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    try {
      return await completer.future.timeout(_timeout);
    } finally {
      await subscription.cancel();
    }
  }

  static Future<void> _respond(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final encoded = utf8.encode(jsonEncode(body));
    if (encoded.length > _maxBodyBytes) throw const _LanHttpError(413);
    request.response.headers.contentType = ContentType.json;
    request.response.contentLength = encoded.length;
    request.response.add(encoded);
    await request.response.close().timeout(_timeout);
  }

  static Future<String> _resolveLocal(String host) async {
    final parsed = InternetAddress.tryParse(host);
    final addresses = parsed != null
        ? [parsed]
        : await InternetAddress.lookup(host).timeout(_timeout);
    for (final address in addresses) {
      if (_isLocal(address)) return address.address;
    }
    throw const FormatException('Use a local network address');
  }

  static bool _isLocal(InternetAddress? address) {
    if (address == null) return false;
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }
    return bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc;
  }

  static List<Map<String, dynamic>> _changes(dynamic value) {
    if (value is! List ||
        value.length > _maxBatchRecords ||
        utf8.encode(jsonEncode(value)).length > _maxBatchBytes) {
      throw const FormatException('Invalid change set');
    }
    return value.map(_object).toList(growable: false);
  }

  static int _offset(dynamic value) {
    if (value is! int ||
        value < 0 ||
        value > _maxSyncPages * _maxBatchRecords) {
      throw const FormatException('Invalid sync offset');
    }
    return value;
  }

  static _SyncBatch _batch(List<Map<String, dynamic>> records, int offset) {
    final result = <Map<String, dynamic>>[];
    var bytes = 2; // JSON array brackets.
    var index = min(offset, records.length);
    while (index < records.length && result.length < _maxBatchRecords) {
      final record = records[index];
      final size = utf8.encode(jsonEncode(record)).length;
      if (size + 2 > _maxBatchBytes) {
        throw StateError('A sync record exceeds the batch size limit');
      }
      final separator = result.isEmpty ? 0 : 1;
      if (bytes + size + separator > _maxBatchBytes) break;
      result.add(record);
      bytes += size + separator;
      index++;
    }
    return _SyncBatch(result, index);
  }

  static _FrozenRecords _freezeRecords(
    List<Map<String, dynamic>> source, {
    int maxBytes = _maxSnapshotBytes,
  }) {
    final records = <Map<String, dynamic>>[];
    var bytes = 2;
    if (source.length > _maxSyncPages * _maxBatchRecords) {
      throw const _LanHttpError(413);
    }
    for (final record in source) {
      final encoded = jsonEncode(record);
      final size = utf8.encode(encoded).length;
      if (size + 2 > _maxBatchBytes) throw const _LanHttpError(413);
      bytes += size + (records.isEmpty ? 0 : 1);
      if (bytes > maxBytes) throw const _LanHttpError(413);
      // Deep copy: callbacks may mutate maps as well as list membership while
      // incoming progress is merged between pages of this same sync pass.
      records.add(_object(jsonDecode(encoded)));
    }
    if (bytes > maxBytes) throw const _LanHttpError(413);
    return _FrozenRecords(records, bytes);
  }

  static Map<String, dynamic> _object(dynamic value) {
    if (value is! Map) throw const FormatException('Expected object');
    return Map<String, dynamic>.from(value);
  }

  static String _controlMethod(dynamic value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,79}$').hasMatch(value)) {
      throw const FormatException('Invalid control method');
    }
    return value;
  }

  static String _token(dynamic value, int bytes) {
    if (value is! String || value.length > bytes * 2 + 8) {
      throw const FormatException('Invalid token');
    }
    if (base64Decode(value).length != bytes) {
      throw const FormatException('Invalid token');
    }
    return value;
  }

  static String _randomToken(int length) =>
      base64Encode(List<int>.generate(length, (_) => _random.nextInt(256)));

  void _requirePeer(LanSyncDevice peer, int lifecycle, int trust) {
    _requireStarted();
    if (_lifecycle != lifecycle ||
        (_trustGeneration[peer.id] ?? 0) != trust ||
        _trusted[peer.id] != peer.publicKeyBase64) {
      throw StateError('Peer authorization has changed');
    }
  }

  void _requireStarted() {
    if (_server == null || _keyPair == null) {
      throw StateError('LAN transport is not running');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

class _LanHttpError implements Exception {
  const _LanHttpError(this.status);
  final int status;
}

class _SyncBatch {
  const _SyncBatch(this.records, this.nextOffset);
  final List<Map<String, dynamic>> records;
  final int nextOffset;
}

class _ReplayWindow {
  int _highest = 0;
  final Set<int> _seen = {};
  bool accept(int sequence) {
    if (sequence <= _highest - 4096 || !_seen.add(sequence)) return false;
    if (sequence > _highest) {
      _highest = sequence;
      _seen.removeWhere((value) => value <= _highest - 4096);
    }
    return true;
  }
}

class _OutgoingSnapshot {
  _OutgoingSnapshot({required this.peerId, required this.expiresAt});
  final String peerId;
  DateTime expiresAt;
  List<Map<String, dynamic>>? records;
  int bytes = 0;
  int nextOffset = 0;
}

class _FrozenRecords {
  const _FrozenRecords(this.records, this.bytes);
  final List<Map<String, dynamic>> records;
  final int bytes;
}
