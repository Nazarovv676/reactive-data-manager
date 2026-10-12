/// Immutable snapshot of one key of a `ReactiveDataManager` (or of a
/// `ReactiveValue`): the value together with its loading, error and freshness
/// flags. It uses the vocabulary of `PagedState`: the previous [data] is kept
/// while a fetch runs and after a fetch fails, and errors live here, never as
/// stream errors.
///
/// Has value equality ([data] is compared with `==`), so `distinct()` and
/// widget rebuild checks work; `watchState` never emits a state equal to the
/// previous one.
final class DataState<T> {
  /// Creates a state.
  const DataState({
    this.data,
    this.hasData = false,
    this.isLoading = false,
    this.error,
    this.stackTrace,
    this.fetchedAt,
    this.isStale = false,
  });

  /// The cached value; `null` when there is none (see [hasData]).
  final T? data;

  /// Whether a value is cached. Tells "no value yet" from a `null` value.
  final bool hasData;

  /// A fetch is in flight (or the persisted value is still being read). The
  /// previous [data] stays visible.
  final bool isLoading;

  /// The last failure (of a fetch or an `updateData`), after `errorMapper`.
  /// Cleared when the next fetch starts or a new value is written.
  final Object? error;

  /// Where [error] was thrown.
  final StackTrace? stackTrace;

  /// When [data] was fetched (or last written).
  final DateTime? fetchedAt;

  /// [data] was invalidated or is older than `maxAge` (evaluated when the
  /// state was emitted). Always `false` without data.
  final bool isStale;

  /// Whether the last fetch or update failed.
  bool get hasError => error != null;

  /// The very first fetch is in flight: no data yet.
  bool get isLoadingInitial => !hasData && isLoading;

  /// [error] as an [E], or `null` when it is something else (or absent).
  E? errorAs<E>() {
    final e = error;
    return e is E ? e : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DataState<T> &&
          other.data == data &&
          other.hasData == hasData &&
          other.isLoading == isLoading &&
          other.error == error &&
          other.stackTrace == stackTrace &&
          other.fetchedAt == fetchedAt &&
          other.isStale == isStale;

  @override
  int get hashCode => Object.hash(
        data,
        hasData,
        isLoading,
        error,
        stackTrace,
        fetchedAt,
        isStale,
      );

  @override
  String toString() => 'DataState('
      '${hasData ? 'data: $data' : 'no data'}'
      '${isLoading ? ', loading' : ''}'
      '${isStale ? ', stale' : ''}'
      '${error != null ? ', error: $error' : ''}'
      ')';
}
