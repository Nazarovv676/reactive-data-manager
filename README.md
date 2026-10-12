# Reactive Data Manager

A Flutter package that provides a robust, reactive data management solution with built-in caching, optimistic updates, and error handling capabilities.

## Features

- 🔄 Reactive data streams
- 💾 Automatic caching
- ⚡ Optimistic updates
- 🔍 Data filtering
- ❌ Error handling
- 🧹 Automatic resource cleanup
- 🤝 In-flight de-duplication (concurrent calls share one fetch)
- ⏱️ Freshness (`maxAge`), invalidation, `refresh`, `watch`, `mutate`
- 🧩 `ReactiveValue` for keyless values, abortable fetches, typed errors
- 💽 Optional persistence (stale-while-revalidate across restarts)
- 📜 `ReactivePagedManager` for paginated lists (pagination, dedupe, cross-query patching, eviction)

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
    reactive_data_manager: ^2.0.0
```

## Basic Usage

```dart
// Create a manager instance
final userManager = ReactiveDataManager<int, User>(
    fetcher: (id) => fetchUserFromApi(id),
    updater: (id, user) => updateUserInApi(id, user),
);

// Get data stream
Stream<User?> userStream = userManager.getStream(userId);

// Fetch or refresh data
User user = await userManager.getData(userId);

// Force refresh
User freshUser = await userManager.getData(userId, forceRefresh: true);

// Update data
await userManager.updateData(userId, updatedUser);
```

## Advanced Usage

### With Data Filtering

```dart
ReactiveDataManager<String, Data>(
    fetcher: fetchData,
    updater: updateData,
    fetchFilter: (key, data) {
        // Filter fetched data
        return data.isValid ? data : null;
    },
    updateFilter: (key, result) {
        // Filter update results
        return result.success ? result.data : null;
    },
);
```

### In Flutter Widgets

```dart
StreamBuilder<User?>(
    stream: userManager.getStream(userId),
    builder: (context, snapshot) {
        if (snapshot.hasError) {
            return ErrorWidget(snapshot.error!);
        }
        
        if (!snapshot.hasData) {
            return LoadingWidget();
        }
        
        return UserWidget(user: snapshot.data!);
    },
);
```

## Concurrency and freshness

Concurrent `getData(key)` calls join one fetch: the fetcher runs once and every
caller completes with the same value or error. Only `forceRefresh: true` starts
a new fetch; callers of the superseded fetch complete with the newer result. A
cached read never touches an in-flight fetch.

```dart
final manager = ReactiveDataManager<int, User>(
    fetcher: fetchUser,
    maxAge: const Duration(seconds: 20), // default freshness (optional)
    clock: DateTime.now,                  // injectable for tests
);

await manager.getData(id);                          // fetch or join
await manager.getData(id, maxAge: Duration.zero);   // per-call override
manager.fetchedAt(id);                              // DateTime?
manager.isFresh(id);                                // bool
```

### Invalidate, refresh, watch, mutate

```dart
manager.invalidate(id);   // keep the value visible, refetch on next read;
manager.invalidateAll();  // results of fetches started before are discarded

manager.refresh(id);      // fire-and-forget, errors only via the stream

// Non-null stream; fetches when missing/stale, skips `null` events.
Stream<User> user = manager.watch(id);

