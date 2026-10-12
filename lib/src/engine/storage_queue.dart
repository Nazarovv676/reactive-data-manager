import 'dart:async';

import 'package:reactive_data_manager/src/storage.dart';

/// Storage plumbing shared by the managers. Writes, deletes and clears run one
/// after another; adapter errors never escape. Every method is a no-op (or
/// reads `null`) without a [storage].
class StorageQueue<K, V> {
  /// Creates a queue over [storage]; entries are written with [version].
  StorageQueue(this.storage, this.version);

  /// The adapter, if persistence is enabled.
  final ReactiveStorage<K, V>? storage;

  /// The schema version entries are written and accepted with.
  final int version;

  Future<void> _tail = Future<void>.value();

  /// Persists [value] for [key].
  void write(K key, V value, DateTime fetchedAt) => _enqueue(
        (s) => s.write(key, StoredEntry<V>(value, fetchedAt, version: version)),
      );

  /// Deletes the entry for [key].
  void delete(K key) => _enqueue((s) => s.delete(key));

  /// Deletes every entry.
  void clear() => _enqueue((s) => s.clear());

  /// Reads the entry for [key]; a failing adapter reads as `null`.
  Future<StoredEntry<V>?> read(K key) async {
    final s = storage;
    if (s == null) return null;
    try {
      return await s.read(key);
    } catch (_) {
      return null;
    }
  }

  /// Whether [entry] was written with [version]. Otherwise it is deleted.
  bool accept(K key, StoredEntry<V> entry) {
    if (entry.version == version) return true;
    delete(key);
    return false;
  }

  void _enqueue(Future<void> Function(ReactiveStorage<K, V> s) op) {
    final s = storage;
    if (s == null) return;
    _tail = _tail.then((_) async {
      try {
        await op(s);
      } catch (_) {}
    });
  }
}
