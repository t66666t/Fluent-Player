import 'package:flutter/foundation.dart';

/// Keeps active and resumable deliveries out of the storage cleaner.
class FolderTransferStorage extends ChangeNotifier {
  FolderTransferStorage._();
  static final instance = FolderTransferStorage._();
  final Map<Object, Set<String>> _directories = {};
  final Map<Object, Set<String>> _roots = {};
  Set<String> get directories => _directories.values.expand((v) => v).toSet();
  Set<String> get sourceRoots => _roots.values.expand((v) => v).toSet();
  void update(Object owner, Set<String> directories, Set<String> sourceRoots) {
    if (setEquals(_directories[owner], directories) &&
        setEquals(_roots[owner], sourceRoots)) {
      return;
    }
    _directories[owner] = directories;
    _roots[owner] = sourceRoots;
    notifyListeners();
  }

  void remove(Object owner) {
    _directories.remove(owner);
    _roots.remove(owner);
    notifyListeners();
  }
}
