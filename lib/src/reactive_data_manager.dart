import 'dart:async';
import 'package:reactive_data_manager/src/exceptions.dart';
import 'package:reactive_data_manager/src/storage.dart';
import 'package:rxdart/rxdart.dart';

/// One in-flight fetch for a key. Every caller that joins it shares [future].
class _Fetch<T> {
  _Fetch() {
    // Callers that never await (e.g. `refresh`) must not trigger an unhandled
    // zone error; callers that do await still receive the error.
    _completer.future.ignore();
  }

  final Completer<T> _completer = Completer<T>();
  final Completer<void> _cancel = Completer<void>();

  /// Set when the result must not be written to the cache (superseded,
  /// invalidated, cleared, evicted, overwritten by `set`, or disposed).
  bool discarded = false;

  /// The fetch that replaced this one through `forceRefresh`, if any.
  _Fetch<T>? successor;

  Future<T> get future => _completer.future;

  /// Completes when this fetch is no longer wanted.
  Future<void> get signal => _cancel.future;

  void discard({_Fetch<T>? by}) {
    discarded = true;
    if (by != null && successor == null) {
      successor = by;
      // Callers of a superseded fetch must not wait for its (abandoned)
      // request: they complete with the newer result right away.
      if (!_completer.isCompleted) _completer.complete(by.future);
    }
    if (!_cancel.isCompleted) _cancel.complete();
  }

