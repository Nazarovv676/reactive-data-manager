import 'dart:async';

import 'package:reactive_data_manager/src/reactive_data_manager.dart';
import 'package:reactive_data_manager/src/storage.dart';

/// A [ReactiveDataManager] for a single value that has no natural key (the
/// signed-in user, remote config). It shares the engine with
/// [ReactiveDataManager], so join, `maxAge`, invalidation, `watch`, storage and
/// the other behaviours are identical; there is just no key parameter.
class ReactiveValue<T> {
  /// Creates a value. See [ReactiveDataManager] for the parameters.
  ReactiveValue({
    required Future<T> Function() fetcher,
    Future<dynamic> Function(T data)? updater,
    T? Function(T data)? fetchFilter,
    dynamic Function(dynamic result)? updateFilter,
    Duration? maxAge,
    DateTime Function() clock = DateTime.now,
    bool replayErrors = true,
    Object Function(Object error, StackTrace stackTrace)? errorMapper,
    ReactiveStorage<String, T>? storage,
    int storageVersion = 0,
  }) : _manager = ReactiveDataManager<String, T>(
          fetcher: (_) => fetcher(),
          updater: updater == null ? null : (_, data) => updater(data),
          fetchFilter:
              fetchFilter == null ? null : (_, data) => fetchFilter(data),
          updateFilter:
              updateFilter == null ? null : (_, result) => updateFilter(result),
          maxAge: maxAge,
          clock: clock,
          replayErrors: replayErrors,
          errorMapper: errorMapper,
          storage: storage,
          storageVersion: storageVersion,
        );

  /// Like the default constructor, but the fetcher receives a cancellation
  /// signal. See [ReactiveDataManager.cancellable].
  ReactiveValue.cancellable({
    required Future<T> Function(Future<void> cancel) fetcher,
    Future<dynamic> Function(T data)? updater,
    T? Function(T data)? fetchFilter,
    dynamic Function(dynamic result)? updateFilter,
    Duration? maxAge,
    DateTime Function() clock = DateTime.now,
    bool replayErrors = true,
    Object Function(Object error, StackTrace stackTrace)? errorMapper,
    ReactiveStorage<String, T>? storage,
    int storageVersion = 0,
  }) : _manager = ReactiveDataManager<String, T>.cancellable(
          fetcher: (_, cancel) => fetcher(cancel),
          updater: updater == null ? null : (_, data) => updater(data),
          fetchFilter:
              fetchFilter == null ? null : (_, data) => fetchFilter(data),
          updateFilter:
              updateFilter == null ? null : (_, result) => updateFilter(result),
          maxAge: maxAge,
          clock: clock,
          replayErrors: replayErrors,
          errorMapper: errorMapper,
          storage: storage,
          storageVersion: storageVersion,
        );

  static const _key = 'value';

  final ReactiveDataManager<String, T> _manager;

  /// The value stream (replays the current value).
  Stream<T?> get stream => _manager.getStream(_key);

  /// The current value, if any.
  T? get currentValue => _manager.getCurrentValue(_key);

  /// See [ReactiveDataManager.getData].
  Future<T> getData({bool forceRefresh = false, Duration? maxAge}) =>
      _manager.getData(_key, forceRefresh: forceRefresh, maxAge: maxAge);

  /// See [ReactiveDataManager.refresh].
  void refresh() => _manager.refresh(_key);

  /// See [ReactiveDataManager.watch].
  Stream<T> watch({bool fetch = true}) => _manager.watch(_key, fetch: fetch);

  /// See [ReactiveDataManager.updateData].
  Future<dynamic> updateData(T newData) => _manager.updateData(_key, newData);

  /// See [ReactiveDataManager.set].
  void set(T value) => _manager.set(_key, value);

  /// See [ReactiveDataManager.patch].
  void patch(T Function(T current) transform) =>
      _manager.patch(_key, transform);

  /// See [ReactiveDataManager.invalidate].
  void invalidate() => _manager.invalidate(_key);

  /// See [ReactiveDataManager.mutate].
  Future<R> mutate<R>(Future<R> Function() action, {bool invalidate = true}) =>
      _manager.mutate(_key, action, invalidate: invalidate);

  /// See [ReactiveDataManager.fetchedAt].
  DateTime? get fetchedAt => _manager.fetchedAt(_key);

  /// See [ReactiveDataManager.isFresh].
  bool isFresh({Duration? maxAge}) => _manager.isFresh(_key, maxAge: maxAge);

  /// Drops the value, cancels in-flight fetches and deletes the persisted
  /// entry.
  void clear() => _manager.clearCache();

  /// Dispose resources.
  void dispose() => _manager.dispose();
}
