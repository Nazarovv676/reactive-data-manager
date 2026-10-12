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
  AbortController() {
    signal = AbortSignal._(_completer);
  }

  final Completer<void> _completer = Completer<void>();
  late final AbortSignal signal;

  void abort() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Which part of the list a request is for.
enum PageDirection {
  /// First load of a query, or a refresh. The cursor is `null` (head of the
  /// list) or the anchor passed to `refresh(anchor: ...)`.
  initial,

  /// Continue past the tail (`PageResult.next`).
  next,

  /// Continue before the head (`PageResult.previous`).
  previous,
}

/// What a page fetcher is asked for.
final class PageRequest<Q, C extends Object> {
  /// Creates a request.
  const PageRequest({
    required this.query,
    required this.direction,
    required this.cursor,
    required this.loadedCount,
    required this.signal,
  });

  /// The query (filters, sort, ...) the page belongs to.
  final Q query;

  /// Which part of the list is requested.
  final PageDirection direction;

  /// Opaque cursor from the neighbouring page, or the anchor for
  /// [PageDirection.initial].
  final C? cursor;

  /// Number of items currently held for [query] (after dedupe and local
  /// edits). Offset APIs can use `offset = loadedCount`, which self-heals
  /// when the app removed items locally.
  final int loadedCount;

  /// Aborted when this request is no longer wanted.
  final AbortSignal signal;
}

/// One fetched page. Named `PageResult` to avoid clashing with Flutter's
/// `Page`.
final class PageResult<T, C extends Object> {
  /// Creates a page result.
  const PageResult(this.items, {this.next, this.previous, this.totalCount});

  /// Items in LIST order (top to bottom), whatever the request direction.
  final List<T> items;

  /// Cursor of the page after this one; `null` means no more in that
  /// direction.
  final C? next;

  /// Cursor of the page before this one; `null` means no more in that
  /// direction.
  final C? previous;

  /// Optional server total. Informational: never used to derive `hasMore`.
  final int? totalCount;
}

/// Fetches one page.
typedef PageFetcher<Q, T, C extends Object> = Future<PageResult<T, C>> Function(
    PageRequest<Q, C> request);

/// Thrown by a fetcher when its cursor is no longer valid. The manager then
/// refreshes the first page instead of reporting an error.
final class PageCursorExpiredException implements Exception {
  /// Creates the exception.
  const PageCursorExpiredException();
}

/// A failure together with its stack trace.
final class PagedError {
  /// Creates a paged error.
  const PagedError(this.error, this.stackTrace);

  /// The error thrown by the fetcher.
  final Object error;

  /// Where it was thrown.
  final StackTrace stackTrace;

  /// [error] as an [E], or `null` when it is something else.
  E? errorAs<E>() {
    final e = error;
    return e is E ? e as E : null;
  }
}

/// The state of one end of a list.
final class PagedEdge {
  /// Creates an edge state.
  const PagedEdge({this.hasMore = false, this.isLoading = false, this.error});

  /// A cursor exists in this direction.
  final bool hasMore;

  /// A load in this direction is in flight.
  final bool isLoading;

  /// Last failure in this direction. Items are retained.
  final PagedError? error;
}

/// Immutable snapshot of a paged list: items plus per-operation flags. Errors
/// live here, next to the retained items; they are never stream errors.
final class PagedState<T> {
  /// Creates a state.
  const PagedState({
    this.items = const [],
    this.hasLoaded = false,
    this.isRefreshing = false,
    this.refreshError,
    this.next = const PagedEdge(),
    this.previous = const PagedEdge(),
    this.totalCount,
    this.fetchedAt,
    this.isStale = false,
  });

  /// Unmodifiable. Server order plus local edits. Never cleared by an error.
  final List<T> items;

  /// Whether any page was applied. Tells "nothing loaded yet" from "empty".
  final bool hasLoaded;

  /// An initial load or refresh is in flight (items stay visible).
  final bool isRefreshing;

  /// Last initial/refresh failure; cleared when the next head load starts.
  final PagedError? refreshError;

  /// Tail edge (`loadNext`).
  final PagedEdge next;

  /// Head edge (`loadPrevious`).
  final PagedEdge previous;

  /// Last server total, adjusted by local inserts and removals.
  final int? totalCount;

  /// When the head was last loaded from the network.
  final DateTime? fetchedAt;

  /// Invalidated or older than `maxAge`.
  final bool isStale;

  /// The very first load is in flight.
  bool get isLoadingInitial => !hasLoaded && isRefreshing;

  /// The very first load failed.
  bool get hasInitialError => !hasLoaded && refreshError != null;

  /// Loaded, empty and nothing more to load.
  bool get isEmpty =>
      hasLoaded && items.isEmpty && !next.hasMore && !previous.hasMore;
}

/// Which end of the list an item is inserted at.
enum PagedEnd {
  /// The top of the list.
  head,

  /// The bottom of the list.
  tail,
}

/// What is kept for a query that has no listeners.
enum Retention {
  /// Everything loaded.
  all,

  /// Only the first page (trimmed when the last listener leaves).
  firstPage,
}
