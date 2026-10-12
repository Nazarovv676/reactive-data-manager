/// A persisted cache entry: the value together with the moment it was fetched.
class StoredEntry<T> {
  /// Creates a stored entry.
  ///
  /// [version] is the `storageVersion` of the manager that wrote the entry.
  /// Adapters that cannot persist it may leave it at `0`; entries whose version
  /// differs from the manager's `storageVersion` are ignored and deleted.
  const StoredEntry(this.value, this.fetchedAt, {this.version = 0});

  /// The cached value.
  final T value;

  /// When [value] was originally fetched. Freshness (`maxAge`) is evaluated
  /// against this moment, so it survives app restarts.
  final DateTime fetchedAt;

  /// Schema version the entry was written with.
  final int version;
}

/// A pluggable persistence layer for `ReactiveDataManager`.
///
/// Serialization is the adapter's job. Any exception thrown by an adapter
/// (including a corrupt or undecodable entry) is swallowed by the manager: the
/// entry is treated as missing and the manager keeps working from memory.
abstract interface class ReactiveStorage<K, T> {
  /// Reads the entry for [key], or `null` when there is none.
  Future<StoredEntry<T>?> read(K key);

  /// Writes (or replaces) the entry for [key].
  Future<void> write(K key, StoredEntry<T> entry);

  /// Deletes the entry for [key].
  Future<void> delete(K key);

  /// Deletes every entry.
  Future<void> clear();
}

/// A [ReactiveStorage] that keeps entries in memory. Useful for tests.
class InMemoryReactiveStorage<K, T> implements ReactiveStorage<K, T> {
  /// The stored entries, exposed for assertions in tests.
  final Map<K, StoredEntry<T>> entries = {};

  @override
  Future<StoredEntry<T>?> read(K key) async => entries[key];

  @override
  Future<void> write(K key, StoredEntry<T> entry) async {
    entries[key] = entry;
  }

  @override
  Future<void> delete(K key) async {
    entries.remove(key);
  }

  @override
  Future<void> clear() async {
    entries.clear();
  }
}
