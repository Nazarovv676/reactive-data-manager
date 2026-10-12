import 'dart:async';

import 'package:reactive_data_manager/src/paged/paged_types.dart';
import 'package:rxdart/rxdart.dart';

enum _EditKind { patch, remove, upsert }

class _Edit<T> {
  _Edit.patch(this.seq, this.id, this.transform)
      : kind = _EditKind.patch,
        item = null,
        atHead = true,
        move = false;
  _Edit.remove(this.seq, this.id)
      : kind = _EditKind.remove,
        transform = null,
        item = null,
        atHead = true,
        move = false;
  _Edit.upsert(this.seq, this.id, T this.item, this.atHead, this.move)
      : kind = _EditKind.upsert,
        transform = null;

  final _EditKind kind;
  final int seq;
  final Object? id;
  final T Function(T current)? transform;
  final T? item;
  final bool atHead;
  final bool move;
}

/// One in-flight load of one lane (head, next or previous).
class _Op<T, C extends Object> {
  _Op(this.startSeq, [this.anchor]);

  final Completer<PagedState<T>> _completer = Completer<PagedState<T>>();
  final AbortController abort = AbortController();
  final int startSeq;
  final C? anchor;
  bool discarded = false;

  Future<PagedState<T>> get future => _completer.future;

  void resolve(FutureOr<PagedState<T>> value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  /// The result is no longer wanted: abort the request and release callers.
  void discard(FutureOr<PagedState<T>> result) {
    discarded = true;
    abort.abort();
    resolve(result);
  }
}

class _Entry<T, C extends Object> {
  _Entry(this.subject);

  final BehaviorSubject<PagedState<T>> subject;
  List<T> items = [];
  bool hasLoaded = false;
  C? nextCursor;
  C? prevCursor;
  bool nextMore = false;
  bool prevMore = false;
  int? totalCount;
  DateTime? fetchedAt;
  bool stale = false;
  PagedError? refreshError;
  PagedError? nextError;
  PagedError? prevError;

  // First-page snapshot, for Retention.firstPage.
  int headCount = 0;
  C? headNext;

  _Op<T, C>? head;
  _Op<T, C>? next;
  _Op<T, C>? prev;

  int seq = 0;
  final List<_Edit<T>> edits = [];

  int watchers = 0;
  int lastUnwatched = 0;
  Timer? evictTimer;

  bool get hasInFlight => head != null || next != null || prev != null;
}

/// A manager for paginated lists: one accumulated list per query, with
/// concurrent-safe `loadNext`/`loadPrevious`/`refresh`, dedupe by item id,
/// cross-query item patching, and automatic eviction of unwatched queries.
///
/// Type parameters:
/// - [Q]: the query (filters, sort, ...). Needs value equality and must not
///   contain the page, offset or cursor.
/// - [T]: the item type.
/// - [C]: the opaque cursor type (page number, offset, token, ...). The package
///   never interprets it.
///
/// Loading futures never throw and never hang: they resolve to the resulting
/// [PagedState]. Errors are exposed in the state and through [onError].
///
/// ```dart
/// final events = ReactivePagedManager<EventQuery, Event, int>(
///   idOf: (e) => e.id,
///   fetchPage: (req) async {
///     final page = req.cursor ?? 1;
///     final r = await api.events(req.query, page: page);
///     return PageResult(r.items, next: r.hasNext ? page + 1 : null);
///   },
/// );
/// ```
class ReactivePagedManager<Q, T, C extends Object> {
  /// Creates a manager.
  ///
  /// - [fetchPage]: loads one page.
  /// - [idOf]: identity for dedupe, `patchItem` and `removeItem`. Return `null`
  ///   for items without identity.
  /// - [maxAge]: age of the head after which a watch refetches.
  /// - [maxEntries]: how many *unwatched* queries are kept (LRU).
  /// - [evictAfterUnwatched]: evicts a query that had no listener for this long.
  /// - [retainWhenUnwatched]: [Retention.firstPage] trims a query to its first
  ///   page when the last listener leaves.
  /// - [maxUnproductivePages]: how many pages that add nothing new one
  ///   `loadNext`/`loadPrevious` follows before the edge counts as exhausted.
  /// - [onError]: notified of every fetch failure (also exposed in the state).
  /// - [clock]: injectable time source.
  ReactivePagedManager({
    required this.fetchPage,
    required this.idOf,
    this.maxAge,
    this.maxEntries,
    this.evictAfterUnwatched,
    this.retainWhenUnwatched = Retention.all,
    this.maxUnproductivePages = 3,
    this.onError,
    this.clock = DateTime.now,
  });

