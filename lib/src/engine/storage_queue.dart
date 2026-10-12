import 'dart:async';

import 'package:reactive_data_manager/src/storage.dart';

/// Storage plumbing shared by the managers. Writes, deletes and clears run one
/// after another, and reads run after the operations queued before them;
/// adapter errors (also synchronous throws) never escape. Every method is a
/// no-op (or reads `null`) without a [storage].
class StorageQueue<K, V> {
  /// Creates a queue over [storage]; entries are written with [version].
  /// Reads that take longer than [readTimeout] read as `null`.
  StorageQueue(this.storage, this.version, {this.readTimeout});

  /// The adapter, if persistence is enabled.
  final ReactiveStorage<K, V>? storage;

  /// The schema version entries are written and accepted with.
  final int version;

  /// The longest a [read] may take (`null`: no limit). It is measured from
  /// the [read] call, so it also covers the time spent waiting behind queued
  /// writes: a slow or stuck adapter never holds up a load. A read that times
  /// out reads as `null` (missing) and its late result is dropped; when it
  /// was still waiting in the queue, the adapter is not called at all.
  final Duration? readTimeout;

  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  /// After this every method is a no-op (reads `null`). Operations queued
  /// before still run.
  void close() => _closed = true;

  /// Persists [value] for [key].
  void write(K key, V value, DateTime fetchedAt) => _enqueue(
        (s) => s.write(key, StoredEntry<V>(value, fetchedAt, version: version)),
      );

  /// Deletes the entry for [key].
  void delete(K key) => _enqueue((s) => s.delete(key));

  /// Deletes every entry.
  void clear() => _enqueue((s) => s.clear());

  /// Reads the entry for [key]; a failing adapter, or one slower than
  /// [readTimeout], reads as `null`.
  ///
  /// The read runs after every write, delete and clear queued before it, so
  /// it never sees an entry that an earlier `evict`/`clearCache` is about to
  /// delete. It does not hold up operations queued after it.
  Future<StoredEntry<V>?> read(K key) {
    final s = storage;
    if (s == null || _closed) return Future.value();
    final result = Completer<StoredEntry<V>?>();
    void complete(StoredEntry<V>? entry) {
      if (!result.isCompleted) result.complete(entry);
    }

    final limit = readTimeout;
    final timer = limit == null ? null : Timer(limit, () => complete(null));
    _tail.then((_) async {
      if (result.isCompleted) return; // timed out while queued
      try {
        complete(await s.read(key));
      } catch (_) {
        complete(null);
      } finally {
        timer?.cancel();
      }
    });
    return result.future;
  }

  /// Whether [entry] was written with [version]. Otherwise it is deleted.
  bool accept(K key, StoredEntry<V> entry) {
    if (entry.version == version) return true;
    delete(key);
    return false;
  }

  void _enqueue(Future<void> Function(ReactiveStorage<K, V> s) op) {
    final s = storage;
    if (s == null || _closed) return;
    _tail = _tail.then((_) async {
      try {
        await op(s);
      } catch (_) {}
    });
  }
}
