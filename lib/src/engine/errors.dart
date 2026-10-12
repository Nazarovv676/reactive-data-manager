/// Maps an error thrown by a fetcher into the object delivered to consumers.
typedef ErrorMapper = Object Function(Object error, StackTrace stackTrace);

/// [mapper] applied to [error]. Without a mapper, or when the mapper itself
/// throws, the raw [error] is returned: mapping never turns one failure into
/// another or leaves an operation hanging.
Object mapError(ErrorMapper? mapper, Object error, StackTrace stackTrace) {
  if (mapper == null) return error;
  try {
    return mapper(error, stackTrace);
  } catch (_) {
    return error;
  }
}