  void succeed(T value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void fail(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class _Hydration {
  late final Future<void> future;
}

/// A class that manages reactive data fetching and updating with caching and
/// optimistic updates.
///
/// The [ReactiveDataManager] class provides a way to manage data streams,
/// fetch data from a remote source, update data optimistically, and handle
/// caching. It uses [BehaviorSubject] to provide reactive streams of data
/// and tokens to supersede stale fetch and update operations.
///
/// Concurrent [getData] calls for one key join a single fetch. Results of
/// fetches that were superseded, invalidated, cleared or evicted are never
/// written to the cache.
///
/// Type parameters:
/// - [K]: The type of the key used to identify data.
/// - [T]: The type of the data being managed.
///
/// Example usage:
/// ```dart
/// final manager = ReactiveDataManager<String, MyData>(
///   fetcher: (key) async => await fetchDataFromApi(key),
///   updater: (key, data) async => await updateDataToApi(key, data),
///   maxAge: const Duration(seconds: 20),
/// );
/// ```
class ReactiveDataManager<K, T> {
  /// Create a new [ReactiveDataManager] instance.
  ///
  /// - [maxAge]: default freshness. A cached value older than this is
  ///   refetched by [getData]. `null` means cached values never expire (they
  ///   can still be [invalidate]d).
  /// - [clock]: injectable time source, for tests.
  /// - [replayErrors]: when `false`, a failed fetch is delivered only to the
  ///   listeners subscribed at that moment instead of being replayed to late
  ///   subscribers.
  /// - [errorMapper]: converts errors thrown by the fetcher into the object
  ///   delivered to stream listeners and to the future returned by [getData].
  /// - [storage]/[storageVersion]: optional persistence, see
  ///   [ReactiveStorage].
  ReactiveDataManager({
    required Future<T> Function(K key) fetcher,
    this.updater,
    this.fetchFilter,
    this.updateFilter,
    this.maxAge,
    this.clock = DateTime.now,
    this.replayErrors = true,
    this.errorMapper,
    this.storage,
    this.storageVersion = 0,
  }) : _fetcher = ((key, _) => fetcher(key));

  /// Like the default constructor, but the fetcher receives a cancellation
  /// signal: a future that completes when the fetch is superseded,
  /// invalidated, cleared or evicted. Wire it to e.g. Dio's `CancelToken`.
  ReactiveDataManager.cancellable({
    required Future<T> Function(K key, Future<void> cancel) fetcher,
    this.updater,
    this.fetchFilter,
    this.updateFilter,
    this.maxAge,
    this.clock = DateTime.now,
    this.replayErrors = true,
    this.errorMapper,
    this.storage,
    this.storageVersion = 0,
  }) : _fetcher = fetcher;

  final Future<T> Function(K key, Future<void> cancel) _fetcher;

  /// A function that updates data for a specific key.
  final Future<dynamic> Function(K key, T data)? updater;

  /// A function that filters data for a specific key.
  final T? Function(K key, T data)? fetchFilter;

  /// A function that filters [updater] results for a specific key.
  final dynamic Function(K key, dynamic result)? updateFilter;

  /// Default freshness of cached values.
  final Duration? maxAge;

  /// Time source used for [fetchedAt] and freshness checks.
  final DateTime Function() clock;

  /// Whether the last error is replayed to new stream subscribers.
  final bool replayErrors;

  /// Maps fetcher errors to the error object delivered to consumers.
  final Object Function(Object error, StackTrace stackTrace)? errorMapper;

  /// Optional persistence layer.
  final ReactiveStorage<K, T>? storage;

  /// Entries persisted with a different version are ignored and deleted.
  final int storageVersion;

  /// All data streams are stored in a map with the key as the identifier.
  final Map<K, BehaviorSubject<T?>> _dataSubjects = {};

  /// Error channels, used instead of the subjects when [replayErrors] is off.
  final Map<K, StreamController<Object>> _errorChannels = {};

  /// The cache stores the latest data for each key.
  final Map<K, T> _cache = {};

  /// When each cached value was fetched.
  final Map<K, DateTime> _fetchedAt = {};

  /// Keys whose cached value was invalidated.
  final Set<K> _stale = {};
  DateTime? _invalidatedAllAt;

  /// Active fetch operations for each key.
  final Map<K, _Fetch<T>> _activeFetches = {};

  /// Active update operations for each key.
  final Map<K, Object> _activeUpdates = {};

  final Map<K, _Hydration> _hydrations = {};
  final Set<K> _hydrated = {};
  Future<void> _storageTail = Future<void>.value();

  /// Get a stream for a specific key
  Stream<T?> getStream(K key) {
    final subject = _getSubjectForKey(key);
    if (replayErrors) return subject.stream;
    final errors = _errorChannels.putIfAbsent(
      key,
      () => StreamController<Object>.broadcast(),
    );
    return Rx.merge<T?>([subject.stream, errors.stream.cast<T?>()]);
  }

  /// A non-null stream of values for [key]. Fetches when the value is missing
  /// or stale (on every listen), skips `null` events such as the one emitted
  /// by [clearCache]. Pass `fetch: false` to only observe.
  Stream<T> watch(K key, {bool fetch = true}) {
    return Rx.defer<T?>(() {
      if (fetch) getData(key).ignore();
      return getStream(key);
    }, reusable: true)
        .where((value) => value != null)
        .cast<T>();
  }

  /// Get the current value for a specific key
  T? getCurrentValue(K key) {
    return _dataSubjects[key]?.valueOrNull;
  }

  /// When the cached value for [key] was fetched (or last [set]).
  DateTime? fetchedAt(K key) => _fetchedAt[key];

  /// Whether [key] has a cached value that is not invalidated and younger than
  /// [maxAge] (defaults to the manager's [maxAge]).
  bool isFresh(K key, {Duration? maxAge}) {
    if (!_cache.containsKey(key) || _stale.contains(key)) return false;
    final limit = maxAge ?? this.maxAge;
    if (limit == null) return true;
    final at = _fetchedAt[key];
    return at != null && clock().difference(at) < limit;
  }

  /// Fetch data safely for a specific key.
  ///
  /// - A fresh cached value is returned without touching in-flight fetches.
  /// - Otherwise the call joins the in-flight fetch for [key], or starts one.
  /// - [forceRefresh] always starts a new fetch; callers of the superseded
  ///   fetch complete with the new result.
  Future<T> getData(
    K key, {
    bool forceRefresh = false,
    Duration? maxAge,
  }) async {
    final hydration = _hydrate(key);
    if (hydration != null) await hydration;

    if (!forceRefresh) {
      if (isFresh(key, maxAge: maxAge)) {
        final value = _cache[key] as T;
        final subject = _getSubjectForKey(key);
        if (subject.hasError || !identical(subject.valueOrNull, value)) {
          subject.add(value);
        }
        return value;
      }
      final inFlight = _activeFetches[key];
      if (inFlight != null) return inFlight.future;
    }

    return _startFetch(key).future;
  }

  /// Fire-and-forget [getData] with `forceRefresh`. Errors are delivered only
  /// through the stream.
  void refresh(K key) {
    getData(key, forceRefresh: true).ignore();
  }

  _Fetch<T> _startFetch(K key) {
    final fetch = _Fetch<T>();
    _activeFetches[key]?.discard(by: fetch);
    _activeFetches[key] = fetch;
    _runFetch(key, fetch);
    return fetch;
  }

  Future<void> _runFetch(K key, _Fetch<T> fetch) async {
    T result;
    try {
      result = await _fetcher(key, fetch.signal);
    } catch (e, s) {
      final error = errorMapper?.call(e, s) ?? e;
      if (!fetch.discarded) _emitError(key, error, s);
      _finish(key, fetch);
      fetch.fail(error, s);
      return;
    }

    try {
      if (!fetch.discarded) {
        final filter = fetchFilter;
        if (filter != null) {
          final filtered = filter(key, result);
          if (filtered != null) {
            result = filtered;
          } else if (_cache[key] != null) {
            result = _cache[key] as T;
          } else {
            throw const DataFilteredException();
          }
        }
        _write(key, result);
      }
      _finish(key, fetch);
      fetch.succeed(result);
    } catch (e, s) {
      _emitError(key, e, s);
      _finish(key, fetch);
      fetch.fail(e, s);
    }
  }

  void _finish(K key, _Fetch<T> fetch) {
    if (identical(_activeFetches[key], fetch)) _activeFetches.remove(key);
  }

  /// Update data safely for a specific key.
  ///
  /// The new value is visible immediately. If the [updater] fails the previous
  /// value is restored and [OptimisticUpdateException] is thrown. An update
  /// superseded by a newer one (or by `evict`/`dispose`) still completes with
  /// its own result, but no longer touches the cache.
  Future<dynamic> updateData(K key, T newData) async {
    final token = Object();
    _activeUpdates[key] = token; // supersedes any ongoing update

    final oldData = _cache[key]; // Store the old state for rollback
    final oldFetchedAt = _fetchedAt[key];
    final oldStale = _stale.contains(key);

    // Update locally and notify listeners
    _write(key, newData);

    bool current() => identical(_activeUpdates[key], token);

    try {
      var result = await _performUpdate(
        key,
        newData,
        current,
        oldData,
        oldFetchedAt,
        oldStale,
      );
      if (updateFilter != null) {
        final filteredResult = updateFilter?.call(key, result);
        if (filteredResult != null) {
          result = filteredResult;
        } else if (oldData != null) {
          result = oldData;
        } else {
          throw const DataFilteredException();
        }
      }
      return result;
    } catch (e) {
      if (current()) _emitError(key, e);
      return Future.error(e);
    } finally {
      if (current()) _activeUpdates.remove(key);
    }
  }

  /// Perform the update and handle failures with rollback
  Future<dynamic> _performUpdate(
    K key,
    T newData,
    bool Function() current,
    T? oldData,
    DateTime? oldFetchedAt,
    bool oldStale,
  ) async {
    if (updater != null) {
      try {
        return await updater!(key, newData);
      } catch (e) {
        if (current()) {
          if (oldData != null) {
            _write(key, oldData, at: oldFetchedAt);
            if (oldStale) _stale.add(key);
          } else {
            _cache.remove(key);
            _fetchedAt.remove(key);
            _getSubjectForKey(key).add(null);
            _enqueueStorage((s) => s.delete(key));
          }
        }
        throw const OptimisticUpdateException();
      }
    }
    return Future.value();
  }

  /// Writes [value] into the cache without any updater or rollback: updates
  /// the stream synchronously and [fetchedAt]. A fetch that is in flight is
  /// discarded, so its older response never overwrites [value].
  void set(K key, T value) {
    _activeFetches.remove(key)?.discard();
    _write(key, value);
  }

  /// Replaces the cached value with `transform(current)`. A no-op when nothing
  /// is cached for [key]. Like [set] it discards an in-flight fetch, but it
  /// keeps the invalidated state of the entry.
  void patch(K key, T Function(T current) transform) {
    if (!_cache.containsKey(key)) return;
    final wasStale = _stale.contains(key);
    _activeFetches.remove(key)?.discard();
    _write(key, transform(_cache[key] as T), markFresh: !wasStale);
  }

  /// Marks [key] stale but keeps its value visible. A fetch that is in flight
  /// is discarded; the next [getData] fetches again.
  void invalidate(K key) {
    _stale.add(key);
    _activeFetches.remove(key)?.discard();
  }

  /// [invalidate] for every cached key matching [test].
  void invalidateWhere(bool Function(K key) test) {
    for (final key in _cache.keys.toList()) {
      if (test(key)) invalidate(key);
    }
  }

  /// Replaces cached values across keys. For every cached key, [transform]
  /// returns the new value, or `null` to leave it alone. Like [patch] it
  /// discards an in-flight fetch of a changed key and keeps its invalidated
  /// state. Useful for per-page caches where one item lives under several keys.
  void patchWhere(T? Function(K key, T value) transform) {
    for (final key in _cache.keys.toList()) {
      final next = transform(key, _cache[key] as T);
      if (next == null) continue;
      final wasStale = _stale.contains(key);
      _activeFetches.remove(key)?.discard();
      _write(key, next, markFresh: !wasStale);
    }
  }

  /// [invalidate] for every key.
  void invalidateAll() {
    _invalidatedAllAt = clock();
    _stale.addAll(_cache.keys);
    for (final fetch in _activeFetches.values) {
      fetch.discard();
    }
    _activeFetches.clear();
  }

  /// Runs [action] and invalidates [key] afterwards, whether it succeeded or
  /// not (a failed mutation may have been partly applied).
  Future<R> mutate<R>(
    K key,
    Future<R> Function() action, {
    bool invalidate = true,
  }) async {
    try {
      return await action();
    } finally {
      if (invalidate) this.invalidate(key);
    }
  }

  void _write(K key, T value, {DateTime? at, bool markFresh = true}) {
    _cache[key] = value;
    final fetchedAt = at ?? clock();
    _fetchedAt[key] = fetchedAt;
    if (markFresh) _stale.remove(key);
    _getSubjectForKey(key).add(value);
    _enqueueStorage((s) => s.write(
          key,
          StoredEntry<T>(value, fetchedAt, version: storageVersion),
        ));
  }

  void _emitError(K key, Object error, [StackTrace? stackTrace]) {
    if (replayErrors) {
      _getSubjectForKey(key).addError(error, stackTrace);
    } else {
      _errorChannels[key]?.addError(error, stackTrace);
    }
  }

  /// Get or create a BehaviorSubject for a specific key
  BehaviorSubject<T?> _getSubjectForKey(K key) {
    if (!_dataSubjects.containsKey(key)) {
      _dataSubjects[key] = BehaviorSubject<T?>();
    }

    return _dataSubjects[key]!;
  }

  // --- persistence ---------------------------------------------------------

  /// Storage operations run one after another, errors never escape.
  void _enqueueStorage(Future<void> Function(ReactiveStorage<K, T> s) op) {
    final s = storage;
    if (s == null) return;
    _storageTail = _storageTail.then((_) async {
      try {
        await op(s);
      } catch (_) {}
    });
  }

  Future<void>? _hydrate(K key) {
    final s = storage;
    if (s == null || _cache.containsKey(key) || _hydrated.contains(key)) {
      return null;
    }
    final existing = _hydrations[key];
    if (existing != null) return existing.future;
    final hydration = _Hydration();
    _hydrations[key] = hydration;
    hydration.future = _readStored(key, s, hydration);
    return hydration.future;
  }

  Future<void> _readStored(
    K key,
    ReactiveStorage<K, T> s,
    _Hydration hydration,
  ) async {
    StoredEntry<T>? entry;
    try {
      entry = await s.read(key);
    } catch (_) {
      entry = null;
    }
    // Evicted or cleared while reading: drop the result.
    if (!identical(_hydrations[key], hydration)) return;
    _hydrations.remove(key);
    _hydrated.add(key);
    if (entry == null) return;
    if (entry.version != storageVersion) {
      _enqueueStorage((s) => s.delete(key));
      return;
    }
    if (_cache.containsKey(key)) return;
    _cache[key] = entry.value;
    _fetchedAt[key] = entry.fetchedAt;
    final invalidatedAt = _invalidatedAllAt;
    if (invalidatedAt != null && !entry.fetchedAt.isAfter(invalidatedAt)) {
      _stale.add(key);
    }
    _getSubjectForKey(key).add(entry.value);
  }

  // --- lifecycle -----------------------------------------------------------

  /// Clear the cache. Fetches that are in flight are discarded and persisted
  /// entries are deleted.
  void clearCache() {
    for (final fetch in _activeFetches.values) {
      fetch.discard();
    }
    _activeFetches.clear();
    _cache.clear();
    _fetchedAt.clear();
    _stale.clear();
    _invalidatedAllAt = null;
    _hydrations.clear();
    _hydrated.clear();
    _enqueueStorage((s) => s.clear());
    for (final subject in _dataSubjects.values) {
      subject.add(null);
    }
  }

  /// Removes the cached value, subject, and any in-flight fetch/update for
  /// [key] entirely. A later call to [getStream] or [getData] for the same
  /// key starts completely fresh, with no replay of the old value — unlike
  /// [clearCache], which resets every key, this only affects [key]. The
  /// persisted entry is deleted too.
  void evict(K key) {
    _activeFetches.remove(key)?.discard();
    _activeUpdates.remove(key);
    _cache.remove(key);
    _fetchedAt.remove(key);
    _stale.remove(key);
    _hydrations.remove(key);
    _hydrated.remove(key);
    _enqueueStorage((s) => s.delete(key));
    _dataSubjects.remove(key)?.close();
    _errorChannels.remove(key)?.close();
  }

  /// Dispose resources
  void dispose() {
    for (final fetch in _activeFetches.values) {
      fetch.discard();
    }
    for (final subject in _dataSubjects.values) {
      subject.close();
    }
    for (final channel in _errorChannels.values) {
      channel.close();
    }
    _activeFetches.clear();
    _activeUpdates.clear();
    _dataSubjects.clear();
    _errorChannels.clear();
    _hydrations.clear();
  }
}
