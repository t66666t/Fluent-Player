import 'dart:collection';

/// Indexable transcript data whose normalization follows the visible rows.
/// Appending cues keeps the already computed prefix; replacing a track creates
/// a new cache so selection and copy always use the current text.
class TranscriptTextCache<T extends Object> extends ListBase<T> {
  TranscriptTextCache({required int length, required T Function(int) resolve})
    : _length = length,
      _resolve = resolve;

  int _length;
  final T Function(int) _resolve;
  final Map<int, T> _values = {};

  void extendTo(int length) {
    if (length < _length) throw ArgumentError.value(length, 'length');
    _length = length;
  }

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('Read-only transcript cache');

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _values.putIfAbsent(index, () => _resolve(index));
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Read-only transcript cache');
}
