/// Explicit state representation for reactive data operations.
///
/// This sealed class provides a clear distinction between different states of data
/// fetching and updating operations, allowing consumers to react appropriately
/// to loading, success, and error states.
sealed class ReactiveDataState<T> {
  const ReactiveDataState();
}

/// Represents a loading state when data is being fetched or updated.
///
/// This state is emitted when:
/// - Data fetching begins (via [ReactiveDataManager.getData])
/// - Data updating begins (via [ReactiveDataManager.updateData])
final class ReactiveDataStateLoading<T> extends ReactiveDataState<T> {
  const ReactiveDataStateLoading();
}

/// Represents a successful state with data.
///
/// This state is emitted when:
/// - Data is successfully fetched
/// - Data is successfully updated
///
/// The [data] field contains the successfully retrieved or updated data.
final class ReactiveDataStateSuccess<T> extends ReactiveDataState<T> {
  /// The successfully fetched or updated data.
  final T data;

  const ReactiveDataStateSuccess(this.data);
}

/// Represents an error state when data fetching or updating fails.
///
/// This state is emitted when:
/// - Fetching fails (via [ReactiveDataManager.getData])
/// - Updating fails (via [ReactiveDataManager.updateData])
///
/// The [error] field contains the error object, and [stackTrace] contains
/// the stack trace if available.
final class ReactiveDataStateError<T> extends ReactiveDataState<T> {
  /// The error that occurred during the operation.
  final Object error;

  /// The stack trace associated with the error, if available.
  final StackTrace? stackTrace;

  const ReactiveDataStateError(this.error, [this.stackTrace]);
}

