import 'dart:async';

/// Watch bookkeeping of one cache entry. Managers extend it with their data.
class RegistryEntry {
  int _watchers = 0;
  int _lastUnwatched = 0;
  Timer? _evictTimer;

  /// How many listeners are subscribed.
  int get watchers => _watchers;

  void _cancelTimer() {
    _evictTimer?.cancel();
    _evictTimer = null;
  }
}

/// Per-key entries with ref-counted watching and automatic eviction of
/// unwatched entries: [maxEntries] keeps the most recently watched ones (LRU)
/// and [evictAfterUnwatched] evicts an entry that stayed unwatched that long.
///
/// Eviction calls [onEvict]; the manager decides what it means (typically it
/// resets the entry and [remove]s it).
class EntryRegistry<K, E extends RegistryEntry> {
  /// Creates a registry.
  EntryRegistry({
    required this.onEvict,
    this.maxEntries,
    this.evictAfterUnwatched,
  });

  /// Called for an entry chosen for eviction.
  final void Function(K key, E entry) onEvict;

  /// Maximum number of unwatched entries.
  final int? maxEntries;

  /// How long an entry may stay unwatched.
  final Duration? evictAfterUnwatched;

  final Map<K, E> _entries = {};
  int _tick = 0;

  /// The entry for [key], if any.
  E? operator [](K key) => _entries[key];

  /// Registers [entry] for [key].
  void operator []=(K key, E entry) => _entries[key] = entry;

  /// The keys, in insertion order.
  Iterable<K> get keys => _entries.keys;

  /// A copy of the entries, safe to iterate while entries are removed.
  List<MapEntry<K, E>> snapshot() => _entries.entries.toList();

  /// Whether [entry] is still the one registered for [key].
  bool isCurrent(K key, E entry) => identical(_entries[key], entry);

  /// Cancels the eviction timer of [entry] and unregisters it if it is still
  /// the current entry of [key].
  void remove(K key, E entry) {
    entry._cancelTimer();
    if (isCurrent(key, entry)) _entries.remove(key);
  }

  /// Cancels the eviction timer of [entry], keeping it registered.
  void cancelEviction(E entry) => entry._cancelTimer();

  /// Cancels every timer and forgets every entry.
  void clear() {
    for (final entry in _entries.values) {
      entry._cancelTimer();
    }
    _entries.clear();
  }

  /// A listener subscribed to [entry]: it is no longer evictable.
  void watch(E entry) {
    entry._watchers++;
    entry._cancelTimer();
  }

  /// A listener left [entry]. Returns whether it has none left; the caller
  /// then calls [unwatched].
  bool unwatch(E entry) => --entry._watchers == 0;

  /// [entry] has no listeners from now on: it becomes the most recently
  /// unwatched entry, its eviction timer starts, and the least recently
  /// watched entries over [maxEntries] are evicted.
  void unwatched(K key, E entry) {
    touch(key, entry);
    _enforceMaxEntries();
  }

  /// [entry] was used without being watched: it becomes the most recently
  /// unwatched entry and its eviction timer restarts. Unlike [unwatched] it
  /// does not enforce [maxEntries]: the touched entry is the newest, so it
  /// cannot be the one evicted. A no-op while watched or once replaced.
  void touch(K key, E entry) {
    if (entry._watchers != 0 || !isCurrent(key, entry)) return;
    entry._lastUnwatched = ++_tick;
    entry._cancelTimer();
    final after = evictAfterUnwatched;
    if (after != null) {
      entry._evictTimer = Timer(after, () {
        if (entry._watchers == 0 && isCurrent(key, entry)) onEvict(key, entry);
      });
    }
  }

  void _enforceMaxEntries() {
    final limit = maxEntries;
    if (limit == null) return;
    while (true) {
      final unwatched = _entries.entries
          .where((x) => x.value._watchers == 0)
          .toList()
        ..sort(
          (a, b) => a.value._lastUnwatched.compareTo(b.value._lastUnwatched),
        );
      if (unwatched.length <= limit) return;
      onEvict(unwatched.first.key, unwatched.first.value);
    }
  }
}
