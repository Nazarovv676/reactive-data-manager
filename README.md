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
    reactive_data_manager: ^1.3.0
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
        cancel.then((_) => token.cancel()); // superseded/invalidated/cleared
        return api.getUser(id, cancelToken: token);
    },
);
```

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

### Persistence

Pass a `ReactiveStorage` to keep values across restarts. On the first
`getData`/`watch` of a key with nothing in memory the stored value is emitted
immediately with its original `fetchedAt`: fresh means no network, stale means
emit then refetch. Values are written after every successful fetch, `set`,
`patch` and `updateData` (including rollback); `evict` and `clearCache` delete
the persisted entries. Storage errors never fail `getData`. Bump
`storageVersion` after a model change to ignore old entries.

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
  deduped. `req.loadedCount` lets offset APIs use `offset = loadedCount`.
- A page that adds nothing new is followed up to `maxUnproductivePages` (3)
  times, then the edge counts as exhausted. A `next` cursor equal to the one
  just requested exhausts it immediately. Throw `PageCursorExpiredException`
  from the fetcher to refresh the first page instead of failing.
- `upsertItem` inserts an *absent* item only if that end is fully loaded
  (`at: head` needs no previous page), otherwise it is ignored.
- Unwatched queries: `maxEntries` evicts the least recently watched one,
  `evictAfterUnwatched` evicts after a timer that re-watching cancels, and
  `retainWhenUnwatched: Retention.firstPage` trims to the first page.
  Watched queries are never evicted; `evict`/`clearCache` reset them in place
  and keep their streams open.

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

Don't forget to dispose of the manager when it's no longer needed:

```dart
@override
void dispose() {
    userManager.dispose();
    super.dispose();
}
```

## License

MIT License - see the [LICENSE](LICENSE) file for details
