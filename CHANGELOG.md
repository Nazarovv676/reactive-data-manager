# Changelog

## 1.3.0 (2026-10-12)

### Added
- `ReactivePagedManager<Q, T, C>` — paginated lists, one accumulated list per query:
  - `watch`, `peek`, `loadNext`, `loadPrevious`, `refresh({anchor})`; loading futures never throw or hang and resolve to a `PagedState`.
  - `PagedState` (items, `hasLoaded`, `isRefreshing`, `refreshError`, `next`/`previous` edges, `totalCount`, `fetchedAt`, `isStale`); errors live in the state, never replayed as stream errors.
  - Opaque cursors (`PageRequest`, `PageResult`, `PageFetcher`, `PageDirection`), `AbortSignal`, `PageCursorExpiredException`.
  - Concurrent `loadNext` joins one request; loads started before `invalidate`/`refresh`/`evict`/`clearCache` never write their page; local edits made in flight are re-applied onto the response.
  - Dedupe by `idOf`, `loadedCount`, unproductive-page and cursor-loop guards.
  - `patchItem`/`removeItem` across every cached query, `upsertItem` (head/tail, `move`).
  - `invalidate`/`invalidateWhere`/`invalidateAll` (a watched query refetches), `evict`, `clearCache`, `dispose`.
  - Eviction: `maxEntries` (LRU over unwatched queries), `evictAfterUnwatched`, `Retention.firstPage`; `maxAge`, `onError`, injectable `clock`.
  - `RefreshMode.mergeHead` / `allPages`, `refresh(anchor:)`, `maxItems` windowing, `maxRefreshPages`.
  - `mutate` with optimistic `PagedEdits` and rollback, `invalidateAfter`.
  - Persistence of the first page (`storage`, `persistWhen`, `storageVersion`, `PagedSnapshot`): stored page emitted first, revalidated; `evict`/`clearCache` delete it.
- `package:reactive_data_manager/testing.dart` with `ScriptedPageFetcher`.
- `ReactiveDataManager.invalidateWhere` and `patchWhere`.

## 1.2.0 (2026-10-12)

### Changed (behaviour fixes)
- `getData` no longer cancels the in-flight fetch. Concurrent calls for one key **join a single fetch** and all complete with its result or error; previously every call hit the fetcher and all but the last future hung forever. Only `forceRefresh: true` starts a new fetch, and callers of the superseded fetch complete with the newer result.
- A cached read no longer cancels an in-flight forced refresh.
- `clearCache()` and `evict(key)` now discard results of fetches started before them (a logout can no longer be repopulated by a late response). Such callers complete with the fetch's own result, which is not cached.
- `updateData`: a superseded or evicted update now completes with its own result (it used to hang) and no longer rolls back the newer value. The unused `async` dependency was removed.
- The `fetcher` field is no longer public (the constructor parameter is unchanged).

### Added
- `maxAge` (constructor and per call), injectable `clock`, `fetchedAt(key)`, `isFresh(key)`.
- `invalidate(key)` / `invalidateAll()` — stale-while-revalidate: the value stays visible, in-flight results are discarded.
- `refresh(key)` — fire-and-forget refetch, errors only via the stream.
- `watch(key, {fetch})` — non-null `Stream<T>` that fetches when missing or stale.
- `mutate(key, action, {invalidate})` — invalidates afterwards, also when the action fails.
- `set(key, value)` / `patch(key, transform)` — plain cache writes, no updater or rollback. An in-flight fetch is discarded so it cannot overwrite them.
- `replayErrors: false` — do not replay the last error to late subscribers.
- `errorMapper` — surfaces typed errors on the stream and from `getData`.
- `ReactiveDataManager.cancellable` — fetcher receiving a cancellation signal (completes when the fetch is superseded, invalidated, cleared or evicted), e.g. for Dio's `CancelToken`.
- `ReactiveValue<T>` — keyless single-value manager with the same API.
- Persistence: `ReactiveStorage`, `StoredEntry`, `InMemoryReactiveStorage`, `storage` / `storageVersion` options (stale-while-revalidate across restarts).

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
