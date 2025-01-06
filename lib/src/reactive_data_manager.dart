import 'dart:async';
import 'package:async/async.dart';
import 'package:reactive_data_manager/src/exceptions.dart';
import 'package:rxdart/rxdart.dart';

/// A class that manages reactive data fetching and updating with caching and
/// optimistic updates.
///
/// The [ReactiveDataManager] class provides a way to manage data streams,
/// fetch data from a remote source, update data optimistically, and handle
/// caching. It uses [BehaviorSubject] to provide reactive streams of data
/// and [CancelableOperation] to handle cancellable fetch and update operations.
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
/// );
/// ```
class ReactiveDataManager<K, T> {
  /// All data streams are stored in a map with the key as the identifier.
  final Map<K, BehaviorSubject<T?>> _dataSubjects = {};

  /// The cache stores the latest data for each key.
  final Map<K, T> _cache = {};

  /// Active fetch operations for each key.
  final Map<K, CancelableOperation<T>> _activeFetches = {};

  /// Active update operations for each key.
  final Map<K, CancelableOperation<dynamic>> _activeUpdates = {};

  /// A function that fetches data for a specific key.
  final Future<T> Function(K key) fetcher;

  /// A function that updates data for a specific key.
  final Future<dynamic> Function(K key, T data)? updater;

  /// A function that filters data for a specific key.
  final T? Function(K key, T data)? fetchFilter;

  /// A function that updates the filter for a specific key.
  final Future<dynamic> Function(K key, dynamic result)? updateFilter;

  /// Create a new [ReactiveDataManager] instance.
  ReactiveDataManager({
    required this.fetcher,
    this.updater,
    this.fetchFilter,
    this.updateFilter,
  });

  /// Get a stream for a specific key
  Stream<T?> getStream(K key) {
    return _getSubjectForKey(key).stream;
  }

  /// Get the current value for a specific key
  T? getCurrentValue(K key) {
    return _dataSubjects[key]?.value;
  }

  /// Fetch data safely for a specific key
  Future<T> getData(K key, {bool forceRefresh = false}) async {
    // Cancel any ongoing fetch for this key
    _activeFetches[key]?.cancel();

    if (!forceRefresh && _cache.containsKey(key)) {
      _getSubjectForKey(key).add(_cache[key]);
      return _cache[key]!;
    }

    // Create a new cancellable fetch operation for this key
    final fetchOperation = CancelableOperation.fromFuture(
      fetcher(key),
    );
    _activeFetches[key] = fetchOperation;

    try {
      var result = await fetchOperation.value;

      result = fetchFilter?.call(key, result) ?? result;
      if (result == null) {
        throw const DataFilteredException();
      }

      _cache[key] = result;
      _getSubjectForKey(key).add(result);
      return result;
    } catch (e) {
      _getSubjectForKey(key).addError(e);
      return Future.error(e);
    } finally {
      _activeFetches.remove(key);
    }
  }

  /// Update data safely for a specific key
  Future<dynamic> updateData(K key, T newData) async {
    // Cancel any ongoing update for this key
    _activeUpdates[key]?.cancel();

    final oldData = _cache[key]; // Store the old state for rollback

    // Update locally and notify listeners
    _cache[key] = newData;
    _getSubjectForKey(key).add(newData);

    // Create a cancellable update operation for this key
    final updateOperation = CancelableOperation.fromFuture(
      _performUpdate(key, newData, oldData),
    );

    _activeUpdates[key] = updateOperation;

    try {
      var result = await updateOperation.value;
      result = fetchFilter?.call(key, result) ?? result;
      if (result == null) {
        throw const DataFilteredException();
      }
      return result;
    } catch (e) {
      _getSubjectForKey(key).addError(e);
      return Future.error(e);
    } finally {
      _activeUpdates.remove(key);
    }
  }

  /// Perform the update and handle failures with rollback
  Future<dynamic> _performUpdate(K key, T newData, T? oldData) async {
    if (updater != null) {
      try {
        return await updater!(key, newData);
      } catch (e) {
        if (oldData != null) {
          _cache[key] = oldData;
        } else {
          _cache.remove(key);
        }
        _getSubjectForKey(key).add(oldData);
        throw const OptimisticUpdateException();
      }
    }
    return Future.value();
  }

  /// Get or create a BehaviorSubject for a specific key
  BehaviorSubject<T?> _getSubjectForKey(K key) {
    if (!_dataSubjects.containsKey(key)) {
      _dataSubjects[key] = BehaviorSubject<T?>();
    }

    return _dataSubjects[key]!;
  }

  /// Clear the cache
  void clearCache() {
    _cache.clear();
    for (final subject in _dataSubjects.values) {
      subject.add(null);
    }
  }

  /// Dispose resources
  void dispose() {
    for (final fetch in _activeFetches.values) {
      fetch.cancel();
    }
    for (final update in _activeUpdates.values) {
      update.cancel();
    }
    for (final subject in _dataSubjects.values) {
      subject.close();
    }
    _activeFetches.clear();
    _activeUpdates.clear();
    _dataSubjects.clear();
  }
}
