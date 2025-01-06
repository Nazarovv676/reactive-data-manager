/// Base class for all exceptions thrown by the reactive data package
abstract base class ReactiveDataException implements Exception {
  const ReactiveDataException();
}

/// Exception thrown when a update fails and the data is rolled back
final class OptimisticUpdateException extends ReactiveDataException {
  const OptimisticUpdateException();
}

/// Exception thrown when a first fetched data filter is applied and nothing
/// could be returned in the data stream
final class DataFilteredException extends ReactiveDataException {
  const DataFilteredException();
}