// Runs the action, then invalidates the key even if the action failed.
await manager.mutate(id, () => api.rename(id, 'Ann'));
```

`clearCache()` and `evict(key)` also discard in-flight fetches, so a late
response can never repopulate the cache after a logout.

### `set` and `patch`

Plain cache writes without an updater, rollback or `Future`:

```dart
manager.set(id, user);                              // writes and emits synchronously
manager.patch(id, (u) => u.copyWith(name: 'Ann'));  // no-op when not cached
```

Both discard a fetch that is in flight, so an older response never overwrites
the value you just wrote. `set` marks the entry fresh; `patch` keeps its
invalidated state.

`updateData` follows the same rule: a fetch that started before the update
never overwrites the optimistic value (its callers still get its result). If
the updater fails, the previous value is restored only when nothing wrote the
key since the update started; a newer `set`/`patch`, a fetch started during
the update or a newer `updateData` wins. `evict`, `clearCache` and `dispose`
cancel running updates: they complete with their own result and never roll
back.

### Errors

`BehaviorSubject` replays the last error to late subscribers. Pass
`replayErrors: false` to deliver errors only to current listeners. Use
`errorMapper` to surface typed failures without wrapping/unwrapping:

```dart
ReactiveDataManager<int, User>(
    fetcher: fetchUser,
    replayErrors: false,
    errorMapper: (error, stack) => Failure.from(error), // stream + getData
);
```

### Abortable fetches

```dart
ReactiveDataManager<int, User>.cancellable(
    fetcher: (id, cancel) {
        final token = CancelToken();
        cancel.then((_) => token.cancel()); // superseded/evicted/cleared/disposed
        return api.getUser(id, cancelToken: token);
    },
);
```

The signal fires when the fetch is superseded (`forceRefresh`/`refresh`; its
callers then complete with the newer result), or when its key is evicted,
cleared or the manager disposed. In the latter cases callers still waiting
on `getData` complete with the fetcher's own outcome, i.e. **the fetcher's
cancellation error** (e.g. `DioException.cancel`) if it honours the signal.
`invalidate`, `set` and `patch` (and their `Where`/`All` variants) do not fire
it: the request finishes, waiting callers get its result, and the result is
not cached.

The base fetcher gets a bare `Future<void> cancel`, while the paged fetcher
gets an `AbortSignal` (`req.signal.whenAborted`, `req.signal.aborted`) inside
its `PageRequest`; both complete/abort under the same rules.

### Cross-key operations

`invalidateWhere((key) => ...)` and `patchWhere((key, value) => newValueOrNull)`
act on every cached key, e.g. for per-page caches where one item lives under
several keys.

### Keyless values

`ReactiveValue<T>` has the same API without a key parameter:

```dart
final me = ReactiveValue<User>(
    fetcher: api.me,
    maxAge: const Duration(minutes: 5),
);
final user = await me.getData();
me.watch().listen(print);
```

With `storage`, a value is persisted under `storageKey` (default `'value'`).
Values that share one storage adapter need distinct keys, e.g.
`ReactiveValue<User>(..., storage: prefsStorage, storageKey: 'me')`; `clear()`
deletes only that key.

### Persistence

Pass a `ReactiveStorage` to keep values across restarts. On the first
`getData`/`watch`/`getStream` of a key with nothing in memory the stored value
is emitted with its original `fetchedAt`: fresh means no network, stale means
emit then refetch (`watch(fetch: false)` and `getStream` only restore, they
never fetch). Values are written after every successful fetch, `set`, `patch`
and `updateData` (including rollback); `evict` and `clearCache` delete the
persisted entries, and a read issued after them never sees the deleted
entry. `invalidate`, `invalidateWhere` and `invalidateAll` also mark values
that are restored later (if they were stored before the call). Storage errors
(also synchronous throws) never fail `getData`. Bump `storageVersion` after a
model change to ignore old entries.

Storage operations run in call order: a read waits for the writes, deletes and
clears queued before it. `getData` waits for the read of a key it restores, so
an adapter whose `read` (or an earlier `write`) never completes delays
`getData` for that key; keep adapters bounded (e.g. with their own timeout).

```dart
final manager = ReactiveDataManager<int, User>(
    fetcher: fetchUser,
    maxAge: const Duration(hours: 1),
    storage: PrefsStorage(prefs),
    storageVersion: 1,
);
```

`InMemoryReactiveStorage` is provided for tests. A `SharedPreferences` adapter
(serialization stays with you):

```dart
class PrefsStorage implements ReactiveStorage<int, User> {
    PrefsStorage(this.prefs);
    final SharedPreferences prefs;

    @override
    Future<StoredEntry<User>?> read(int key) async {
        final raw = prefs.getString('user_$key');
        if (raw == null) return null;
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return StoredEntry(
            User.fromJson(json['value']),
            DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
            version: json['v'] as int,
        );
    }

    @override
    Future<void> write(int key, StoredEntry<User> e) => prefs.setString(
        'user_$key',
        jsonEncode({
            'value': e.value.toJson(),
            'at': e.fetchedAt.millisecondsSinceEpoch,
            'v': e.version,
        }),
    );

    @override
    Future<void> delete(int key) => prefs.remove('user_$key');

    @override
    Future<void> clear() async {
        for (final k in prefs.getKeys().where((k) => k.startsWith('user_'))) {
            await prefs.remove(k);
        }
    }
}
```

## Paginated lists

`ReactivePagedManager<Q, T, C>` keeps **one accumulated list per query** `Q`
(filters, sort, ...; it needs value equality and must *not* contain the page).
`C` is an opaque cursor (page number, offset, token): the package never
interprets it, `null` means "no more in that direction".

```dart
final events = ReactivePagedManager<EventQuery, Event, int>(
    idOf: (e) => e.id,                       // dedupe, patchItem, removeItem
    maxAge: const Duration(minutes: 2),
    maxEntries: 5,                           // LRU over unwatched queries
    evictAfterUnwatched: const Duration(seconds: 30),
    onError: (q, direction, error, stack) => report(error, stack),
    fetchPage: (req) async {
        final page = req.cursor ?? 1;
        final r = await api.events(req.query, page: page);
        return PageResult(
            r.items,
            next: r.hasNext ? page + 1 : null,
            previous: page > 1 ? page - 1 : null,
            totalCount: r.total,
        );
    },
);

