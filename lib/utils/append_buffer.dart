import 'dart:collection';

/// Immutable length-bounded views over pages whose existing slots never change.
class AppendBuffer<T> {
  AppendBuffer();
  factory AppendBuffer.fromPrefix(
    List<T> prefix,
    int length, {
    bool shareImmutablePrefix = false,
  }) {
    RangeError.checkValueInInterval(length, 0, prefix.length, 'length');
    final result = AppendBuffer<T>();
    if (prefix is AppendSnapshot<T>) {
      final inherited = prefix.owner._prefixLength;
      result._prefix = prefix.owner._prefix;
      result._prefixLength = length < inherited ? length : inherited;
      final tailLength = length - result._prefixLength;
      final full = tailLength ~/ _size;
      result._pages.addAll(prefix.owner._pages.take(full));
      if (tailLength % _size != 0) {
        result._pages.add(
          prefix.owner._pages[full].take(tailLength % _size).toList(),
        );
      }
      result._length = length;
    } else if (shareImmutablePrefix) {
      // The caller owns an immutable source (for example an ArticleLayout).
      // Borrow it once; later snapshots inherit the same flat prefix instead
      // of building a chain or copying all old entries on each append.
      result._prefix = prefix;
      result._prefixLength = result._length = length;
    } else {
      result.addAll(prefix.take(length));
    }
    return result;
  }
  static const _size = 128;
  final List<List<T>> _pages = [];
  List<T>? _prefix;
  int _prefixLength = 0;
  int _length = 0;
  AppendSnapshot<T> get snapshot => AppendSnapshot._(this, _length);
  void addAll(Iterable<T> items) {
    for (final item in items) {
      if ((_length - _prefixLength) % _size == 0) _pages.add([]);
      _pages.last.add(item);
      _length++;
    }
  }
}

class AppendSnapshot<T> extends ListBase<T> {
  AppendSnapshot._(this.owner, this._length);
  final AppendBuffer<T> owner;
  final int _length;
  @override
  int get length => _length;
  @override
  set length(int value) => throw UnsupportedError('Immutable append snapshot');
  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this, null, length);
    if (index < owner._prefixLength) return owner._prefix![index];
    final tailIndex = index - owner._prefixLength;
    return owner._pages[tailIndex ~/ AppendBuffer._size][tailIndex %
        AppendBuffer._size];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable append snapshot');
}
