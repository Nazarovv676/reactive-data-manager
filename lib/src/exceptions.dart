class ReactiveDataException implements Exception {
  const ReactiveDataException();
}

class OptimisticUpdateException extends ReactiveDataException {
  const OptimisticUpdateException();
}

class DataFilteredException extends ReactiveDataException {
  const DataFilteredException();
}
