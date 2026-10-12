import 'dart:async';

/// A cancellation signal handed to a page fetcher. It is aborted when the
/// request is superseded, invalidated, evicted, cleared or disposed. Wire it to
/// e.g. Dio's `CancelToken`. Ignoring it is always safe.
class AbortSignal {
  AbortSignal._(this._completer);

  final Completer<void> _completer;

  /// Whether the request is no longer wanted.
  bool get aborted => _completer.isCompleted;

  /// Completes when the request is no longer wanted.
  Future<void> get whenAborted => _completer.future;
}

/// Creates an [AbortSignal] and aborts it. Internal.
class AbortController {
  /// Creates a controller with a fresh, not yet aborted [signal].
  AbortController() {
    signal = AbortSignal._(_completer);
  }

  final Completer<void> _completer = Completer<void>();

  /// The signal handed to the fetcher.
  late final AbortSignal signal;

  /// Aborts [signal]. Idempotent.
  void abort() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