// UI: one immutable state value, errors included.
events.watch(query).listen((PagedState<Event> s) {
    s.items;              // unmodifiable, never cleared by an error
    s.hasLoaded;          // "nothing yet" vs "loaded, empty"
    s.isRefreshing;       // initial load / refresh in flight (items stay)
    s.refreshError;       // last initial/refresh failure
    s.next.hasMore;       // also: s.next.isLoading, s.next.error
    s.previous;           // same for loadPrevious
    s.totalCount; s.fetchedAt; s.isStale;
});

await events.loadNext(query);    // joins an in-flight loadNext; no-op without more pages
await events.refresh(query);     // first page; previous items stay visible
events.patchItem(id, (e) => e.copyWith(liked: true)); // in EVERY cached query
events.removeItem(id);
events.upsertItem(query, event); // e.g. a socket message (head/tail, move: true)
events.loadPrevious(query);      // bidirectional feeds (chat history, jump-to)
events.refresh(query, mode: RefreshMode.mergeHead); // see "Refresh modes"
await events.mutate(                 // optimistic edits with rollback
    () => api.like(id),
    optimistic: (e) => e.patchItem(id, (x) => x.copyWith(liked: true)),
);
events.invalidate(query);        // watched: refetch now; otherwise mark stale
events.evict(query);
events.clearCache();             // logout: discards in-flight loads
await events.dispose();
```

Rules worth knowing:

- Loading futures **never throw and never hang**. They resolve to the state
  after the operation (or after the one that superseded them); failures are in
  the state (`refreshError`, `next.error`) and in `onError`. Late subscribers
  get the state, not a replayed error.
- `PagedState` (and `PagedEdge`, `PagedError`) have value equality; a state
  equal to the previous one is never emitted.
- Concurrent `loadNext` calls share one request. `loadNext` during a refresh
  joins it, so a page is never appended to a list that is being replaced.
  `refresh` aborts running `loadNext`/`loadPrevious`.
- A load that started before `invalidate`, `refresh`, `evict` or `clearCache`
  never writes its page. Its request gets an aborted `req.signal` (wire it to
  Dio's `CancelToken`).
- Local edits made while a request is in flight are re-applied onto its
  response (patches, removals, inserts), so an older page cannot undo them.
- Pages are merged by `idOf`: an id that is already present keeps its position
  and takes the new value, which absorbs the duplicates that offset pagination
  produces when the list shifts. Items whose `idOf` is `null` are never
  deduped.
- Offset APIs: the simplest recipe for `next` is `offset = req.cursor ?? 0`
  with `next: offset + items.length` (the cursor *is* the offset).
  Alternatively `offset = req.loadedCount`, the number of items held, which
  self-heals when items were removed locally. Within one
  `loadNext`/`loadPrevious` it also counts the raw items of followed pages
  that added nothing new, so the offset moves past a page of duplicates (e.g.
  after `limit` or more items were inserted at the head); the price is one
  extra request per load while the list is shifted.
- A page that adds nothing new is followed up to `maxUnproductivePages` (3)
  times, then the edge counts as exhausted. A `next` cursor equal to the one
  just requested exhausts it immediately when the page added items or was
  empty (a page of duplicates is followed, bounded by `maxUnproductivePages`,
  because it advances `loadedCount`). Throw `PageCursorExpiredException`
  from the fetcher to refresh the first page instead of failing; that
  recovery is always a `RefreshMode.firstPage` refresh, whatever the
  `refreshMode`.
- `upsertItem` inserts an *absent* item only if that end is fully loaded
  (`at: head` needs no previous page), otherwise it is ignored. Nothing counts
  as fully loaded before the first page arrived or while a restored snapshot
  is not revalidated yet. An insert made during a refresh is re-checked
  against the cursors of the refreshed page.
- Unwatched queries: `maxEntries` evicts the least recently watched one,
  `evictAfterUnwatched` evicts after a timer that re-watching cancels, and
  `retainWhenUnwatched: Retention.firstPage` trims to the first page.
  Watched queries are never evicted; `evict`/`clearCache` reset them in place
  and keep their streams open.
- `maxEntries`, `maxItems`, `maxRefreshPages` and `maxUnproductivePages` must
  be at least 1 (`null` for no limit where allowed); smaller values throw an
  `ArgumentError`. To keep no unwatched query at all, use a short
  `evictAfterUnwatched` instead of `maxEntries: 0`.

### Refresh modes

`refresh(query, mode: ...)` (or the constructor's `refreshMode`):

- `RefreshMode.firstPage` (default): replaces the whole window with the fresh
  first page.
- `RefreshMode.allPages`: re-fetches as many pages as are loaded (capped by
  `maxRefreshPages`, default 10) along the *new* cursors, then swaps atomically.
  A failure keeps the old window and sets `refreshError`.
- `RefreshMode.mergeHead`: for feeds. Fetches the head page and splices it in
  front of the loaded items, keeping the tail cursor. If the fresh page does not
  overlap with what is loaded there is a gap, so it behaves like `firstPage`.
  Typical use: `socket.onReconnect(() => feed.refresh(q, mode: RefreshMode.mergeHead))`.

`refresh(query, anchor: cursor)` loads around an anchor ("jump to"): the cursor
is passed to the fetcher with `PageDirection.initial`.

### Windowing

`maxItems: 600` keeps long feeds bounded: when a load pushes the list over the
limit, whole pages are dropped from the opposite end and that end's cursor is
restored from the retained boundary page, so they can be loaded again with
`loadPrevious`/`loadNext`. Nothing is trimmed when the boundary cursor is
unknown. Don't combine it with `req.loadedCount` offsets; use `req.cursor`.

### Optimistic mutations

```dart
await feed.mutate(
    () => api.deleteMessage(id),
    optimistic: (e) => e.removeItem(id),    // also patchItem / upsertItem
    invalidateAfter: (q) => q.userId == me, // optional extra invalidation
);
```

The edits apply immediately. If the action fails they are undone (a patch is
restored only if the item is still the one that was written, a removed item is
re-inserted after its former predecessor, an inserted item is removed) and the
error is rethrown. Whatever the outcome, every touched query is invalidated,
because a failed mutation may have been partly applied.

### Persistence of lists

```dart
ReactivePagedManager<EventQuery, Event, int>(
    ...,
    storage: myStorage,                 // ReactiveStorage<EventQuery, PagedSnapshot<Event>>
    persistWhen: (q) => q.isDefault,    // default: every query
    storageVersion: 1,
);
```

The first page (items and total, never cursors) is written after each
successful head load. On the first use of a query the stored page is emitted
immediately with its original `fetchedAt`, marked `isStale`, and revalidated;
`loadNext` on a restored query refreshes the first page before paging. A faster
network result wins over a slower read. `evict`/`clearCache` delete persisted
entries (logout); LRU/timer eviction only frees memory. Storage errors never
fail a load.

### Testing

`package:reactive_data_manager/testing.dart` has `ScriptedPageFetcher`: a
fetcher whose requests you complete by hand, in any order, with a request log.

```dart
final pages = ScriptedPageFetcher<String, Item, int>();
final manager = ReactivePagedManager<String, Item, int>(
    fetchPage: pages.call, idOf: (i) => i.id);

