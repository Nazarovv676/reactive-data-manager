/// Test helpers for code that uses `ReactivePagedManager`.
library reactive_data_manager.testing;

import 'dart:async';

import 'package:reactive_data_manager/reactive_data_manager.dart';

/// A [PageFetcher] whose requests are completed by hand, so a test controls
/// the order in which responses arrive. Every request is logged.
///
/// ```dart
/// final pages = ScriptedPageFetcher<String, Item, int>();
/// final manager = ReactivePagedManager<String, Item, int>(
///   fetchPage: pages.call,
///   idOf: (i) => i.id,
/// );
/// final f = manager.loadNext('q');
/// pages.completeLast([item], next: 2);
/// await f;
/// ```
class ScriptedPageFetcher<Q, T, C extends Object> {
  /// Every request received so far, in order.
  final List<PageRequest<Q, C>> requests = [];

  final List<Completer<PageResult<T, C>>> _pending = [];

  /// Pass this as `fetchPage`.
  Future<PageResult<T, C>> call(PageRequest<Q, C> request) {
    requests.add(request);
    final completer = Completer<PageResult<T, C>>();
    _pending.add(completer);
    return completer.future;
  }

  /// How many requests are still waiting for a response.
  int get pending => _pending.where((c) => !c.isCompleted).length;

  /// Responds to request [index] (0-based, in arrival order).
  void complete(
    int index,
    List<T> items, {
    C? next,
    C? previous,
    int? totalCount,
  }) {
    _pending[index].complete(
      PageResult<T, C>(items,
          next: next, previous: previous, totalCount: totalCount),
    );
  }

  /// Responds to the most recent request.
  void completeLast(
    List<T> items, {
    C? next,
    C? previous,
    int? totalCount,
  }) =>
      complete(
        _pending.length - 1,
        items,
        next: next,
        previous: previous,
        totalCount: totalCount,
      );

  /// Fails request [index].
  void fail(int index, Object error, [StackTrace? stackTrace]) =>
      _pending[index].completeError(error, stackTrace);

  /// Fails the most recent request.
  void failLast(Object error, [StackTrace? stackTrace]) =>
      fail(_pending.length - 1, error, stackTrace);
}
