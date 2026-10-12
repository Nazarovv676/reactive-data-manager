# Changelog

## 2.0.0 (2026-10-12)

This release contains everything since 1.1.0 (the 1.2.0 and 1.3.0 changes were
never published separately). It is a major version because it changes
observable behaviour that 1.x callers may depend on (see "Changed (behaviour
fixes)" and the compatibility notes below): concurrent `getData` calls now join
instead of cancel, `clearCache`/`evict` discard in-flight results,
`updateData` supersede semantics changed, and invalidating a watched key
refetches it. The public API of 1.1.0 is otherwise
kept (the `fetcher` field remains as a deprecated getter).

### Changed (behaviour fixes)
- `getData` no longer cancels the in-flight fetch. Concurrent calls for one key **join a single fetch** and all complete with its result or error; previously every call hit the fetcher and all but the last future hung forever. Only `forceRefresh: true` starts a new fetch, and callers of the superseded fetch complete with the newer result.
- A cached read no longer cancels an in-flight forced refresh, and a cache hit **no longer re-emits an identical value** to the stream (1.1.0 always called `add`).
- `clearCache()` and `evict(key)` **discard results of fetches started before them** (a logout can no longer be repopulated by a late response). Their callers complete with the fetch's own result, which is not cached; with a fetcher that honours the cancel signal (e.g. Dio) that is the fetcher's cancellation error. `evict`'s pending `getData` completes instead of hanging.
- A storage read issued right after `evict`/`clearCache` is ordered behind the queued delete, so a deleted persisted entry never comes back (logout leak).
- `updateData`: a superseded, evicted, cleared or disposed update **completes with its own result** (it used to hang) and no longer emits an error or rolls back. A failed update rolls back only if nothing wrote the key since it started (a newer `set`/`patch`/fetch/update wins), and a fetch that started before the update no longer overwrites the optimistic value (its callers still get its result).
- `invalidate`, `set`, `patch` (and `invalidateWhere`, `invalidateAll`, `patchWhere`, `mutate`) discard the result of an in-flight fetch **without** firing its cancel signal: callers waiting on it get its result instead of a cancellation error.
- A throwing `errorMapper` falls back to the raw error, and a throwing `errorMapper`/`fetchFilter` can no longer leave a key's fetch stuck in flight.
- **Invalidating a watched key refetches it.** A key is watched while its stream (`getStream`, `watch`, `watchState`) has a listener; `invalidate`, `invalidateWhere`, `invalidateAll` and `mutate` now refetch such keys immediately (errors only via the stream), like the paged manager. Unwatched keys are still only marked stale. A watched fetch in flight is detached as before (its callers get its result) and a new one starts.
- `invalidateWhere` also matches keys that are being fetched or watched but have no cached value (it used to test cached keys only), so their in-flight results are discarded too.
- `getStream` resolves the key's subject when it is listened to: a stream obtained before the key was evicted (or dropped by `maxEntries`/`evictAfterUnwatched`) keeps working instead of replaying a closed subject. Calls for one key still return an equal stream (safe in `StreamBuilder`); with `replayErrors: false` this is new.
- The unused `async` dependency was removed.

### Compatibility notes
- The public `fetcher` field became private; a **deprecated `fetcher` getter** (`Future<T> Function(K key)`) is kept for 1.1.0 code. It calls the fetcher directly (no cache, no join); for a cancellable fetcher the cancel signal never fires. It will be removed in 3.0.0.
- `getData` gained the named parameter `maxAge`: subclasses overriding `getData` must add it.
- About 20 new public members were added to `ReactiveDataManager`; hand-written `implements ReactiveDataManager` fakes must implement them (generated mocks such as mocktail are unaffected).
- `replayErrors` defaults to `true` (1.1.0 behaviour); exceptions and existing exports are unchanged.

