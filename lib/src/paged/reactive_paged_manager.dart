import 'dart:async';

import 'package:reactive_data_manager/src/engine/entry_registry.dart';
import 'package:reactive_data_manager/src/engine/freshness.dart';
import 'package:reactive_data_manager/src/engine/operation.dart';
import 'package:reactive_data_manager/src/engine/storage_queue.dart';
import 'package:reactive_data_manager/src/paged/paged_types.dart';
import 'package:reactive_data_manager/src/storage.dart';
import 'package:rxdart/rxdart.dart';

enum _EditKind { patch, remove, upsert, insertAt }

class _Edit<T> {
  _Edit.patch(this.seq, this.id, this.transform)
      : kind = _EditKind.patch,
        item = null,
        afterId = null,
        index = 0,
        atHead = true,
        move = false;
  _Edit.remove(this.seq, this.id)
      : kind = _EditKind.remove,
        transform = null,
        item = null,
        afterId = null,
        index = 0,
        atHead = true,
        move = false;
  _Edit.upsert(this.seq, this.id, T this.item, this.atHead, this.move)
      : kind = _EditKind.upsert,
        transform = null,
        afterId = null,
        index = 0;
  _Edit.insertAt(this.seq, this.id, T this.item, this.afterId, this.index)
      : kind = _EditKind.insertAt,
        transform = null,
        atHead = true,
        move = false;

  final _EditKind kind;
  final int seq;
  final Object? id;
  final T Function(T current)? transform;
  final T? item;
  final bool atHead;
  final bool move;
  final Object? afterId;
  final int index;
}

/// One loaded page inside an entry: how many items it owns in the list and the
/// cursors the server returned for it.
class _Page<C extends Object> {
  _Page(this.count, this.previous, this.next);
  int count;
  C? previous;
  C? next;
}

/// The independent in-flight lanes of a query.
enum _Lane { head, next, previous }

/// One in-flight load of one lane (head, next or previous).
class _Op<T, C extends Object> extends Operation<PagedState<T>> {
  _Op(this.startSeq, [this.anchor, this.mode = RefreshMode.firstPage]);

  /// Edit sequence number when the load started (for rebasing).
  final int startSeq;
  final C? anchor;
  final RefreshMode mode;
}

class _Entry<T, C extends Object> extends RegistryEntry {
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

  /// Loaded pages in list order. Their counts add up to `items.length`.
  List<_Page<C>> pages = [];

  /// Restored from storage and not revalidated by the network yet.
  bool hydrated = false;
  int hydrationToken = 0;

  final InFlight<_Lane, _Op<T, C>> lanes = InFlight();

  _Op<T, C>? get head => lanes[_Lane.head];
  _Op<T, C>? get next => lanes[_Lane.next];
  _Op<T, C>? get prev => lanes[_Lane.previous];

  /// The running loads, head first.
  List<_Op<T, C>> get ops => [head, next, prev].whereType<_Op<T, C>>().toList();

  int seq = 0;
  final List<_Edit<T>> edits = [];
}

/// Optimistic edits handed to the `optimistic` callback of
/// [ReactivePagedManager.mutate]. They behave like the manager's own
/// `patchItem`/`removeItem`/`upsertItem`, and are undone if the action fails.
class PagedEdits<Q, T> {
  PagedEdits._(this._patch, this._remove, this._upsert);

  final void Function(Object, T Function(T), bool Function(Q)?) _patch;
  final void Function(Object, bool Function(Q)?) _remove;
  final void Function(Q, T, PagedEnd, bool) _upsert;

  /// See [ReactivePagedManager.patchItem].
  void patchItem(
    Object id,
    T Function(T current) transform, {
    bool Function(Q query)? where,
  }) =>
      _patch(id, transform, where);

  /// See [ReactivePagedManager.removeItem].
  void removeItem(Object id, {bool Function(Q query)? where}) =>
      _remove(id, where);

