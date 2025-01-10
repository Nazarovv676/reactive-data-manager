# Reactive Data Manager

A Flutter package that provides a robust, reactive data management solution with built-in caching, optimistic updates, and error handling capabilities.

## Features

- 🔄 Reactive data streams
- 💾 Automatic caching
- ⚡ Optimistic updates
- 🔍 Data filtering
- ❌ Error handling
- 🧹 Automatic resource cleanup

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
    reactive_data_manager: ^1.0.0
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
