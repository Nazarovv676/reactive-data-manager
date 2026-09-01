# Changelog

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