  /// See [ReactivePagedManager.upsertItem].
  void upsertItem(
    Q query,
    T item, {
    PagedEnd at = PagedEnd.head,
    bool move = false,
  }) =>
      _upsert(query, item, at, move);
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
  /// - [maxEntries]: how many *unwatched* queries are kept (LRU). At least 1
  ///   (`null`: unlimited); a query a call is working on is unwatched too.
  ///
  /// [maxEntries], [maxRefreshPages], [maxItems] and [maxUnproductivePages]
  /// must be at least 1, otherwise an [ArgumentError] is thrown.
  /// - [evictAfterUnwatched]: evicts a query that had no listener for this long.
  /// - [retainWhenUnwatched]: [Retention.firstPage] trims a query to its first
  ///   page when the last listener leaves.
  /// - [refreshMode]: default for [refresh], the stale refetch of `watch` and
  ///   the refetch of a watched query on [invalidate].
  /// - [maxRefreshPages]: cap for [RefreshMode.allPages].
  /// - [maxItems]: windowing. When a load pushes the list over this size, whole
  ///   pages are dropped from the opposite end and that end's cursor is
  ///   restored, so they can be loaded again. Nothing is trimmed when the
  ///   boundary cursor is unknown. Do not combine with `req.loadedCount`
  ///   offsets (trimmed items are no longer counted); use `req.cursor`.
  /// - [maxUnproductivePages]: how many pages that add nothing new one
  ///   `loadNext`/`loadPrevious` follows before the edge counts as exhausted.
  /// - [storage], [persistWhen], [storageVersion]: optional persistence of the
  ///   first page of each query (items and total, never cursors). A restored
  ///   query is emitted first, marked stale, and revalidated; `loadNext` on it
  ///   refreshes the first page before paging. `evict`/`clearCache` delete the
  ///   persisted entries; LRU/timer eviction only drops memory. Storage errors
  ///   never fail a load.
  /// - [onError]: notified of every fetch failure (also exposed in the state).
  /// - [clock]: injectable time source.
  ReactivePagedManager({
    required this.fetchPage,
    required this.idOf,
    this.maxAge,
    this.maxEntries,
    this.evictAfterUnwatched,
    this.retainWhenUnwatched = Retention.all,
    this.refreshMode = RefreshMode.firstPage,
    this.maxRefreshPages = 10,
    this.maxItems,
    this.maxUnproductivePages = 3,
    this.storage,
    this.persistWhen,
    this.storageVersion = 0,
    this.onError,
    this.clock = DateTime.now,
  }) {
    _checkAtLeastOne(maxEntries, 'maxEntries');
    _checkAtLeastOne(maxRefreshPages, 'maxRefreshPages');
    _checkAtLeastOne(maxItems, 'maxItems');
    _checkAtLeastOne(maxUnproductivePages, 'maxUnproductivePages');
  }

  static void _checkAtLeastOne(int? value, String name) {
    if (value != null && value < 1) {
      throw ArgumentError.value(value, name, 'must be at least 1');
    }
  }

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

  /// Default refresh mode.
  final RefreshMode refreshMode;

  /// Cap for [RefreshMode.allPages].
  final int maxRefreshPages;

  /// Windowing limit.
  final int? maxItems;

  /// Pages that add nothing new followed per call.
  final int maxUnproductivePages;

  /// Optional persistence layer.
  final ReactiveStorage<Q, PagedSnapshot<T>>? storage;

  /// Which queries are persisted (default: all, when [storage] is set).
  final bool Function(Q query)? persistWhen;

  /// Entries persisted with a different version are ignored and deleted.
  final int storageVersion;

  /// Failure callback.
  final void Function(
    Q query,
    PageDirection direction,
    Object error,
    StackTrace stackTrace,
  )? onError;

  /// Time source.
  final DateTime Function() clock;

