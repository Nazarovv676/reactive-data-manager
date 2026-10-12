import 'dart:async';

import 'package:reactive_data_manager/src/engine/abort.dart';

/// One in-flight operation (a fetch or a page load). Every caller that joins
/// it shares [future], which completes exactly once.
///
/// A [discard]ed or [detach]ed operation must not write its result anywhere;
/// on [discard] its fetcher is told through [signal]. [discardWith] additionally releases the callers with
/// another result, e.g. the future of the operation that superseded it, so a
/// superseded operation never leaves its callers hanging.
class Operation<R> {
  /// Creates a pending operation.
  Operation() {
    // Callers that never await (fire-and-forget) must not trigger an
    // unhandled zone error; callers that do await still receive the error.
    _completer.future.ignore();
  }

  final Completer<R> _completer = Completer<R>();
  final AbortController _abort = AbortController();

  /// Set when the result must no longer be applied.
  bool discarded = false;

  /// What the callers receive.
  Future<R> get future => _completer.future;

  /// Aborted when the operation is discarded.
  AbortSignal get signal => _abort.signal;

  /// Completes [future] with [result] unless it already completed.
  void resolve(FutureOr<R> result) {
    if (!_completer.isCompleted) _completer.complete(result);
  }

  /// Completes [future] with an error unless it already completed.
  void fail(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }

  /// Marks the result unwanted and aborts [signal]. Callers still complete
  /// with the operation's own outcome (with a fetcher that honours the signal
  /// that is typically its cancellation error).
  void discard() {
    discarded = true;
    _abort.abort();
  }

  /// Marks the result unwanted without aborting [signal]: the request runs to
  /// completion and callers receive its outcome, which is not applied.
  void detach() {
    discarded = true;
  }

  /// Marks the result unwanted, completes the callers with [result] right
  /// away and aborts [signal].
  void discardWith(FutureOr<R> result) {
    discarded = true;
    resolve(result);
    _abort.abort();
  }
}

/// The in-flight operations of one owner, at most one per lane. A new call on
/// a lane either joins `inFlight[lane]` or supersedes it.
class InFlight<L, O extends Operation<Object?>> {
  final Map<L, O> _ops = {};

  /// The operation running on [lane], if any.
  O? operator [](L lane) => _ops[lane];

  /// Makes [op] the operation of [lane]. The caller discards the previous one.
  void operator []=(L lane, O op) => _ops[lane] = op;

  /// Removes and returns the operation of [lane].
  O? take(L lane) => _ops.remove(lane);

  /// Removes [op] from [lane] if it is still the current one.
  void finish(L lane, O op) {
    if (identical(_ops[lane], op)) _ops.remove(lane);
  }

  /// Whether nothing is in flight.
  bool get isEmpty => _ops.isEmpty;

  /// The running operations, in start order.
  Iterable<O> get all => _ops.values;

  /// Removes and returns every running operation, in start order.
  List<O> takeAll() {
    final ops = _ops.values.toList();
    _ops.clear();
    return ops;
  }
}
