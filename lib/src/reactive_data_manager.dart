import 'dart:async';
import 'package:reactive_data_manager/src/engine/errors.dart';
import 'package:reactive_data_manager/src/engine/freshness.dart';
import 'package:reactive_data_manager/src/engine/operation.dart';
import 'package:reactive_data_manager/src/engine/storage_queue.dart';
import 'package:reactive_data_manager/src/exceptions.dart';
import 'package:reactive_data_manager/src/storage.dart';
import 'package:rxdart/rxdart.dart';

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
  /// - [storageReadTimeout]: the longest a storage read may take (`null`, the
  ///   default: no limit). A slower read counts as "nothing persisted" (the
  ///   value is fetched; the late result is dropped), so a slow or stuck
  ///   adapter never blocks [getData]. Measured from the read request, so it
  ///   includes the wait behind storage writes queued before it.
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
    this.storageReadTimeout,
  }) : _fetcher = ((key, _) => fetcher(key));

  /// Like the default constructor, but the fetcher receives a cancellation
  /// signal: a future that completes when the fetch is superseded (by
  /// `forceRefresh`/[refresh]), or its key is [evict]ed, [clearCache]d or the
  /// manager is [dispose]d. Wire it to e.g. Dio's `CancelToken`.
  ///
  /// - Superseded: waiting callers complete with the newer fetch's result.
  /// - Evicted/cleared/disposed: waiting callers complete with the fetcher's
  ///   own outcome, i.e. the fetcher's cancellation error if it honours the
  ///   signal.
  /// - [invalidate], [set], [patch] (and their `Where`/`All` variants) do
  ///   *not* fire the signal: the request finishes, waiting callers receive
  ///   its result, and the result is not cached.
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
    this.storageReadTimeout,
  }) : _fetcher = fetcher;

  final Future<T> Function(K key, Future<void> cancel) _fetcher;

  /// The fetcher, called directly: bypasses the cache, in-flight joining and
  /// the stream. For a [ReactiveDataManager.cancellable] fetcher the cancel
  /// signal never fires.
  @Deprecated(
    'Kept for 1.1.0 compatibility; use getData(key, forceRefresh: true). '
    'Will be removed in 2.0.0.',
  )
  Future<T> Function(K key) get fetcher =>
      (key) => _fetcher(key, Completer<void>().future);

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

  /// The longest a storage read may take before it counts as missing.
  final Duration? storageReadTimeout;

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

  /// [invalidateWhere] calls since the last [invalidateAll]/[clearCache],
  /// applied to keys hydrated later (only kept when [storage] is set).
  final List<(DateTime, bool Function(K))> _invalidations = [];

  /// Active fetch operations, one lane per key.
  final InFlight<K, Operation<T>> _activeFetches = InFlight();

  /// Active update operations for each key.
  final Map<K, Object> _activeUpdates = {};

  /// Sequence number of the last write per key (rollback guard).
  final Map<K, int> _writeSeq = {};
  int _writes = 0;

  final Map<K, _Hydration> _hydrations = {};

  /// Uncached keys whose storage was read and held nothing: not read again.
  final Set<K> _hydrated = {};
  late final StorageQueue<K, T> _storage =
      StorageQueue(storage, storageVersion, readTimeout: storageReadTimeout);
  late final Freshness _freshness = Freshness(clock, maxAge);

  /// Get a stream for a specific key. With [storage], a persisted value is
  /// restored into the stream when nothing is in memory (no fetch).
  Stream<T?> getStream(K key) {
    final subject = _getSubjectForKey(key);
    _hydrate(key)?.ignore();
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
    return !_freshness.isExpired(_fetchedAt[key], maxAge: maxAge);
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

  /// Fire-and-forget, non-forced [getData]: warms the cache for [key] (e.g.
  /// before navigating to a screen that shows it). Does nothing when a fresh
  /// value is cached, joins a fetch that is already in flight, otherwise
  /// starts one. Never throws; errors are delivered only through the stream.
  void prefetch(K key) {
    getData(key).ignore();
  }

  Operation<T> _startFetch(K key) {
    final fetch = Operation<T>();
    // Callers of the superseded fetch must not wait for its (abandoned)
    // request: they complete with the newer result right away.
    _activeFetches[key]?.discardWith(fetch.future);
    _activeFetches[key] = fetch;
    _runFetch(key, fetch);
    return fetch;
  }

  /// Runs [fetch]. Whatever the fetcher or a user callback (`errorMapper`,
  /// `fetchFilter`) does, the lane is released and every caller completes.
  Future<void> _runFetch(K key, Operation<T> fetch) async {
    try {
      T result;
      try {
        result = await _fetcher(key, fetch.signal.whenAborted);
      } catch (e, s) {
        final error = mapError(errorMapper, e, s);
        if (!fetch.discarded) _emitError(key, error, s);
        fetch.fail(error, s);
        return;
      }
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
      fetch.resolve(result);
    } catch (e, s) {
      if (!fetch.discarded) _emitError(key, e, s);
      fetch.fail(e, s);
    } finally {
      _finish(key, fetch);
    }
  }

  void _finish(K key, Operation<T> fetch) => _activeFetches.finish(key, fetch);

  /// Update data safely for a specific key.
  ///
  /// The new value is visible immediately. If the [updater] fails the previous
  /// value is restored and [OptimisticUpdateException] is thrown.
  ///
  /// - A fetch that started before the update is detached like by [set]: its
  ///   callers still complete with its result, but it never overwrites the
  ///   optimistic value.
  /// - The rollback happens only if nothing wrote the key since the update
  ///   started: a newer [set]/[patch], a fetch that started (and finished)
  ///   during the update, or a newer update win over the rollback.
  /// - An update superseded by a newer one (or by `evict`/`clearCache`/
  ///   `dispose`) still completes with its own result, but no longer touches
  ///   the cache or the stream.
  Future<dynamic> updateData(K key, T newData) async {
    final token = Object();
    _activeUpdates[key] = token; // supersedes any ongoing update

    final oldData = _cache[key]; // Store the old state for rollback
    final oldFetchedAt = _fetchedAt[key];
    final oldStale = _stale.contains(key);

    // An older response must not overwrite the optimistic value.
    _activeFetches.take(key)?.detach();
    // Update locally and notify listeners
    _write(key, newData);
    final written = _writeSeq[key];

    bool current() => identical(_activeUpdates[key], token);
    bool untouched() => current() && _writeSeq[key] == written;

    try {
      var result = await _performUpdate(
        key,
        newData,
        untouched,
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
    bool Function() canRollback,
    T? oldData,
    DateTime? oldFetchedAt,
    bool oldStale,
  ) async {
    if (updater != null) {
      try {
        return await updater!(key, newData);
      } catch (e) {
        if (canRollback()) {
          if (oldData != null) {
            _write(key, oldData, at: oldFetchedAt);
            if (oldStale) _stale.add(key);
          } else {
            _cache.remove(key);
            _fetchedAt.remove(key);
            _getSubjectForKey(key).add(null);
            _storage.delete(key);
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
    _activeFetches.take(key)?.detach();
    _write(key, value);
  }

  /// Replaces the cached value with `transform(current)`. A no-op when nothing
  /// is cached for [key]. Like [set] it discards an in-flight fetch, but it
  /// keeps the invalidated state of the entry.
  void patch(K key, T Function(T current) transform) {
    if (!_cache.containsKey(key)) return;
    final wasStale = _stale.contains(key);
    final next = transform(_cache[key] as T); // may throw: nothing changed yet
    _activeFetches.take(key)?.detach();
    _write(key, next, markFresh: !wasStale);
  }

  /// Marks [key] stale but keeps its value visible. A fetch that is in flight
  /// is discarded; the next [getData] fetches again.
  void invalidate(K key) {
    // An uncached key only needs marking if a persisted value may come back.
    if (_cache.containsKey(key) ||
        (storage != null && !_hydrated.contains(key))) {
      _stale.add(key);
    }
    _activeFetches.take(key)?.detach();
  }

  /// [invalidate] for every cached key matching [test]. With [storage] it also
  /// applies to persisted values restored later (stored before this call).
  /// The predicate is kept until the next [invalidateAll] or [clearCache].
  void invalidateWhere(bool Function(K key) test) {
    for (final key in _cache.keys.toList()) {
      if (test(key)) invalidate(key);
    }
    if (storage == null) return;
    _invalidations.add((clock(), test));
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
      _activeFetches.take(key)?.detach();
      _write(key, next, markFresh: !wasStale);
    }
  }

  /// [invalidate] for every key.
  void invalidateAll() {
    _invalidatedAllAt = clock();
    _invalidations.clear(); // covered by the newer, wider marker
    _stale.addAll(_cache.keys);
    for (final fetch in _activeFetches.takeAll()) {
      fetch.detach();
    }
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
    _hydrated.remove(key); // cached now: never read from storage
    _writeSeq[key] = ++_writes;
    final fetchedAt = at ?? clock();
    _fetchedAt[key] = fetchedAt;
    if (markFresh) _stale.remove(key);
    _getSubjectForKey(key).add(value);
    _storage.write(key, value, fetchedAt);
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

  Future<void>? _hydrate(K key) {
    if (storage == null || _cache.containsKey(key) || _hydrated.contains(key)) {
      return null;
    }
    final existing = _hydrations[key];
    if (existing != null) return existing.future;
    final hydration = _Hydration();
    _hydrations[key] = hydration;
    hydration.future = _readStored(key, hydration);
    return hydration.future;
  }

  Future<void> _readStored(K key, _Hydration hydration) async {
    final entry = await _storage.read(key);
    // Evicted or cleared while reading: drop the result.
    if (!identical(_hydrations[key], hydration)) return;
    _hydrations.remove(key);
    if (_cache.containsKey(key)) return; // written meanwhile: memory wins
    if (entry == null || !_storage.accept(key, entry)) {
      _hydrated.add(key); // nothing persisted: do not read again
      _stale.remove(key);
      return;
    }
    _cache[key] = entry.value;
    _fetchedAt[key] = entry.fetchedAt;
    if (_invalidatedSince(key, entry.fetchedAt)) _stale.add(key);
    _getSubjectForKey(key).add(entry.value);
  }

  /// Whether a value of [key] fetched [at] was invalidated by [invalidateAll]
  /// or [invalidateWhere] before it was restored. A throwing predicate counts
  /// as a match.
  bool _invalidatedSince(K key, DateTime at) {
    final all = _invalidatedAllAt;
    if (all != null && !at.isAfter(all)) return true;
    for (final (marker, test) in _invalidations) {
      if (at.isAfter(marker)) continue;
      try {
        if (test(key)) return true;
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  // --- lifecycle -----------------------------------------------------------

  /// Clear the cache. Fetches that are in flight are discarded (their signal
  /// fires), running [updateData] calls no longer touch the cache (no late
  /// rollback), and persisted entries are deleted.
  void clearCache() {
    for (final fetch in _activeFetches.takeAll()) {
      fetch.discard();
    }
    _activeUpdates.clear(); // a late rollback must not resurrect old data
    _writeSeq.clear();
    _cache.clear();
    _fetchedAt.clear();
    _stale.clear();
    _invalidatedAllAt = null;
    _invalidations.clear();
    _hydrations.clear();
    _hydrated.clear();
    _storage.clear();
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
    _activeFetches.take(key)?.discard();
    _activeUpdates.remove(key);
    _writeSeq.remove(key);
    _cache.remove(key);
    _fetchedAt.remove(key);
    _stale.remove(key);
    _hydrations.remove(key);
    _hydrated.remove(key);
    _storage.delete(key);
    _dataSubjects.remove(key)?.close();
    _errorChannels.remove(key)?.close();
  }

  /// Dispose resources. Storage is no longer touched afterwards (`evict` and
  /// `clearCache` then only drop memory).
  void dispose() {
    _storage.close();
    for (final fetch in _activeFetches.takeAll()) {
      fetch.discard();
    }
    for (final subject in _dataSubjects.values) {
      subject.close();
    }
    for (final channel in _errorChannels.values) {
      channel.close();
    }
    _activeUpdates.clear();
    _dataSubjects.clear();
    _errorChannels.clear();
    _hydrations.clear();
  }
}
