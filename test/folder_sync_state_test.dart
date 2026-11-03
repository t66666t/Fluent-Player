import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_state.dart';

const _keyA =
    'sha256:10:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _keyB =
    'sha256:20:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
var _serial = 0;

FolderSyncState _state(
  String device, {
  FolderSyncSettings settings = const FolderSyncSettings(),
  int time = 1000,
}) => FolderSyncState(
  groupId: 'group',
  deviceId: device,
  deviceName: 'Device $device',
  settings: settings,
  newId: () => 'generated-${++_serial}',
  nowMs: () => time,
);

List<FolderSyncLocalEntry> _snapshot({
  String name = 'Movie',
  String parent = 'folder1',
  String key = _keyA,
  int size = 10,
  String extension = '.mp4',
}) => [
  const FolderSyncLocalEntry(
    localId: 'root',
    kind: FolderSyncNodeKind.folder,
    name: 'Library',
  ),
  const FolderSyncLocalEntry(
    localId: 'folder1',
    parentLocalId: 'root',
    kind: FolderSyncNodeKind.folder,
    name: 'First',
  ),
  const FolderSyncLocalEntry(
    localId: 'folder2',
    parentLocalId: 'root',
    kind: FolderSyncNodeKind.folder,
    name: 'Second',
  ),
  FolderSyncLocalEntry(
    localId: 'video',
    parentLocalId: parent,
    kind: FolderSyncNodeKind.media,
    name: name,
    contentKey: key,
    size: size,
    extension: extension,
  ),
];

void _seed(FolderSyncState state) {
  for (final entry in _snapshot()) {
    state.bindLocal(entry.localId, entry.localId);
  }
  expect(state.capture(_snapshot()), hasLength(4));
}

void _applyAll(FolderSyncState target, FolderSyncState source) {
  target.mergeAll(source.events);
  for (final node in target.safeNodes.values) {
    target.markApplied(node.id, localId: node.id);
  }
}

FolderSyncState _restart(FolderSyncState state) => FolderSyncState.fromJson(
  jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
  deviceId: state.deviceId,
  newId: () => 'restarted-${++_serial}',
);

FolderSyncNode _folder(String id, {String? parent, String? name}) =>
    FolderSyncNode(
      id: id,
      parentId: parent,
      kind: FolderSyncNodeKind.folder,
      name: name ?? id,
    );

FolderSyncEvent _event(
  String id,
  FolderSyncNode node, {
  String device = 'A',
  Map<String, int> clock = const {'A': 1},
  bool deleted = false,
  int time = 0,
}) => FolderSyncEvent(
  id: id,
  groupId: 'group',
  deviceId: device,
  clock: clock,
  node: node,
  deleted: deleted,
  createdAtMs: time,
);