final f = manager.loadNext('q');
pages.completeLast([item], next: 2); // or pages.complete(0, ...), pages.fail(0, e)
await f;
```

Mapping common servers to the cursor contract: page + `hasNext` ->
`next: hasNext ? page + 1 : null`; offset -> `next: items.length < limit ?
null : offset + items.length`; opaque token / Relay -> `next: endCursor` or
`null`; no flag at all -> `next: items.isEmpty ? null : page + 1` (one extra
request at the end).

**Migrating from `ReactiveDataManager` keyed by query + manual merge:** drop the
key-stripping helper, the `getCurrentValue` -> API -> `updateData` merge in
`loadNext`, the `isLoadingMore`/`hasNext`/`page` mirrors in your view model, and
the "pending eviction" timer. Put the query into `Q`, the request into
`fetchPage`, and read `items`, `next.hasMore`, `next.isLoading` from the state.
Per-item patches become `patchItem(id, ...)`, which also reaches the other
cached queries.

## Cleanup

Don't forget to dispose of the manager when it's no longer needed. After
`dispose()` storage is never touched again (`evict`/`clearCache` on a disposed
paged manager do nothing; on a disposed `ReactiveDataManager` they only drop
memory):

```dart
@override
void dispose() {
    userManager.dispose();
    super.dispose();
}
```

## License

MIT License - see the [LICENSE](LICENSE) file for details