  /// Loads one page.
  final PageFetcher<Q, T, C> fetchPage;

  /// Item identity.
  final Object? Function(T item) idOf;

  /// Age of the head after which a state is stale.
  final Duration? maxAge;

  /// Maximum number of unwatched queries kept in memory.
  final int? maxEntries;

  /// How long a query may stay unwatched before it is evicted.
  final Duration? evictAfterUnwatched;

  /// What is kept for unwatched queries.
  final Retention retainWhenUnwatched;

  /// Pages that add nothing new followed per call.
  final int maxUnproductivePages;

  /// Failure callback.
  final void Function(
    Q query,
    PageDirection direction,
    Object error,
    StackTrace stackTrace,
  )? onError;

  /// Time source.
  final DateTime Function() clock;

  final Map<Q, _Entry<T, C>> _entries = {};
  int _tick = 0;
  bool _disposed = false;

  // --- reading -------------------------------------------------------------

  /// The state of [query] as a stream. Emits the current state first, then
  /// every change. With [fetch] (default) it loads the first page when the
  /// query has nothing loaded yet or is stale. Listening is ref-counted: it
  /// drives [evictAfterUnwatched] and [maxEntries].
  ///
  /// Each call returns a new single-subscription stream.
  Stream<PagedState<T>> watch(Q query, {bool fetch = true}) {
    _Entry<T, C>? entry;
    StreamSubscription<PagedState<T>>? sub;
    late final StreamController<PagedState<T>> controller;
    controller = StreamController<PagedState<T>>(
      onListen: () {
        if (_disposed) {
          controller.add(const PagedState());
          return;
        }
        final e = _entryFor(query);
        entry = e;
        e.watchers++;
        e.evictTimer?.cancel();
        e.evictTimer = null;
        sub = e.subject.stream.listen(
          controller.add,
          onDone: controller.close,
        );
        if (fetch && e.head == null && (!e.hasLoaded || _isStale(e))) {
          _startHead(e, query);
        }
      },
      onCancel: () {
        final e = entry;
        entry = null;
        if (e != null) {
          e.watchers--;
          if (e.watchers == 0 && !_disposed) _unwatched(query, e);
        }
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  /// The current state of [query], or `null` when it is not cached.
  PagedState<T>? peek(Q query) {
    final e = _entries[query];
    return e == null ? null : _stateOf(e);
  }

  /// The queries currently held in memory.
  Iterable<Q> get cachedQueries => List.of(_entries.keys);

  // --- loading -------------------------------------------------------------

  /// Loads the page after the tail. Joins an in-flight `loadNext`, and joins a
  /// running head load instead of appending to a list being replaced. Starts
  /// the first load when nothing is loaded; a no-op without more pages.
  Future<PagedState<T>> loadNext(Q query) => _loadEdge(query, forward: true);

  /// Loads the page before the head. Same rules as [loadNext].
  Future<PagedState<T>> loadPrevious(Q query) =>
      _loadEdge(query, forward: false);

  /// Refetches the first page, keeping the previous items visible
  /// (`isRefreshing`). On failure the previous items stay and the error is in
  /// the state. Joins a running refresh; a different [anchor] supersedes it.
  /// Aborts running `loadNext`/`loadPrevious`.
  Future<PagedState<T>> refresh(Q query, {C? anchor}) {
    if (_disposed) return Future.value(const PagedState());
    final e = _entryFor(query);
    final running = e.head;
    if (running != null && running.anchor == anchor) return running.future;
    return _startHead(e, query, anchor: anchor).future;
  }

  Future<PagedState<T>> _loadEdge(Q query, {required bool forward}) {
    if (_disposed) return Future.value(const PagedState());
    final e = _entryFor(query);
    final head = e.head;
    if (head != null) return head.future;
    if (!e.hasLoaded) return _startHead(e, query).future;
    final lane = forward ? e.next : e.prev;
    if (lane != null) return lane.future;
    if (!(forward ? e.nextMore : e.prevMore)) {
      return Future.value(_stateOf(e));
    }
    final op = _Op<T, C>(e.seq);
    if (forward) {
      e.next = op;
      e.nextError = null;
    } else {
      e.prev = op;
      e.prevError = null;
    }
    _emit(e);
    _runEdge(e, query, op, forward);
    return op.future;
  }

  _Op<T, C> _startHead(_Entry<T, C> e, Q query, {C? anchor}) {
    final op = _Op<T, C>(e.seq, anchor);
    for (final old in [e.head, e.next, e.prev]) {
      old?.discard(op.future);
    }
    e.next = null;
    e.prev = null;
    e.head = op;
    e.refreshError = null;
    _emit(e);
    _runHead(e, query, op);
    return op;
  }

  Future<void> _runHead(_Entry<T, C> e, Q query, _Op<T, C> op) async {
    PageResult<T, C> result;
    try {
      result = await fetchPage(PageRequest<Q, C>(
        query: query,
        direction: PageDirection.initial,
        cursor: op.anchor,
        loadedCount: e.items.length,
        signal: op.abort.signal,
      ));
    } catch (error, stack) {
      if (op.discarded) return;
      e.head = null;
      e.refreshError = PagedError(error, stack);
      _finishOp(e);
      _emit(e);
      _report(query, PageDirection.initial, error, stack);
      op.resolve(_stateOf(e));
      return;
    }
    if (op.discarded) return;

    var list = _dedupe(result.items);
    for (final edit in e.edits.where((x) => x.seq > op.startSeq)) {
      _applyEdit(list, edit);
    }
    e.items = list;
    e.nextCursor = result.next;
    e.nextMore = result.next != null;
    e.prevCursor = result.previous;
    e.prevMore = result.previous != null;
    e.totalCount = result.totalCount;
    e.fetchedAt = clock();
    e.stale = false;
    e.hasLoaded = true;
    e.refreshError = null;
    e.nextError = null;
    e.prevError = null;
    e.headCount = list.length;
    e.headNext = result.next;
    e.head = null;
    _finishOp(e);
    _emit(e);
    op.resolve(_stateOf(e));
  }

  Future<void> _runEdge(
    _Entry<T, C> e,
    Q query,
    _Op<T, C> op,
    bool forward,
  ) async {
    final direction = forward ? PageDirection.next : PageDirection.previous;
    var cursor = forward ? e.nextCursor : e.prevCursor;
    var unproductive = 0;

    void clearLane() {
      if (forward) {
        e.next = null;
      } else {
        e.prev = null;
      }
    }

    while (true) {
      PageResult<T, C> result;
      try {
        result = await fetchPage(PageRequest<Q, C>(
          query: query,
          direction: direction,
          cursor: cursor,
          loadedCount: e.items.length,
          signal: op.abort.signal,
        ));
      } on PageCursorExpiredException {
        if (op.discarded) return;
        _startHead(e, query); // discards this op and resolves it with the head
        return;
      } catch (error, stack) {
        if (op.discarded) return;
        clearLane();
        final failure = PagedError(error, stack);
        if (forward) {
          e.nextError = failure;
        } else {
          e.prevError = failure;
        }
        _finishOp(e);
        _emit(e);
        _report(query, direction, error, stack);
        op.resolve(_stateOf(e));
        return;
      }
      if (op.discarded) return;

      final added = _mergeEdge(e, result.items, forward, op.startSeq);
      final following = forward ? result.next : result.previous;
      if (forward) {
        e.nextCursor = following;
        e.nextMore = following != null;
      } else {
        e.prevCursor = following;
        e.prevMore = following != null;
      }
      if (result.totalCount != null) e.totalCount = result.totalCount;

      if (following != null && following == cursor) {
        // The cursor did not move: it would loop forever.
        if (forward) {
          e.nextMore = false;
        } else {
          e.prevMore = false;
        }
      } else if (added == 0 && following != null) {
        if (++unproductive < maxUnproductivePages) {
          cursor = following;
          continue;
        }
        if (forward) {
          e.nextMore = false;
        } else {
          e.prevMore = false;
        }
      }
      break;
    }

    clearLane();
    _finishOp(e);
    _emit(e);
    op.resolve(_stateOf(e));
  }

  // --- merging and edits ---------------------------------------------------

  List<T> _dedupe(List<T> items) {
    final seen = <Object>{};
    final out = <T>[];
    for (final item in items) {
      final id = idOf(item);
      if (id == null || seen.add(id)) out.add(item);
    }
    return out;
  }

  /// Merges a next/previous page. Returns how many new items were added.
  int _mergeEdge(_Entry<T, C> e, List<T> page, bool forward, int startSeq) {
    final fresh = _dedupe(page);
    final later = e.edits.where((x) => x.seq > startSeq).toList();
    // Rebase onto local edits made after the request started.
    for (final edit in later) {
      if (edit.kind != _EditKind.upsert) _applyEdit(fresh, edit);
    }
    final index = <Object, int>{};
    for (var i = 0; i < e.items.length; i++) {
      final id = idOf(e.items[i]);
      if (id != null) index[id] = i;
    }
    final added = <T>[];
    for (final item in fresh) {
      final id = idOf(item);
      final at = id == null ? null : index[id];
      if (at == null) {
        added.add(item);
      } else if (!later.any((x) => x.kind == _EditKind.patch && x.id == id)) {
        e.items[at] = item; // already present: keep position, take new value
      }
    }
    e.items = forward ? [...e.items, ...added] : [...added, ...e.items];
    return added.length;
  }

  /// Applies [edit] to [list]. Returns whether anything changed.
  bool _applyEdit(List<T> list, _Edit<T> edit) {
    switch (edit.kind) {
      case _EditKind.patch:
        var changed = false;
        for (var i = 0; i < list.length; i++) {
          if (idOf(list[i]) == edit.id) {
            list[i] = edit.transform!(list[i]);
            changed = true;
          }
        }
        return changed;
      case _EditKind.remove:
        final before = list.length;
        list.removeWhere((x) => idOf(x) == edit.id);
        return list.length != before;
      case _EditKind.upsert:
        final item = edit.item as T;
        final at =
            edit.id == null ? -1 : list.indexWhere((x) => idOf(x) == edit.id);
        if (at >= 0) {
          if (edit.move) {
            list.removeAt(at);
            edit.atHead ? list.insert(0, item) : list.add(item);
          } else {
            list[at] = item;
          }
        } else {
          edit.atHead ? list.insert(0, item) : list.add(item);
        }
        return true;
    }
  }

  void _record(_Entry<T, C> e, _Edit<T> edit) {
    if (e.hasInFlight) e.edits.add(edit);
  }

  /// Drops edits no in-flight request can still need.
  void _finishOp(_Entry<T, C> e) {
    if (!e.hasInFlight) {
      e.edits.clear();
      return;
    }
    final oldest = [e.head, e.next, e.prev]
        .whereType<_Op<T, C>>()
        .map((o) => o.startSeq)
        .reduce((a, b) => a < b ? a : b);
    e.edits.removeWhere((x) => x.seq <= oldest);
  }

  /// Applies [transform] to the item with [id] in every cached query (or those
  /// matching [where]). Emits only for queries that contained the id. The
  /// transform must be pure: it may be replayed onto a response that arrives
  /// later.
  void patchItem(
    Object id,
    T Function(T current) transform, {
    bool Function(Q query)? where,
  }) {
    for (final entry in _entries.entries.toList()) {
      if (where != null && !where(entry.key)) continue;
      final e = entry.value;
      final edit = _Edit<T>.patch(++e.seq, id, transform);
      final changed = _applyEdit(e.items, edit);
      _record(e, edit); // also when nothing changed: a response may need it
      if (changed) _emit(e);
    }
  }

  /// Removes the item with [id] from every cached query (or those matching
  /// [where]) and decrements `totalCount`. Emits only for queries that changed.
  void removeItem(Object id, {bool Function(Q query)? where}) {
    for (final entry in _entries.entries.toList()) {
      if (where != null && !where(entry.key)) continue;
      final e = entry.value;
      final edit = _Edit<T>.remove(++e.seq, id);
      final changed = _applyEdit(e.items, edit);
      if (changed) {
        final total = e.totalCount;
        if (total != null && total > 0) e.totalCount = total - 1;
      }
      _record(e, edit);
      if (changed) _emit(e);
    }
  }

  /// Inserts or replaces [item] in [query].
  ///
  /// A present item is replaced in place, or moved to [at] with [move]. An
  /// absent item is inserted at [at] only when that end is fully loaded
  /// (`at: head` needs no previous page, `at: tail` needs no next page);
  /// otherwise it belongs to an unloaded region and is ignored. Does nothing
  /// when [query] is not cached.
  void upsertItem(
    Q query,
    T item, {
    PagedEnd at = PagedEnd.head,
    bool move = false,
  }) {
    final e = _entries[query];
    if (e == null) return;
    final id = idOf(item);
    final present = id != null && e.items.any((x) => idOf(x) == id);
    if (!present) {
      final endLoaded = at == PagedEnd.head
          ? !e.prevMore
          : (e.hasLoaded || e.head != null) && !e.nextMore;
      if (!endLoaded) return;
    }
    final edit = _Edit<T>.upsert(++e.seq, id, item, at == PagedEnd.head, move);
    _applyEdit(e.items, edit);
    if (!present) {
      final total = e.totalCount;
      if (total != null) e.totalCount = total + 1;
    }
    _record(e, edit);
    _emit(e);
  }

  // --- invalidation --------------------------------------------------------

  /// Marks [query] stale and discards its in-flight loads. A watched query
  /// refetches immediately; an unwatched one is only marked and revalidates on
  /// the next watch.
  void invalidate(Q query) {
    final e = _entries[query];
    if (e != null) _invalidate(query, e);
  }

  /// [invalidate] for every cached query matching [test].
  void invalidateWhere(bool Function(Q query) test) {
    for (final entry in _entries.entries.toList()) {
      if (test(entry.key)) _invalidate(entry.key, entry.value);
    }
  }

  /// [invalidate] for every cached query.
  void invalidateAll() => invalidateWhere((_) => true);

  void _invalidate(Q query, _Entry<T, C> e) {
    e.stale = true;
    if (e.watchers > 0) {
      _startHead(e, query);
      return;
    }
    final state = _stateAfterDiscard(e);
    for (final op in [e.head, e.next, e.prev]) {
      op?.discard(state);
    }
    e.head = e.next = e.prev = null;
    _finishOp(e);
    _emit(e);
  }

  PagedState<T> _stateAfterDiscard(_Entry<T, C> e) {
    final saved = [e.head, e.next, e.prev];
    e.head = e.next = e.prev = null;
    final state = _stateOf(e);
    e.head = saved[0];
    e.next = saved[1];
    e.prev = saved[2];
    return state;
  }

  // --- lifecycle -----------------------------------------------------------

  /// Resets [query]: in-flight loads are discarded, the cache is dropped.
  /// Listeners stay subscribed and receive an empty idle state; nothing is
  /// refetched automatically.
  void evict(Q query) {
    final e = _entries[query];
    if (e != null) _reset(query, e);
  }

  /// [evict] for every query (e.g. on logout).
  void clearCache() {
    for (final entry in _entries.entries.toList()) {
      _reset(entry.key, entry.value);
    }
  }

  void _reset(Q query, _Entry<T, C> e) {
    final ops = [e.head, e.next, e.prev];
    e.head = e.next = e.prev = null;
    e.items = [];
    e.hasLoaded = false;
    e.nextCursor = e.prevCursor = e.headNext = null;
    e.nextMore = e.prevMore = false;
    e.totalCount = null;
    e.fetchedAt = null;
    e.stale = false;
    e.refreshError = e.nextError = e.prevError = null;
    e.headCount = 0;
    e.edits.clear();
    final state = _stateOf(e);
    for (final op in ops) {
      op?.discard(state);
    }
    if (e.watchers > 0) {
      _emit(e);
    } else {
      _remove(query, e);
    }
  }

  void _remove(Q query, _Entry<T, C> e) {
    e.evictTimer?.cancel();
    e.evictTimer = null;
    if (identical(_entries[query], e)) _entries.remove(query);
    e.subject.close();
  }

  /// Aborts everything, cancels timers, closes streams. Pending futures
  /// resolve. Later calls do nothing.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.entries.toList()) {
      final e = entry.value;
      final state = _stateAfterDiscard(e);
      for (final op in [e.head, e.next, e.prev]) {
        op?.discard(state);
      }
      e.head = e.next = e.prev = null;
      e.evictTimer?.cancel();
      await e.subject.close();
    }
    _entries.clear();
  }

  // --- internals -----------------------------------------------------------

  _Entry<T, C> _entryFor(Q query) {
    final existing = _entries[query];
    if (existing != null) return existing;
    final e = _Entry<T, C>(BehaviorSubject<PagedState<T>>());
    _entries[query] = e;
    e.subject.add(_stateOf(e));
    // Created by a call, not a watch: it counts as unwatched from now on.
    _unwatched(query, e);
    return e;
  }

  void _unwatched(Q query, _Entry<T, C> e) {
    e.lastUnwatched = ++_tick;
    if (retainWhenUnwatched == Retention.firstPage && e.hasLoaded) {
      final keep = e.headCount < e.items.length ? e.headCount : e.items.length;
      if (keep < e.items.length || e.nextCursor != e.headNext) {
        for (final op in [e.next, e.prev]) {
          op?.discard(_stateAfterDiscard(e));
        }
        e.next = e.prev = null;
        e.items = e.items.sublist(0, keep);
        e.nextCursor = e.headNext;
        e.nextMore = e.headNext != null;
        _emit(e);
      }
    }
    e.evictTimer?.cancel();
    final after = evictAfterUnwatched;
    if (after != null) {
      e.evictTimer = Timer(after, () {
        if (e.watchers == 0 && identical(_entries[query], e)) {
          _reset(query, e);
        }
      });
    }
    _enforceMaxEntries();
  }

  void _enforceMaxEntries() {
    final limit = maxEntries;
    if (limit == null) return;
    while (true) {
      final unwatched = _entries.entries
          .where((x) => x.value.watchers == 0)
          .toList()
        ..sort(
            (a, b) => a.value.lastUnwatched.compareTo(b.value.lastUnwatched));
      if (unwatched.length <= limit) return;
      _reset(unwatched.first.key, unwatched.first.value);
    }
  }

  bool _isStale(_Entry<T, C> e) {
    if (e.stale) return true;
    final limit = maxAge;
    final at = e.fetchedAt;
    return limit != null && at != null && clock().difference(at) >= limit;
  }

  PagedState<T> _stateOf(_Entry<T, C> e) => PagedState<T>(
        items: List<T>.unmodifiable(e.items),
        hasLoaded: e.hasLoaded,
        isRefreshing: e.head != null,
        refreshError: e.refreshError,
        next: PagedEdge(
          hasMore: e.nextMore,
          isLoading: e.next != null,
          error: e.nextError,
        ),
        previous: PagedEdge(
          hasMore: e.prevMore,
          isLoading: e.prev != null,
          error: e.prevError,
        ),
        totalCount: e.totalCount,
        fetchedAt: e.fetchedAt,
        isStale: e.hasLoaded && _isStale(e),
      );

  void _emit(_Entry<T, C> e) {
    if (!e.subject.isClosed) e.subject.add(_stateOf(e));
  }

  void _report(Q query, PageDirection d, Object error, StackTrace stack) {
    try {
      onError?.call(query, d, error, stack);
    } catch (_) {}
  }
}
