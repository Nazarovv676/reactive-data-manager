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

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
    reactive_data_manager: ^1.2.0
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