### Added — `ReactiveDataManager` / `ReactiveValue`
- `maxAge` (constructor and per call), injectable `clock`, `fetchedAt(key)`, `isFresh(key)`.
- `invalidate(key)` / `invalidateWhere(test)` / `invalidateAll()` — stale-while-revalidate: the value stays visible, in-flight results are discarded, watched keys refetch immediately. With storage they also apply to values restored later.
- `refresh(key)` — fire-and-forget refetch, errors only via the stream.
- `prefetch(key)` — fire-and-forget, non-forced `getData`: a no-op when fresh, joins a fetch in flight, errors only via the stream.
- `watchState(key, {fetch})` and the immutable `DataState<T>` (`data`, `hasData`, `isLoading`, `error`/`stackTrace`, `fetchedAt`, `isStale`, `hasError`, `isLoadingInitial`, `errorAs<E>()`; value equality): the previous data is kept while loading and after a failure, errors are state and never stream errors (nothing is replayed), equal states are not re-emitted, one operation emits one state. The stream survives `evict`, closes on `dispose`, can be listened to several times and is the same object for the same arguments (B6).
- `maxEntries` (LRU over unwatched keys, at least 1, `ArgumentError` otherwise) and `evictAfterUnwatched` (timer cancelled by a re-watch). Automatic eviction frees memory only: an in-flight fetch is detached, persisted entries (and a pending invalidation of them) are kept. Explicit `evict` still closes the key's subject.
- `storageReadTimeout` (also on `ReactiveValue` and `ReactivePagedManager`; default `null`, no limit): a storage read slower than this counts as missing and its late result is dropped, so a stuck adapter never blocks `getData`. The limit runs from the read request and includes the wait behind queued writes; a read that times out while queued never reaches the adapter.
- `watch(key, {fetch})` — non-null `Stream<T>` that fetches when missing or stale.
- `mutate(key, action, {invalidate})` — invalidates afterwards, also when the action fails.
- `set(key, value)` / `patch(key, transform)` / `patchWhere(transform)` — plain cache writes, no updater or rollback. An in-flight fetch is discarded so it cannot overwrite them.
- `replayErrors: false` — do not replay the last error to late subscribers.
- `errorMapper` — surfaces typed errors on the stream and from `getData`.
- `ReactiveDataManager.cancellable` — fetcher receiving a cancel signal (`Future<void>`) that completes when the fetch is superseded, evicted, cleared or disposed, e.g. for Dio's `CancelToken`.
- `ReactiveValue<T>` — keyless single-value manager with the same API (including `prefetch()` and `watchState()`); `storageKey` (default `'value'`) lets several values share one storage adapter, and `clear()` deletes only that key.
- Persistence: `ReactiveStorage`, `StoredEntry`, `InMemoryReactiveStorage`, `storage` / `storageVersion` options (stale-while-revalidate across restarts). `getData`, `watch` (also `fetch: false`) and `getStream` restore a persisted value; storage errors (also synchronous throws) never fail a read; storage is never touched after `dispose()`.