  late final EntryRegistry<Q, _Entry<T, C>> _entries = EntryRegistry(
    onEvict: _reset, // memory only: persisted entries are kept
    maxEntries: maxEntries,
    evictAfterUnwatched: evictAfterUnwatched,
  );
  late final StorageQueue<Q, PagedSnapshot<T>> _storage =
      StorageQueue(storage, storageVersion);
  late final Freshness _freshness = Freshness(clock, maxAge);
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
        _entries.watch(e);
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
        if (e != null && _entries.unwatch(e) && !_disposed) {
          _unwatched(query, e);
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
  /// the first load when nothing is loaded (or only a restored snapshot is);
  /// a no-op without more pages.
  Future<PagedState<T>> loadNext(Q query) => _loadEdge(query, forward: true);

  /// Loads the page before the head. Same rules as [loadNext].
  Future<PagedState<T>> loadPrevious(Q query) =>
      _loadEdge(query, forward: false);

  /// Refetches the head, keeping the previous items visible (`isRefreshing`).
  /// On failure the previous items stay and the error is in the state. Joins a
  /// running refresh; a different [anchor] or [mode] supersedes it. Aborts
  /// running `loadNext`/`loadPrevious`. See [RefreshMode].
  Future<PagedState<T>> refresh(Q query, {C? anchor, RefreshMode? mode}) {
    if (_disposed) return Future.value(const PagedState());
    final e = _entryFor(query);
    final wanted = mode ?? refreshMode;
    final running = e.head;
    if (running != null && running.anchor == anchor && running.mode == wanted) {
      return running.future;
    }
    return _startHead(e, query, anchor: anchor, mode: wanted).future;
  }

  Future<PagedState<T>> _loadEdge(Q query, {required bool forward}) {
    if (_disposed) return Future.value(const PagedState());
    final e = _entryFor(query);
    final head = e.head;
    if (head != null) return head.future;
    if (!e.hasLoaded || e.hydrated) return _startHead(e, query).future;
    final lane = forward ? e.next : e.prev;
    if (lane != null) return lane.future;
    if (!(forward ? e.nextMore : e.prevMore)) {
      return Future.value(_stateOf(e));
    }
    final op = _Op<T, C>(e.seq);
    e.lanes[forward ? _Lane.next : _Lane.previous] = op;
    if (forward) {
      e.nextError = null;
    } else {
      e.prevError = null;
    }
    _emit(e);
    _runEdge(e, query, op, forward);
    return op.future;
  }

  _Op<T, C> _startHead(
    _Entry<T, C> e,
    Q query, {
    C? anchor,
    RefreshMode? mode,
  }) {
    final op = _Op<T, C>(e.seq, anchor, mode ?? refreshMode);
    for (final old in e.ops) {
      old.discardWith(op.future);
    }
    e.lanes.takeAll();
    e.lanes[_Lane.head] = op;
    e.refreshError = null;
    _emit(e);
    _runHead(e, query, op);
    return op;
  }

  Future<void> _runHead(_Entry<T, C> e, Q query, _Op<T, C> op) async {
    final results = <PageResult<T, C>>[];
    try {
      results.add(await fetchPage(PageRequest<Q, C>(
        query: query,
        direction: PageDirection.initial,
        cursor: op.anchor,
        loadedCount: e.items.length,
        signal: op.signal,
      )));
      if (op.discarded) return;
      if (op.mode == RefreshMode.allPages && e.hasLoaded && !e.hydrated) {
        final wanted =
            e.pages.length < maxRefreshPages ? e.pages.length : maxRefreshPages;
        var loaded = results.first.items.length;
        while (results.length < wanted && results.last.next != null) {
          try {
            final more = await fetchPage(PageRequest<Q, C>(
              query: query,
              direction: PageDirection.next,
              cursor: results.last.next,
              loadedCount: loaded,
              signal: op.signal,
            ));
            if (op.discarded) return;
            loaded += more.items.length;
            results.add(more);
          } on PageCursorExpiredException {
            break; // keep what we have
          }
        }
      }
    } catch (error, stack) {
      if (op.discarded) return;
      _failHead(e, query, op, error, stack);
      return;
    }
    if (op.discarded) return;

    // The apply phase runs user callbacks (`idOf`, replayed transforms). A
    // throw fails this load like a fetch error instead of wedging the lane.
    try {
      _applyHead(e, op, results);
    } catch (error, stack) {
      _failHead(e, query, op, error, stack);
      return;
    }
    e.totalCount = results.last.totalCount ?? results.first.totalCount;
    e.fetchedAt = clock();
    e.stale = false;
    e.hasLoaded = true;
    e.hydrated = false;
    e.refreshError = null;
    e.nextError = null;
    e.prevError = null;
    e.lanes.take(_Lane.head);
    _finishOp(e);
    _persist(query, e);
    _emit(e);
    op.resolve(_stateOf(e));
  }

  /// Ends head load [op] with a failure: the previous items stay, the error
  /// goes to `refreshError` and [onError], and the callers get the state.
  void _failHead(
    _Entry<T, C> e,
    Q query,
    _Op<T, C> op,
    Object error,
    StackTrace stack,
  ) {
    e.lanes.take(_Lane.head);
    e.refreshError = PagedError(error, stack);
    _finishOp(e);
    _emit(e);
    _report(query, PageDirection.initial, error, stack);
    op.resolve(_stateOf(e));
  }

  /// Replaces (or splices into) the entry's list with a fresh head load.
  void _applyHead(
    _Entry<T, C> e,
    _Op<T, C> op,
    List<PageResult<T, C>> results,
  ) {
    final first = results.first;
    final replay = e.edits.where((x) => x.seq > op.startSeq).toList();

    if (op.mode == RefreshMode.mergeHead &&
        e.hasLoaded &&
        !e.hydrated &&
        results.length == 1) {
      final fresh = _dedupe(first.items);
      final lastId = fresh.isEmpty ? null : idOf(fresh.last);
      final at =
          lastId == null ? -1 : e.items.indexWhere((x) => idOf(x) == lastId);
      if (at >= 0) {
        for (final edit in replay) {
          _applyEdit(fresh, edit);
        }
        final freshCount = fresh.length;
        final rest = _dropFront(e.pages, at + 1);
        if (rest.isNotEmpty) rest.first.previous = null; // boundary unknown
        final pages = <_Page<C>>[
          _Page<C>(
            freshCount,
            first.previous,
            rest.isEmpty ? e.nextCursor : null,
          ),
          ...rest,
        ];
        e.items = _dedupe([...fresh, ...e.items.sublist(at + 1)]);
        e.pages = pages;
        e.prevCursor = first.previous;
        e.prevMore = first.previous != null;
        _normalizePages(e);
        return;
      }
    }

    final seen = <Object>{};
    final list = <T>[];
    final pages = <_Page<C>>[];
    for (final r in results) {
      var count = 0;
      for (final item in r.items) {
        final id = idOf(item);
        if (id == null || seen.add(id)) {
          list.add(item);
          count++;
        }
      }
      pages.add(_Page<C>(count, r.previous, r.next));
    }
    for (final edit in replay) {
      _applyEdit(list, edit);
    }
    e.items = list;
    e.pages = pages;
    e.nextCursor = results.last.next;
    e.nextMore = results.last.next != null;
    e.prevCursor = first.previous;
    e.prevMore = first.previous != null;
    _normalizePages(e);
  }

  /// Copies [pages] without their first [n] items.
  List<_Page<C>> _dropFront(List<_Page<C>> pages, int n) {
    var left = n;
    final out = <_Page<C>>[];
    for (final page in pages) {
      if (left >= page.count) {
        left -= page.count;
        continue;
      }
      out.add(_Page<C>(page.count - left, page.previous, page.next));
      left = 0;
    }
    return out;
  }

  /// Keeps the page counts consistent with the list. When local edits or
  /// dedupe made them drift, the pages collapse into one (no windowing
  /// granularity, cursors are kept).
  void _normalizePages(_Entry<T, C> e) {
    final sum = e.pages.fold<int>(0, (a, p) => a + p.count);
    if (sum != e.items.length || e.pages.isEmpty) {
      e.pages = [_Page<C>(e.items.length, e.prevCursor, e.nextCursor)];
    }
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
    // Raw items of the pages this call followed that added nothing: they are
    // part of `loadedCount` so offset-based fetchers keep moving forward.
    var consumed = 0;

    void clearLane() => e.lanes.take(forward ? _Lane.next : _Lane.previous);

    void fail(Object error, StackTrace stack) {
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
    }

    // The apply phase runs user callbacks (`idOf`, replayed transforms). A
    // throw fails this load like a fetch error instead of wedging the lane.
    try {
      while (true) {
        PageResult<T, C> result;
        try {
          result = await fetchPage(PageRequest<Q, C>(
            query: query,
            direction: direction,
            cursor: cursor,
            loadedCount: e.items.length + consumed,
            signal: op.signal,
          ));
        } on PageCursorExpiredException {
          if (op.discarded) return;
          // Always a first-page refresh, whatever the default refreshMode: a
          // mergeHead splice would keep the expired tail cursor and allPages
          // would follow it. Discards this op and resolves it with the head.
          _startHead(e, query, mode: RefreshMode.firstPage);
          return;
        } catch (error, stack) {
          if (op.discarded) return;
          fail(error, stack);
          return;
        }
        if (op.discarded) return;

        final added = _mergeEdge(e, result.items, forward, op.startSeq);
        final following = forward ? result.next : result.previous;
        if (added > 0) {
          final page = _Page<C>(added, result.previous, result.next);
          forward ? e.pages.add(page) : e.pages.insert(0, page);
        } else if (e.pages.isNotEmpty) {
          // Nothing new: only the cursor moved on.
          if (forward) {
            e.pages.last.next = following;
          } else {
            e.pages.first.previous = following;
          }
        }
        if (forward) {
          e.nextCursor = following;
          e.nextMore = following != null;
        } else {
          e.prevCursor = following;
          e.prevMore = following != null;
        }
        if (result.totalCount != null) e.totalCount = result.totalCount;

        if (following != null &&
            following == cursor &&
            (added > 0 || result.items.isEmpty)) {
          // The cursor did not move and the next request would repeat this
          // one: it would loop forever. (A page of duplicates with the same
          // cursor is followed, bounded below: its items advance
          // `loadedCount`, which offset-based fetchers use.)
          if (forward) {
            e.nextMore = false;
          } else {
            e.prevMore = false;
          }
        } else if (added == 0 && following != null) {
          if (++unproductive < maxUnproductivePages) {
            cursor = following;
            consumed += result.items.length;
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

      _normalizePages(e);
      _window(e, forward);
    } catch (error, stack) {
      fail(error, stack);
      return;
    }
    clearLane();
    _finishOp(e);
    _emit(e);
    op.resolve(_stateOf(e));
  }

  /// Drops whole pages from the end opposite to the last load while the list
  /// is over [maxItems]. Only when the boundary cursor is known.
  void _window(_Entry<T, C> e, bool forward) {
    final limit = maxItems;
    if (limit == null) return;
    while (e.items.length > limit && e.pages.length > 1) {
      if (forward) {
        final boundary = e.pages[1].previous;
        if (boundary == null) return;
        final dropped = e.pages.removeAt(0);
        e.items.removeRange(0, dropped.count);
        e.prevCursor = boundary;
        e.prevMore = true;
      } else {
        final boundary = e.pages[e.pages.length - 2].next;
        if (boundary == null) return;
        final dropped = e.pages.removeLast();
        e.items.removeRange(e.items.length - dropped.count, e.items.length);
        e.nextCursor = boundary;
        e.nextMore = true;
      }
    }
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
      if (edit.kind == _EditKind.patch || edit.kind == _EditKind.remove) {
        _applyEdit(fresh, edit);
      }
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

  /// Applies [edit] to [list]. With [track], the entry's page counts follow.
  /// Returns whether anything changed.
  bool _applyEdit(List<T> list, _Edit<T> edit, [_Entry<T, C>? track]) {
    void removeAt(int i) {
      list.removeAt(i);
      if (track != null) _trackRemove(track, i);
    }

    void insertAt(int i, T item) {
      list.insert(i, item);
      if (track != null) _trackInsert(track, i);
    }

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
        var changed = false;
        for (var i = list.length - 1; i >= 0; i--) {
          if (idOf(list[i]) == edit.id) {
            removeAt(i);
            changed = true;
          }
        }
        return changed;
      case _EditKind.upsert:
        final item = edit.item as T;
        final at =
            edit.id == null ? -1 : list.indexWhere((x) => idOf(x) == edit.id);
        if (at >= 0) {
          if (!edit.move) {
            list[at] = item;
            return true;
          }
          removeAt(at);
        }
        insertAt(edit.atHead ? 0 : list.length, item);
        return true;
      case _EditKind.insertAt:
        final item = edit.item as T;
        if (edit.id != null && list.any((x) => idOf(x) == edit.id)) {
          return false; // already back
        }
        var at = edit.index;
        if (edit.afterId != null) {
          final after = list.indexWhere((x) => idOf(x) == edit.afterId);
          if (after >= 0) at = after + 1;
        }
        insertAt(at.clamp(0, list.length), item);
        return true;
    }
  }

  void _trackRemove(_Entry<T, C> e, int index) {
    var start = 0;
    for (final page in e.pages) {
      if (index < start + page.count) {
        page.count--;
        return;
      }
      start += page.count;
    }
  }

  void _trackInsert(_Entry<T, C> e, int index) {
    if (e.pages.isEmpty) return;
    var start = 0;
    for (final page in e.pages) {
      if (index < start + page.count) {
        page.count++;
        return;
      }
      start += page.count;
    }
    e.pages.last.count++;
  }

  void _record(_Entry<T, C> e, _Edit<T> edit) {
    if (!e.lanes.isEmpty) e.edits.add(edit);
  }

  /// Drops edits no in-flight request can still need.
  void _finishOp(_Entry<T, C> e) {
    if (e.lanes.isEmpty) {
      e.edits.clear();
      return;
    }
    final oldest =
        e.lanes.all.map((o) => o.startSeq).reduce((a, b) => a < b ? a : b);
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
    for (final entry in _entries.snapshot()) {
      if (where != null && !where(entry.key)) continue;
      final e = entry.value;
      final edit = _Edit<T>.patch(++e.seq, id, transform);
      final changed = _applyEdit(e.items, edit, e);
      _record(e, edit); // also when nothing changed: a response may need it
      if (changed) _emit(e);
    }
  }

  /// Removes the item with [id] from every cached query (or those matching
  /// [where]) and decrements `totalCount`. Emits only for queries that changed.
  void removeItem(Object id, {bool Function(Q query)? where}) {
    for (final entry in _entries.snapshot()) {
      if (where != null && !where(entry.key)) continue;
      final e = entry.value;
      final edit = _Edit<T>.remove(++e.seq, id);
      final changed = _applyEdit(e.items, edit, e);
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
    _applyEdit(e.items, edit, e);
    if (!present) {
      final total = e.totalCount;
      if (total != null) e.totalCount = total + 1;
    }
    _record(e, edit);
    _emit(e);
  }

  // --- optimistic mutation -------------------------------------------------

  /// Runs [action] with optimistic edits.
  ///
  /// [optimistic] applies edits through [PagedEdits] immediately. If [action]
  /// fails, they are undone (a patch is restored only when the item is still
  /// the one that was written; a removed item is re-inserted after its former
  /// predecessor; an inserted item is removed) and the error is rethrown.
  /// Whatever the outcome, every touched query is invalidated (a watched one
  /// refetches), and so is every query matching [invalidateAfter] — a failed
  /// mutation may have been partly applied.
  ///
  /// Unlike the loading methods this one rethrows: it is a mutation, not a
  /// load. An `upsertItem` whose `move` relocated an item is undone by value,
  /// not by position.
  Future<R> mutate<R>(
    Future<R> Function() action, {
    void Function(PagedEdits<Q, T> edits)? optimistic,
    bool Function(Q query)? invalidateAfter,
  }) async {
    final undo = <void Function()>[];
    final touched = <Q>{};
    final edits = PagedEdits<Q, T>._(
      (id, f, where) => _patchRecorded(id, f, where, undo, touched),
      (id, where) => _removeRecorded(id, where, undo, touched),
      (q, item, at, move) => _upsertRecorded(q, item, at, move, undo, touched),
    );
    try {
      optimistic?.call(edits);
      return await action();
    } catch (_) {
      for (final step in undo.reversed) {
        step();
      }
      rethrow;
    } finally {
      for (final q in touched) {
        invalidate(q);
      }
      if (invalidateAfter != null) invalidateWhere(invalidateAfter);
    }
  }

  void _patchRecorded(
    Object id,
    T Function(T) transform,
    bool Function(Q)? where,
    List<void Function()> undo,
    Set<Q> touched,
  ) {
    for (final key in List.of(_entries.keys)) {
      if (where != null && !where(key)) continue;
      final pairs = <(T, T)>[];
      var recording = true;
      patchItem(id, (current) {
        final next = transform(current);
        if (recording) pairs.add((current, next));
        return next;
      }, where: (q) => q == key);
      recording = false;
      if (pairs.isEmpty) continue;
      touched.add(key);
      undo.add(() {
        for (final (old, written) in pairs) {
          patchItem(id, (cur) => cur == written ? old : cur,
              where: (q) => q == key);
        }
      });
    }
  }

  void _removeRecorded(
    Object id,
    bool Function(Q)? where,
    List<void Function()> undo,
    Set<Q> touched,
  ) {
    for (final entry in _entries.snapshot()) {
      final key = entry.key;
      if (where != null && !where(key)) continue;
      final items = entry.value.items;
      final at = items.indexWhere((x) => idOf(x) == id);
      if (at < 0) continue;
      final item = items[at];
      final afterId = at > 0 ? idOf(items[at - 1]) : null;
      removeItem(id, where: (q) => q == key);
      touched.add(key);
      undo.add(() => _insertAt(key, item, afterId, at));
    }
  }

  void _upsertRecorded(
    Q query,
    T item,
    PagedEnd at,
    bool move,
    List<void Function()> undo,
    Set<Q> touched,
  ) {
    final e = _entries[query];
    if (e == null) return;
    final id = idOf(item);
    final before = id == null ? -1 : e.items.indexWhere((x) => idOf(x) == id);
    final old = before >= 0 ? e.items[before] : null;
    final length = e.items.length;
    upsertItem(query, item, at: at, move: move);
    if (id == null) return; // no identity: cannot be undone
    if (before >= 0) {
      touched.add(query);
      undo.add(() => patchItem(id, (cur) => cur == item ? old as T : cur,
          where: (q) => q == query));
    } else if (e.items.length > length) {
      touched.add(query);
      undo.add(() {
        final current = _entries[query]?.items;
        if (current != null && current.any((x) => idOf(x) == id && x == item)) {
          removeItem(id, where: (q) => q == query);
        }
      });
    }
  }

  void _insertAt(Q query, T item, Object? afterId, int index) {
    final e = _entries[query];
    if (e == null) return;
    final edit = _Edit<T>.insertAt(++e.seq, idOf(item), item, afterId, index);
    if (_applyEdit(e.items, edit, e)) {
      final total = e.totalCount;
      if (total != null) e.totalCount = total + 1;
      _record(e, edit);
      _emit(e);
    }
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
    for (final entry in _entries.snapshot()) {
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
    final state = _stateOf(e, idle: true);
    for (final op in e.ops) {
      op.discardWith(state);
    }
    e.lanes.takeAll();
    _finishOp(e);
    _emit(e);
  }

  // --- lifecycle -----------------------------------------------------------

  /// Resets [query]: in-flight loads are discarded, the cache and the
  /// persisted entry are dropped. Listeners stay subscribed and receive an
  /// empty idle state; nothing is refetched automatically.
  void evict(Q query) {
    final e = _entries[query];
    if (e != null) _reset(query, e);
    _storage.delete(query);
  }

  /// [evict] for every query (e.g. on logout), including persisted entries.
  void clearCache() {
    for (final entry in _entries.snapshot()) {
      _reset(entry.key, entry.value);
    }
    _storage.clear();
  }

  void _reset(Q query, _Entry<T, C> e) {
    final ops = e.ops;
    e.lanes.takeAll();
    e.items = [];
    e.pages = [];
    e.hasLoaded = false;
    e.hydrated = false;
    e.hydrationToken = ++_tick;
    e.nextCursor = e.prevCursor = null;
    e.nextMore = e.prevMore = false;
    e.totalCount = null;
    e.fetchedAt = null;
    e.stale = false;
    e.refreshError = e.nextError = e.prevError = null;
    e.edits.clear();
    final state = _stateOf(e);
    for (final op in ops) {
      op.discardWith(state);
    }
    if (e.watchers > 0) {
      _emit(e);
    } else {
      _remove(query, e);
    }
  }

  void _remove(Q query, _Entry<T, C> e) {
    _entries.remove(query, e);
    e.subject.close();
  }

  /// Aborts everything, cancels timers, closes streams. Pending futures
  /// resolve. Later calls do nothing.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.snapshot()) {
      final e = entry.value;
      final state = _stateOf(e, idle: true);
      for (final op in e.ops) {
        op.discardWith(state);
      }
      e.lanes.takeAll();
      _entries.cancelEviction(e);
      await e.subject.close();
    }
    _entries.clear();
  }

  // --- persistence ---------------------------------------------------------

  /// Whether [query] is persisted. A throwing [persistWhen] counts as "no"
  /// and is reported to [onError]; it never fails a load.
  bool _persists(Q query) {
    if (storage == null) return false;
    final when = persistWhen;
    if (when == null) return true;
    try {
      return when(query);
    } catch (error, stack) {
      _report(query, PageDirection.initial, error, stack);
      return false;
    }
  }

  void _persist(Q query, _Entry<T, C> e) {
    if (!_persists(query)) return;
    final count = e.pages.isEmpty ? e.items.length : e.pages.first.count;
    final snapshot = PagedSnapshot<T>(
      List<T>.of(e.items.take(count)),
      totalCount: e.totalCount,
    );
    _storage.write(query, snapshot, e.fetchedAt!);
  }

  Future<void> _hydrate(Q query, _Entry<T, C> e) async {
    if (!_persists(query)) return;
    final token = e.hydrationToken = ++_tick;
    final stored = await _storage.read(query);
    if (stored == null) return;
    // Evicted, reset or disposed while reading: drop the result.
    if (_disposed ||
        !_entries.isCurrent(query, e) ||
        e.hydrationToken != token) {
      return;
    }
    if (!_storage.accept(query, stored)) return;
    if (e.hasLoaded) return; // the network was faster
    final list = List<T>.of(stored.value.items);
    e.items = list;
    e.pages = [_Page<C>(list.length, null, null)];
    e.hasLoaded = true;
    e.hydrated = true;
    e.fetchedAt = stored.fetchedAt;
    e.totalCount = stored.value.totalCount;
    _emit(e);
  }

  // --- internals -----------------------------------------------------------

  _Entry<T, C> _entryFor(Q query) {
    final existing = _entries[query];
    if (existing != null) return existing;
    final e = _Entry<T, C>(BehaviorSubject<PagedState<T>>());
    _entries[query] = e;
    e.subject.add(_stateOf(e));
    _hydrate(query, e);
    // Created by a call, not a watch: it counts as unwatched from now on.
    _unwatched(query, e);
    return e;
  }

  void _unwatched(Q query, _Entry<T, C> e) {
    if (retainWhenUnwatched == Retention.firstPage &&
        e.hasLoaded &&
        e.pages.length > 1) {
      final first = e.pages.first;
      for (final op in [e.next, e.prev].whereType<_Op<T, C>>()) {
        op.discardWith(_stateOf(e, idle: true));
      }
      e.lanes.take(_Lane.next);
      e.lanes.take(_Lane.previous);
      e.items = e.items.sublist(0, first.count);
      e.pages = [first];
      e.nextCursor = first.next;
      e.nextMore = first.next != null;
      _emit(e);
    }
    _entries.unwatched(query, e);
  }

  bool _isStale(_Entry<T, C> e) {
    return e.stale || e.hydrated || _freshness.isExpired(e.fetchedAt);
  }

  /// The state of [e]. With [idle], as if nothing were in flight (the state
  /// handed to the callers of discarded loads).
  PagedState<T> _stateOf(_Entry<T, C> e, {bool idle = false}) => PagedState<T>(
        items: List<T>.unmodifiable(e.items),
        hasLoaded: e.hasLoaded,
        isRefreshing: !idle && e.head != null,
        refreshError: e.refreshError,
        next: PagedEdge(
          hasMore: e.nextMore,
          isLoading: !idle && e.next != null,
          error: e.nextError,
        ),
        previous: PagedEdge(
          hasMore: e.prevMore,
          isLoading: !idle && e.prev != null,
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
