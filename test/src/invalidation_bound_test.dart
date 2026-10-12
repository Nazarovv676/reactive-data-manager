import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// `invalidateWhere` keeps at most 64 predicates for persisted values; older
/// ones are folded into one marker that over-invalidates, never the opposite.
void main() {
  final t0 = DateTime(2026);
  late InMemoryReactiveStorage<String, int> storage;
  late DateTime now;
  late int fetches;

  ReactiveDataManager<String, int> make() => ReactiveDataManager<String, int>(
        fetcher: (_) async => 100 + ++fetches,
        storage: storage,
        clock: () => now,
      );

  setUp(() {
    storage = InMemoryReactiveStorage<String, int>();
    now = t0;
    fetches = 0;
  });

  /// [calls] predicates; the first one (only) matches 'early'. Marker i is
  /// taken at `t0 + at(i)` seconds.
  void invalidate(
    ReactiveDataManager<String, int> m,
    int calls,
    int Function(int i) at,
  ) {
    for (var i = 1; i <= calls; i++) {
      now = t0.add(Duration(seconds: at(i)));
      m.invalidateWhere((k) => i == 1 && k == 'early');
    }
  }

  test('a thousand calls retain at most 64 predicates', () {
    final m = make();
    invalidate(m, 1000, (i) => i);
    expect(m.debugRetainedInvalidations, inInclusiveRange(1, 64));
  });

  test('without storage nothing is retained', () {
    final m = ReactiveDataManager<String, int>(
      fetcher: (_) async => 1,
      clock: () => now,
    );
    invalidate(m, 100, (i) => i);
    expect(m.debugRetainedInvalidations, 0);
  });

  group('after 65 calls (markers at +1..+65 s; the first two are folded)', () {
    late ReactiveDataManager<String, int> m;

    setUp(() {
      m = make();
      invalidate(m, 65, (i) => i);
      expect(m.debugRetainedInvalidations, 63);
    });

    test('a key matching a folded predicate, stored before it, is stale',
        () async {
      storage.entries['early'] = StoredEntry(5, t0);
      expect(await m.getData('early'), 101);
    });

    test('a non-matching key stored after the fold moment is restored fresh',
        () async {
      storage.entries['x'] =
          StoredEntry(5, t0.add(const Duration(milliseconds: 2500)));
      expect(await m.getData('x'), 5);
      expect(fetches, 0);
    });

    test(
        'a non-matching key stored before the fold moment is restored stale '
        '(the documented over-invalidation)', () async {
      storage.entries['y'] = StoredEntry(5, t0.add(const Duration(seconds: 1)));
      expect(await m.getData('y'), 101);
    });
  });

  test('a non-monotonic clock folds up to the latest marker, not the last',
      () async {
    final m = make();
    // The first marker is far in the future, the rest are older.
    invalidate(m, 65, (i) => i == 1 ? 100 : i);
    storage.entries['k'] = StoredEntry(5, t0.add(const Duration(seconds: 50)));
    expect(await m.getData('k'), 101);
  });

  test('invalidateAll and clearCache reset the bookkeeping', () {
    final m = make();
    invalidate(m, 100, (i) => i);
    m.invalidateAll();
    expect(m.debugRetainedInvalidations, 0);
    invalidate(m, 100, (i) => 200 + i);
    m.clearCache();
    expect(m.debugRetainedInvalidations, 0);
  });
}