### Added — `ReactivePagedManager<Q, T, C>`
Paginated lists, one accumulated list per query:
- `watch`, `peek`, `loadNext`, `loadPrevious`, `refresh({anchor, mode})`; loading futures never throw or hang (also when `idOf`, a replayed transform or `persistWhen` throws) and resolve to a `PagedState`.
- `PagedState` (items, `hasLoaded`, `isRefreshing`, `refreshError`, `next`/`previous` edges, `totalCount`, `fetchedAt`, `isStale`) with value equality, like `PagedEdge` and `PagedError`; equal states are not re-emitted. Errors live in the state, never replayed as stream errors.
- Opaque cursors (`PageRequest`, `PageResult`, `PageFetcher`, `PageDirection`), `AbortSignal` (inside `PageRequest`), `PageCursorExpiredException` (always recovered with a first-page refresh).
- Concurrent `loadNext` joins one request; loads started before `invalidate`/`refresh`/`evict`/`clearCache` never write their page; local edits made in flight are re-applied onto the response.
- Dedupe by `idOf`, `loadedCount` (also counting the raw items of followed all-duplicate pages within one call), unproductive-page and cursor-loop guards.
- `patchItem`/`removeItem` across every cached query, `upsertItem` (head/tail, `move`; absent items only at a fully loaded end, never on unloaded or restored-only queries).
- `invalidate`/`invalidateWhere`/`invalidateAll` (a watched query refetches), `evict`, `clearCache`, `dispose` (later `evict`/`clearCache` are no-ops).
- `prefetch(query)` — fire-and-forget first-page load when nothing is loaded or the query is stale (invalidated, expired or restored from storage) and no head load runs; never throws.
- `errorMapper` with the base manager's signature: errors thrown by `fetchPage` are mapped before they reach `PagedError` and `onError`; a throwing mapper falls back to the raw error, an expired cursor is recovered and never mapped.
- `@visibleForTesting debugCursors(query)`: `(next, previous, pages)` record with the cursors the next `loadNext`/`loadPrevious` would send, or `null` when the query is not cached.
- A debug-build warning (`dart:developer` log, name `reactive_data_manager`) when an edge is given up after `maxUnproductivePages` unproductive pages.
- Eviction: `maxEntries` (LRU over unwatched queries), `evictAfterUnwatched`, `Retention.firstPage`; `maxAge`, `onError`, injectable `clock`. `maxEntries`, `maxItems`, `maxRefreshPages` and `maxUnproductivePages` must be at least 1 (`ArgumentError`).
- `RefreshMode.mergeHead` / `allPages`, `refresh(anchor:)`, `maxItems` windowing, `maxRefreshPages`; exact per-page accounting so windowing and `Retention.firstPage` keep working after splices and replayed edits.
- `mutate` with optimistic `PagedEdits` and rollback, `invalidateAfter`.
- Persistence of the first page (`storage`, `persistWhen`, `storageVersion`, `PagedSnapshot`): stored page emitted first, revalidated; `evict`/`clearCache` delete it.
- `package:reactive_data_manager/testing.dart` with `ScriptedPageFetcher`.

### Changed (internal)
- `ReactiveDataManager`, `ReactiveValue` and `ReactivePagedManager` run on a shared internal engine (`lib/src/engine/`): in-flight operations with abort signals and per-lane join/supersede, freshness against the injectable clock, the serialized storage queue with version checks, and the entry registry (watcher ref-count, `maxEntries` LRU, `evictAfterUnwatched` timers).
- `fake_async` dev dependency relaxed to `^1.3.1` (Flutter 3.27).
- `meta: ^1.12.0` added as a dependency (for `@visibleForTesting`; the version pinned by Flutter 3.22, the declared SDK floor).
- Error mapping lives in `lib/src/engine/errors.dart`, shared by both managers.

### Not implemented (from the design)
- A debug assert for calls after `dispose`. Both managers document calls after `dispose` as safe no-ops (`evict`/`clearCache` on a disposed paged manager, memory-only `evict`/`clearCache` on a disposed base manager, an idle state from paged loads), and existing tests rely on that; an assert would turn these documented no-ops into failures in debug builds, e.g. when widget teardown order calls `evict` after the owner disposed the manager.

## 1.1.0 (2026-09-01)

### Added
- 🗑️ `evict(key)` — removes the cached value, subject, and any in-flight fetch/update for a single key, without resetting every other key the way `clearCache()` does. Useful for callers that key by something derived (e.g. a request minus its pagination params) and need to drop one superseded entry while leaving the rest of the cache intact.

## 1.0.0 (2025-01-10)

### Initial Release 🎉

#### Features
- ✨ Reactive data streams with RxDart integration
- 💾 Built-in caching system
- ⚡ Optimistic updates support
- 🔍 Configurable data filtering
- ❌ Comprehensive error handling
- 🧹 Automatic resource cleanup
- 📝 Type-safe API
- 🔄 Cancellable operations

#### Components
- `ReactiveDataManager` - Core class for reactive data management
- Data filtering capabilities
- Cache management
- Stream handling
- Error handling with custom exceptions

#### Dependencies
- RxDart for reactive streams
- Async package for cancellable operations

#### Documentation
- Comprehensive README with usage examples
- Fully documented API with examples
- Installation instructions