void main() {
  group('settings and wire validation', () {
    test('safe defaults and nullable settings round trip', () {
      const settings = FolderSyncSettings();
      expect(settings.mode, FolderSyncMode.smart);
      expect(settings.syncDeletes, isFalse);
      expect(settings.includeSidecars, isTrue);
      expect(settings.shareProgressForSameContent, isFalse);
      expect(settings.minFreeBytes, 512 * 1024 * 1024);
      expect(settings.maxAutoTransferBytes, 0);
      final changed = settings.copyWith(
        mode: FolderSyncMode.oneWay,
        sourceDeviceId: 'A',
        excludedExtensions: ['.tmp'],
        excludedPatterns: ['private/**'],
        bytesPerSecondLimit: 1200,
      );
      final roundTrip = FolderSyncSettings.fromJson(changed.toJson());
      expect(roundTrip.toJson(), changed.toJson());
      expect(roundTrip.copyWith(sourceDeviceId: null).sourceDeviceId, isNull);
      expect(() => roundTrip.excludedPatterns.add('x'), throwsUnsupportedError);
      expect(() => settings.copyWith(minFreeBytes: -1), throwsFormatException);
      expect(
        () => FolderSyncSettings.fromJson({'mode': 'unknown'}),
        throwsFormatException,
      );
    });

    test(
      'logical titles allow slashes while extensions remain constrained',
      () {
        const node = FolderSyncNode(
          id: 'node',
          parentId: 'root',
          kind: FolderSyncNodeKind.media,
          name: r'AC/DC\Live',
          size: 10,
          contentKey: _keyA,
          extension: '.mp4',
        );
        node.validate();
        expect(FolderSyncNode.fromJson(node.toJson()).toJson(), node.toJson());
        expect(node.copyWith(parentId: null).parentId, isNull);
        expect(node.copyWith(contentKey: null).contentKey, isNull);
        for (final name in ['', ' ', '.', '..', 'x\u0000y', 'x\ny']) {
          expect(
            () => node.copyWith(name: name).validate(),
            throwsFormatException,
          );
        }
        for (final extension in ['mp4', '.MP4', '.a/b', '.a-b']) {
          expect(
            () => node.copyWith(extension: extension).validate(),
            throwsFormatException,
          );
        }
        expect(() => node.copyWith(size: 11).validate(), throwsFormatException);
        expect(
          () => _folder('folder').copyWith(extension: '.mp4').validate(),
          throwsFormatException,
        );
      },
    );

    test('events validate bounded clocks, identities and group ownership', () {
      final state = _state('A');
      final valid = _event('event', _folder('root'));
      final restored = FolderSyncEvent.fromJson(valid.toJson());
      expect(restored.toJson(), valid.toJson());
      final malformed = <Map<String, dynamic>>[
        {...valid.toJson(), 'clock': <String, int>{}},
        {
          ...valid.toJson(),
          'clock': {'A': 0},
        },
        {
          ...valid.toJson(),
          'clock': {'A': -1},
        },
        {
          ...valid.toJson(),
          'clock': {'A': folderSyncMaxCounter + 1},
        },
        {
          ...valid.toJson(),
          'clock': {'A': 1.5},
        },
        {...valid.toJson(), 'id': '../unsafe'},
        {
          ...valid.toJson(),
          'clock': {for (var i = 0; i < 129; i++) 'D$i': 1},
        },
      ];
      for (final json in malformed) {
        expect(() => FolderSyncEvent.fromJson(json), throwsFormatException);
      }
      final otherGroup = FolderSyncEvent.fromJson({
        ...valid.toJson(),
        'groupId': 'other',
      });
      expect(() => state.merge(otherGroup), throwsFormatException);
      expect(state.events, isEmpty);
    });

    test('setting conflict explains the actual action', () {
      final issue = FolderSyncIssue(
        groupId: 'group',
        nodeId: 'root',
        title: 'Library',
        reason: 'settingsConflict',
        choices: [],
      );
      expect(issue.message, contains('同步设置'));
    });
  });

  group('causal catalog', () {
    test('duplicate and out-of-order deliveries preserve the newest head', () {
      final a = _state('A');
      _seed(a);
      final initial = a.events;
      final renamed = a.capture(_snapshot(name: 'Renamed')).single;
      final b = _state('B');
      expect(b.merge(renamed), isTrue);
      // The old video head is already strictly superseded and need not be
      // retained merely because its ID has not previously been received.
      expect(b.mergeAll(initial.reversed), 3);
      expect(b.merge(renamed), isFalse);
      expect(b.heads('video').single.id, renamed.id);
      expect(b.safeNodes['video']!.name, 'Renamed');
      expect(b.rootNodeId, 'root');
      expect(b.issues, isEmpty);
      final forged = FolderSyncEvent.fromJson({
        ...renamed.toJson(),
        'createdAtMs': renamed.createdAtMs + 1,
      });
      expect(() => b.merge(forged), throwsFormatException);
    });

    test('rename, move and extension change preserve node identity', () {
      final state = _state('A');
      _seed(state);
      final before = state.nodeIdForLocal('video');
      final renamed = state.capture(_snapshot(name: 'AC/DC')).single;
      final moved = state
          .capture(
            _snapshot(name: 'AC/DC', parent: 'folder2', extension: '.mkv'),
          )
          .single;
      expect(moved.node.id, before);
      expect(moved.node.parentId, 'folder2');
      expect(moved.node.extension, '.mkv');
      expect(moved.descendsFrom(renamed), isTrue);
      expect(state.heads('video'), hasLength(1));
      expect(
        state.capture(
          _snapshot(name: 'AC/DC', parent: 'folder2', extension: '.mkv'),
        ),
        isEmpty,
      );
    });

    test(
      'sequential remote edit wins causally despite reversed wall clocks',
      () {
        final a = _state('A', time: 8000000000000);
        _seed(a);
        final b = _state('B', time: -8000000000000);
        _applyAll(b, a);
        final edited = b.capture(_snapshot(name: 'Newer')).single;
        final original = a.heads('video').single;
        expect(edited.createdAtMs, lessThan(original.createdAtMs));
        a.merge(edited);
        expect(a.heads('video').single.id, edited.id);
        expect(a.safeNodes['video']!.name, 'Newer');
        expect(a.issues, isEmpty);
      },
    );

    for (final kind in ['rename', 'move', 'content', 'delete']) {
      test(
        'concurrent $kind edits remain visible until explicit resolution',
        () {
          final a = _state(
            'A',
            settings: const FolderSyncSettings(syncDeletes: true),
          );
          _seed(a);
          final b = _state(
            'B',
            settings: const FolderSyncSettings(syncDeletes: true),
          );
          _applyAll(b, a);
          late FolderSyncEvent left, right;
          switch (kind) {
            case 'rename':
              left = a.capture(_snapshot(name: 'A name')).single;
              right = b.capture(_snapshot(name: 'B name')).single;
            case 'move':
              left = a.capture(_snapshot(parent: 'folder2')).single;
              right = b.capture(_snapshot(name: 'B name')).single;
            case 'content':
              left = a.capture(_snapshot(key: _keyB, size: 20)).single;
              right = b.capture(_snapshot(name: 'B name')).single;
            case 'delete':
              left = a.capture([], explicitlyDeletedLocalIds: {'video'}).single;
              right = b.capture(_snapshot(name: 'B name')).single;
          }
          a.merge(right);
          b.merge(left);
          expect(
            a.heads('video').map((e) => e.id),
            b.heads('video').map((e) => e.id),
          );
          expect(a.heads('video'), hasLength(2));
          expect(a.safeNodes.containsKey('video'), isFalse);
          final issue = a.issues.singleWhere((e) => e.nodeId == 'video');
          expect(issue.choices, hasLength(2));
          expect(issue.kind, switch (kind) {
            'rename' => FolderSyncIssueKind.renameConflict,
            'move' => FolderSyncIssueKind.moveConflict,
            'delete' => FolderSyncIssueKind.deleteConflict,
            _ => FolderSyncIssueKind.contentConflict,
          });
          final resolved = a.resolve('video', right.id);
          expect(resolved.descendsFrom(left), isTrue);
          expect(resolved.descendsFrom(right), isTrue);
          b.merge(resolved);
          expect(b.safeNodes['video']!.name, right.node.name);
          expect(b.heads('video'), hasLength(1));
          expect(b.merge(left), isFalse);
          b.markApplied('video', localId: 'video');
          expect(b.capture(_snapshot(name: right.node.name)), isEmpty);
        },
      );
    }

    test('equal concurrent meanings merge without a user conflict', () {
      final a = _state('A');
      _seed(a);
      final b = _state('B');
      _applyAll(b, a);
      final left = a.capture(_snapshot(name: 'Same')).single;
      final right = b.capture(_snapshot(name: 'Same')).single;
      a.merge(right);
      expect(a.heads('video'), hasLength(2));
      expect(a.safeNodes['video']!.name, 'Same');
      expect(a.issues, isEmpty);
      expect(a.capture(_snapshot(name: 'Same')), isEmpty);
      final next = a.capture(_snapshot(name: 'After both')).single;
      expect(next.descendsFrom(left), isTrue);
      expect(next.descendsFrom(right), isTrue);
    });

    test(
      'receiving an unapplied edit never silently overwrites its branch',
      () {
        final a = _state('A');
        _seed(a);
        final b = _state('B');
        _applyAll(b, a);
        final remote = b.capture(_snapshot(name: 'Remote')).single;
        a.merge(remote);
        final restarted = _restart(a);
        final local = restarted.capture(_snapshot(name: 'Local')).single;
        expect(local.descendsFrom(remote), isFalse);
        expect(restarted.heads('video'), hasLength(2));
        expect(restarted.issues.single.nodeId, 'video');
        expect(restarted.appliedNode('video')!.name, 'Local');
      },
    );

    test('identical content and names remain separate stable entries', () {
      final state = _state('A');
      _seed(state);
      final duplicate = FolderSyncLocalEntry(
        localId: 'second-copy',
        parentLocalId: 'folder1',
        kind: FolderSyncNodeKind.media,
        name: 'Movie',
        contentKey: _keyA,
        size: 10,
        extension: '.mp4',
      );
      expect(state.capture([..._snapshot(), duplicate]), hasLength(1));
      expect(state.nodeIdForLocal('second-copy'), isNot('video'));
      final media = state.safeNodes.values.where(
        (n) => n.kind == FolderSyncNodeKind.media,
      );
      expect(media, hasLength(2));
      expect(media.map((n) => n.contentKey).toSet(), {_keyA});
      expect(state.issues, isEmpty);
    });

    test('equal vector clocks with different data are retained safely', () {
      final state = _state('A');
      state.merge(_event('root-event', _folder('root')));
      state.merge(
        _event('fork-one', _folder('child', parent: 'root', name: 'One')),
      );
      state.merge(
        _event('fork-two', _folder('child', parent: 'root', name: 'Two')),
      );
      expect(state.heads('child'), hasLength(2));
      expect(state.safeNodes.keys, ['root']);
      expect(state.issues.single.kind, FolderSyncIssueKind.renameConflict);
    });

    test(
      'delivery permutations converge with concurrent edits and old history',
      () {
        final a = _state('A');
        _seed(a);
        final b = _state('B');
        _applyAll(b, a);
        a.capture(_snapshot(name: 'First A'));
        a.capture(_snapshot(name: 'Second A'));
        b.capture(_snapshot(parent: 'folder2'));
        final records = {
          for (final e in a.events) e.id: e,
          for (final e in b.events) e.id: e,
        };
        final random = Random(7451);
        for (var run = 0; run < 30; run++) {
          final shuffled = records.values.toList()..shuffle(random);
          final replica = _state('Replica');
          replica.mergeAll(shuffled);
          replica.mergeAll(shuffled.reversed);
          expect(replica.heads('video').map((e) => e.node.name).toSet(), {
            'Second A',
            'Movie',
          });
          expect(replica.activeEvents, hasLength(5));
          expect(replica.events.length, inInclusiveRange(5, records.length));
          expect(replica.issues.single.reason, 'concurrentMove');
          expect(replica.safeNodes.keys.toSet(), {
            'root',
            'folder1',
            'folder2',
          });
        }
      },
    );
  });

  group('missing disks, explicit deletion and local suppression', () {
    test('missing or partial scans never emit deletion', () {
      final state = _state(
        'A',
        settings: const FolderSyncSettings(syncDeletes: true),
      );
      _seed(state);
      final eventCount = state.events.length;
      expect(state.capture([]), isEmpty);
      expect(state.capture(_snapshot().take(1).toList()), isEmpty);
      expect(
        state.capture(
          [],
          available: false,
          explicitlyDeletedLocalIds: {'root'},
        ),
        isEmpty,
      );
      expect(state.events.length, eventCount);
      expect(state.safeNodes, hasLength(4));
      expect(state.suppressedNodeIds, isEmpty);
    });

    test(
      'local-only folder removal survives restart and suppresses descendants',
      () {
        final state = _state('A');
        _seed(state);
        expect(
          state.capture([], explicitlyDeletedLocalIds: {'folder1'}),
          isEmpty,
        );
        expect(state.isSuppressed('folder1'), isTrue);
        expect(state.isSuppressed('video'), isTrue);
        final restarted = _restart(state);
        expect(restarted.safeNodes, hasLength(4));
        expect(restarted.applicableNodes.keys.toSet(), {'root', 'folder2'});
        expect(
          restarted.capture(_snapshot(name: 'Hidden local change')),
          isEmpty,
        );
        for (final id in restarted.suppressedNodeIds) {
          restarted.unsuppress(id);
        }
        expect(restarted.applicableNodes, hasLength(4));
        expect(restarted.capture(_snapshot()), isEmpty);
      },
    );

    test('suppression is local and is never exchanged as remote deletion', () {
      final a = _state('A');
      _seed(a);
      final b = _state('B');
      b.mergeAll(a.events);
      a.suppress('video');
      expect(a.applicableNodes.containsKey('video'), isFalse);
      expect(b.applicableNodes.containsKey('video'), isTrue);
      expect(a.events.any((e) => e.deleted), isFalse);
    });

    test('new remote moves into a suppressed folder stay excluded locally', () {
      final a = _state('A');
      _seed(a);
      final b = _state('B');
      _applyAll(b, a);
      a.suppress('folder2');
      final remoteMove = b.capture(_snapshot(parent: 'folder2')).single;
      a.merge(remoteMove);
      expect(a.appliedNode('video')!.parentId, 'folder1');
      expect(a.safeNodes['video']!.parentId, 'folder2');
      expect(a.isSuppressed('video'), isTrue);
      expect(a.applicableNodes.containsKey('video'), isFalse);
    });

    test(
      'folder delete includes applied children but preserves unseen remote adds',
      () {
        final a = _state(
          'A',
          settings: const FolderSyncSettings(syncDeletes: true),
        );
        _seed(a);
        final remoteAdded = _event(
          'remote-added',
          const FolderSyncNode(
            id: 'unseen',
            parentId: 'folder1',
            kind: FolderSyncNodeKind.media,
            name: 'Added elsewhere',
            contentKey: _keyA,
            size: 10,
          ),
          device: 'B',
          clock: const {'B': 1},
        );
        a.merge(remoteAdded);
        final removed = a.capture([], explicitlyDeletedLocalIds: {'folder1'});
        expect(removed.map((e) => e.node.id).toSet(), {'folder1', 'video'});
        expect(a.heads('unseen').single.deleted, isFalse);
        expect(a.safeDeletedNodeIds.contains('video'), isTrue);
        expect(a.safeDeletedNodeIds.contains('folder1'), isFalse);
        expect(
          a.issues.any((e) => e.reason == 'deleteHasLiveDescendants'),
          isTrue,
        );
        expect(a.capture([], explicitlyDeletedLocalIds: {'folder1'}), isEmpty);
      },
    );

    test(
      'progress-only and one-way receiver never publish catalog changes',
      () {
        for (final settings in [
          const FolderSyncSettings(
            mode: FolderSyncMode.progressOnly,
            syncDeletes: true,
          ),
          const FolderSyncSettings(
            mode: FolderSyncMode.oneWay,
            sourceDeviceId: 'A',
            syncDeletes: true,
          ),
        ]) {
          final source = _state('A');
          _seed(source);
          final receiver = _state('B', settings: settings);
          _applyAll(receiver, source);
          expect(receiver.capture(_snapshot(name: 'Local only')), isEmpty);
          expect(
            receiver.capture([], explicitlyDeletedLocalIds: {'video'}),
            isEmpty,
          );
          expect(receiver.isSuppressed('video'), isTrue);
          expect(receiver.heads('video').single.node.name, 'Movie');
        }
        final source = _state(
          'A',
          settings: const FolderSyncSettings(
            mode: FolderSyncMode.oneWay,
            sourceDeviceId: 'A',
          ),
        );
        _seed(source);
        expect(source.capture(_snapshot(name: 'Published')), hasLength(1));
      },
    );
  });

  group('safe tree projection', () {
    test(
      'cycles, absent parents and non-folder parents are quarantined and repairable',
      () {
        final state = _state('A');
        state.mergeAll([
          _event('root-e', _folder('root')),
          _event('cycle-a', _folder('a', parent: 'b')),
          _event('cycle-b', _folder('b', parent: 'a')),
          _event('missing', _folder('lost', parent: 'absent')),
          _event(
            'media',
            const FolderSyncNode(
              id: 'media',
              parentId: 'root',
              kind: FolderSyncNodeKind.media,
              name: 'Movie',
            ),
          ),
          _event('bad-parent', _folder('child', parent: 'media')),
        ]);
        expect(state.safeNodes.keys.toSet(), {'root', 'media'});
        expect(state.issues.where((e) => e.reason == 'cycle'), hasLength(2));
        expect(state.issues.any((e) => e.reason == 'missingParent'), isTrue);
        expect(state.issues.any((e) => e.reason == 'parentNotFolder'), isTrue);
        state.merge(
          _event('repair', _folder('b', parent: 'root'), clock: const {'A': 2}),
        );
        expect(state.safeNodes.keys.toSet(), {'root', 'media', 'a', 'b'});
        expect(state.issues.any((e) => e.reason == 'cycle'), isFalse);
      },
    );

    test('ambiguous roots and media roots do not yield a usable directory', () {
      final state = _state('A');
      state.merge(_event('root-one', _folder('one')));
      state.merge(_event('root-two', _folder('two')));
      expect(state.safeNodes, isEmpty);
      expect(state.rootNodeId, isNull);
      final mediaRoot = _state('A');
      mediaRoot.merge(
        _event(
          'media-root',
          const FolderSyncNode(
            id: 'video',
            kind: FolderSyncNodeKind.media,
            name: 'Video',
          ),
        ),
      );
      expect(mediaRoot.safeNodes, isEmpty);
      expect(mediaRoot.issues.single.reason, 'rootNotFolder');
    });

    test('unsafe tombstone ancestry cannot authorize local deletion', () {
      final state = _state('A');
      state.mergeAll([
        _event('root-event', _folder('root')),
        _event(
          'orphan-delete',
          _folder('orphan', parent: 'unknown'),
          deleted: true,
        ),
        _event(
          'media-event',
          const FolderSyncNode(
            id: 'media',
            parentId: 'root',
            kind: FolderSyncNodeKind.media,
            name: 'Movie',
          ),
        ),
        _event(
          'child-delete',
          _folder('child', parent: 'media'),
          deleted: true,
        ),
        _event('cycle-del-a', _folder('a', parent: 'b'), deleted: true),
        _event('cycle-del-b', _folder('b', parent: 'a'), deleted: true),
      ]);
      expect(state.safeDeletedNodeIds, isEmpty);
      expect(state.issues.map((e) => e.nodeId).toSet(), {
        'orphan',
        'child',
        'a',
        'b',
      });
      state.merge(
        _event(
          'repair-delete',
          _folder('orphan', parent: 'root'),
          clock: const {'A': 2},
          deleted: true,
        ),
      );
      expect(state.safeDeletedNodeIds, {'orphan'});
    });

    test('oversized nesting is bounded without recursive traversal', () {
      final state = _state('A');
      final nodes = [
        for (var i = FolderSyncState.maxDepth + 3; i >= 0; i--)
          _event(
            'event-$i',
            _folder('node-$i', parent: i == 0 ? null : 'node-${i - 1}'),
          ),
      ];
      state.mergeAll(nodes);
      expect(state.safeNodes, hasLength(FolderSyncState.maxDepth + 1));
      expect(state.safeNodes.containsKey('node-257'), isFalse);
      expect(state.issues.any((e) => e.reason == 'depthLimit'), isTrue);
    });

    test('cyclic local snapshots never publish unsafe events', () {
      final state = _state('A');
      final events = state.capture(const [
        FolderSyncLocalEntry(
          localId: 'a',
          parentLocalId: 'b',
          kind: FolderSyncNodeKind.folder,
          name: 'A',
        ),
        FolderSyncLocalEntry(
          localId: 'b',
          parentLocalId: 'a',
          kind: FolderSyncNodeKind.folder,
          name: 'B',
        ),
      ]);
      expect(events, isEmpty);
      expect(state.safeNodes, isEmpty);
      expect(
        () => state.capture([_snapshot().first, _snapshot().first]),
        throwsFormatException,
      );
      expect(
        () => state.capture(
          List.filled(FolderSyncState.maxNodes + 1, _snapshot().first),
        ),
        throwsFormatException,
      );
    });

    test(
      'reverse-ordered local depth checks keep valid ancestors available',
      () {
        final state = _state('A');
        final entries = [
          for (var i = FolderSyncState.maxDepth + 3; i >= 0; i--)
            FolderSyncLocalEntry(
              localId: 'local-$i',
              parentLocalId: i == 0 ? null : 'local-${i - 1}',
              kind: FolderSyncNodeKind.folder,
              name: 'Folder $i',
            ),
        ];
        final emitted = state.capture(entries);
        expect(emitted, hasLength(FolderSyncState.maxDepth + 1));
        expect(state.safeNodes, hasLength(FolderSyncState.maxDepth + 1));
        expect(state.rootNodeId, state.nodeIdForLocal('local-0'));
      },
    );

    test(
      'projection is cached and large flat libraries keep stable identities',
      () {
        final state = _state('A');
        final entries = [
          _snapshot().first,
          for (var i = 0; i < 3000; i++)
            FolderSyncLocalEntry(
              localId: 'media-$i',
              parentLocalId: 'root',
              kind: FolderSyncNodeKind.media,
              name: 'Movie $i',
              contentKey: _keyA,
              size: 10,
              extension: '.mp4',
            ),
        ];
        final timer = Stopwatch()..start();
        expect(state.capture(entries), hasLength(3001));
        final view = state.safeNodes;
        for (var i = 0; i < 1000; i++) {
          expect(identical(view, state.safeNodes), isTrue);
        }
        expect(state.capture(entries), isEmpty);
        expect(view, hasLength(3001));
        expect(state.events, hasLength(3001));
        timer.stop();
        // A generous regression guard for accidental per-entry full projection.
        expect(timer.elapsed, lessThan(const Duration(seconds: 10)));
      },
    );
  });

  group('persistent bindings and acknowledgements', () {
    test(
      'binding remains one-to-one, requires explicit replacement and is immutable',
      () {
        final state = _state('A');
        state.bindLocal('local', 'remote');
        expect(() => state.bindLocal('other', 'remote'), throwsStateError);
        expect(() => state.bindLocal('local', 'different'), throwsStateError);
        state.bindLocal('other', 'remote', replace: true);
        expect(state.nodeIdForLocal('local'), isNull);
        expect(state.localIdForNode('remote'), 'other');
        expect(() => state.localBindings['x'] = 'y', throwsUnsupportedError);
        expect(() => state.nodeBindings['x'] = 'y', throwsUnsupportedError);
        state.unbindLocal('other', suppress: true);
        final restarted = _restart(state);
        expect(restarted.localBindings, isEmpty);
        expect(restarted.isSuppressed('remote'), isTrue);
      },
    );

    test(
      'full local state round trip retains causal baseline and acknowledgements',
      () {
        final a = _state('A');
        _seed(a);
        a.suppress('folder2');
        a.acknowledgeRemote('B', 'video');
        final restarted = _restart(a);
        expect(restarted.toJson(), a.toJson());
        expect(restarted.capture(_snapshot()), isEmpty);
        expect(restarted.appliedClock('video'), a.appliedClock('video'));
        expect(
          restarted.remoteAcknowledgement('B', 'video')!.contentKey,
          _keyA,
        );
        expect(
          () => FolderSyncState.fromJson(a.toJson(), deviceId: 'B'),
          throwsFormatException,
        );
        final malformed = a.toJson();
        malformed['appliedSignatures'] = {'video': 'forged'};
        expect(
          () => FolderSyncState.fromJson(malformed, deviceId: 'A'),
          throwsFormatException,
        );
      },
    );

    test(
      'remote acknowledgement handles stale and concurrent different metadata',
      () {
        final a = _state('A');
        _seed(a);
        final first = a.heads('video').single;
        a.acknowledgeRemote('B', 'video');
        final changed = a.capture(_snapshot(name: 'Changed')).single;
        a.acknowledgeRemote('B', 'video');
        a.acknowledgeRemote(
          'B',
          'video',
          clock: first.clock,
          contentKey: _keyA,
          metadataSignature: first.semanticSignature,
        );
        expect(
          a.remoteAcknowledgement('B', 'video')!.metadataSignature,
          changed.semanticSignature,
        );
        a.acknowledgeRemote(
          'B',
          'video',
          clock: const {'C': 1},
          contentKey: _keyB,
          metadataSignature: 'other-branch',
        );
        expect(a.remoteAcknowledgement('B', 'video'), isNull);
        final restarted = _restart(a);
        expect(restarted.remoteAcknowledgement('B', 'video'), isNull);
        restarted.acknowledgeRemote(
          'B',
          'video',
          clock: {...changed.clock, 'C': 1},
          contentKey: _keyA,
          metadataSignature: changed.semanticSignature,
        );
        expect(
          restarted.remoteAcknowledgement('B', 'video')!.metadataSignature,
          changed.semanticSignature,
        );
      },
    );
  });

  group('bounded causal history', () {
    test(
      'active events include every concurrent head and no stale ancestor',
      () {
        final a = _state('A');
        _seed(a);
        final b = _state('B');
        _applyAll(b, a);
        final stale = a.capture(_snapshot(name: 'Stale A')).single;
        final left = a.capture(_snapshot(name: 'Latest A')).single;
        final right = b.capture(_snapshot(name: 'Latest B')).single;
        a.merge(right);
        final active = a.activeEvents;
        expect(active, hasLength(5));
        expect(active.map((e) => e.id), containsAll([left.id, right.id]));
        expect(active.map((e) => e.id), isNot(contains(stale.id)));
        expect(identical(active, a.activeEvents), isTrue);
        expect(() => active.clear(), throwsUnsupportedError);
        final consumer = _state('Consumer');
        consumer.mergeAll(active.reversed);
        expect(
          consumer.heads('video').map((e) => e.id),
          a.heads('video').map((e) => e.id),
        );
        expect(consumer.issues.single.reason, 'concurrentRename');
        expect(consumer.merge(stale), isFalse);
        expect(consumer.events, hasLength(5));
      },
    );

    test(
      'compaction preserves applied branches and rejects replays after restart',
      () {
        final local = _state('A');
        _seed(local);
        final initialVideo = local.heads('video').single;
        final remote = _state('B');
        _applyAll(remote, local);
        final oldRemoteEvents = <FolderSyncEvent>[];
        for (var i = 0; i < 1200; i++) {
          oldRemoteEvents.add(
            remote.capture(_snapshot(name: 'Remote $i')).single,
          );
        }
        local.mergeAll(remote.events);
        local.suppress('folder2');
        local.acknowledgeRemote('B', 'video');
        final baseline = local.appliedClock('video');
        final bindings = local.localBindings;
        final acknowledged = local
            .remoteAcknowledgement('B', 'video')!
            .toJson();
        final projection = local.safeNodes;
        final active = local.activeEvents;
        expect(local.events, hasLength(1204));
        expect(local.compact(), 1200);
        expect(local.events, hasLength(4));
        expect(identical(local.safeNodes, projection), isTrue);
        expect(identical(local.activeEvents, active), isTrue);
        expect(local.appliedClock('video'), baseline);
        expect(local.appliedNode('video')!.name, 'Movie');
        expect(local.appliedSignature('video'), initialVideo.semanticSignature);
        expect(local.localBindings, bindings);
        expect(
          local.remoteAcknowledgement('B', 'video')!.toJson(),
          acknowledged,
        );
        expect(local.compact(), 0);

        final restarted = _restart(local);
        expect(restarted.events, hasLength(4));
        expect(restarted.safeNodes['video']!.name, 'Remote 1199');
        expect(restarted.suppressedNodeIds, {'folder2'});
        expect(restarted.appliedClock('video'), baseline);
        expect(
          restarted.remoteAcknowledgement('B', 'video')!.toJson(),
          acknowledged,
        );
        for (final stale in [initialVideo, ...oldRemoteEvents.take(1199)]) {
          expect(restarted.merge(stale), isFalse);
        }
        expect(restarted.events, hasLength(4));
        expect(restarted.activeEvents, hasLength(4));

        // An active event ID must still bind to exactly its original meaning.
        final current = restarted.heads('video').single;
        final reused = FolderSyncEvent.fromJson({
          ...current.toJson(),
          'node': current.node.copyWith(name: 'Forged').toJson(),
        });
        expect(() => restarted.merge(reused), throwsFormatException);

        // Receiving newer content did not imply that it was applied locally.
        // The preserved old baseline must still produce a concurrent local edit.
        final localEdit = restarted.capture(_snapshot(name: 'Local')).single;
        expect(localEdit.descendsFrom(current), isFalse);
        expect(restarted.heads('video'), hasLength(2));
        expect(restarted.issues.single.reason, 'concurrentRename');
      },
    );

    test(
      'explicit compaction waits until history is materially larger than heads',
      () {
        final state = _state('A');
        _seed(state);
        for (var i = 0; i < 1004; i++) {
          state.capture(_snapshot(name: 'Name $i'));
        }
        expect(state.events, hasLength(1008));
        expect(state.activeEvents, hasLength(4));
        expect(state.compact(), 0);
        state.capture(_snapshot(name: 'One more'));
        expect(state.compact(), 1005);
        expect(state.events, hasLength(4));
        expect(state.safeNodes['video']!.name, 'One more');
      },
    );

    test(
      'long history pruning preserves delete conflicts and equal-clock forks',
      () {
        final a = _state(
          'A',
          settings: const FolderSyncSettings(syncDeletes: true),
        );
        _seed(a);
        final b = _state('B');
        _applyAll(b, a);
        final initial = a.heads('video').single;
        for (var i = 0; i < 1200; i++) {
          a.capture(_snapshot(name: 'Local $i'));
        }
        final removed = a
            .capture([], explicitlyDeletedLocalIds: {'video'})
            .single;
        final edited = b.capture(_snapshot(name: 'Remote edit')).single;
        a.merge(edited);
        a.merge(
          _event(
            'equal-one',
            _folder('folder2', parent: 'root', name: 'One'),
            clock: const {'A': 3, 'C': 1},
            device: 'C',
          ),
        );
        a.merge(
          _event(
            'equal-two',
            _folder('folder2', parent: 'root', name: 'Two'),
            clock: const {'A': 3, 'C': 1},
            device: 'C',
          ),
        );
        final before = a.activeEvents.map((e) => e.id).toSet();
        expect(a.compact(), greaterThan(1000));
        expect(a.events.map((e) => e.id).toSet(), before);
        expect(a.activeEvents.map((e) => e.id).toSet(), before);
        expect(a.heads('video').map((e) => e.id).toSet(), {
          removed.id,
          edited.id,
        });
        expect(a.heads('folder2'), hasLength(2));
        expect(a.safeDeletedNodeIds.contains('video'), isFalse);
        expect(a.merge(initial), isFalse);
        final restored = _restart(a);
        expect(restored.heads('video'), hasLength(2));
        expect(restored.heads('folder2'), hasLength(2));
        expect(restored.issues.map((e) => e.kind).toSet(), {
          FolderSyncIssueKind.deleteConflict,
          FolderSyncIssueKind.renameConflict,
        });
      },
    );
  });
}
