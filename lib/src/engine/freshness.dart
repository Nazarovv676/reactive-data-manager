/// Age-based freshness against an injectable clock.
class Freshness {
  /// Creates a policy: values older than [maxAge] are expired (`null`: never).
  const Freshness(this.clock, this.maxAge);

  /// Time source.
  final DateTime Function() clock;

  /// Default maximum age.
  final Duration? maxAge;

  /// Whether a value fetched [at] is older than [maxAge] (defaults to the
  /// policy's). A value without a fetch time is expired whenever a limit
  /// applies.
  bool isExpired(DateTime? at, {Duration? maxAge}) {
    final limit = maxAge ?? this.maxAge;
    if (limit == null) return false;
    return at == null || clock().difference(at) >= limit;
  }
}
