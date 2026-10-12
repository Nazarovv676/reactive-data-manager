import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('fetchFilter', () {
    test('replaces the fetched value when it returns non-null', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        fetchFilter: (_, d) => d * 10,
      );
      expect(await m.getData('k'), 10);
      expect(m.getCurrentValue('k'), 10);
    });

    test('keeps the old value when it returns null and one is cached',
        () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++n,
        fetchFilter: (_, d) => d == 1 ? d : null,
      );
      expect(await m.getData('k'), 1);
      expect(await m.getData('k', forceRefresh: true), 1);
      expect(m.getCurrentValue('k'), 1);
    });

    test('throws DataFilteredException when nothing is cached', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        fetchFilter: (_, __) => null,
      );
      await expectLater(m.getData('k'), throwsA(isA<DataFilteredException>()));
      expect(m.getCurrentValue('k'), isNull);
    });

    test('errorMapper does not map DataFilteredException', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        fetchFilter: (_, __) => null,
        errorMapper: (e, s) => 'mapped',
      );
      await expectLater(m.getData('k'), throwsA(isA<DataFilteredException>()));
    });
  });

  group('updateData', () {
    test('without updater just writes locally and returns null', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      expect(await m.updateData('k', 5), isNull);
      expect(m.getCurrentValue('k'), 5);
      expect(m.isFresh('k'), isTrue);
    });

    test('is optimistic: value is visible before the updater completes',
        () async {
      final c = Completer<String>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) => c.future,
      );
      final f = m.updateData('k', 5);
      expect(m.getCurrentValue('k'), 5);
      c.complete('server');
      expect(await f, 'server');
    });

    test('rolls back to the old value on failure', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) async => throw StateError('x'),
      );
      await m.getData('k');
      final fetchedAt = m.fetchedAt('k');
      await expectLater(
          m.updateData('k', 5), throwsA(isA<OptimisticUpdateException>()));
      expect(m.getCurrentValue('k'), 1);
      expect(m.fetchedAt('k'), fetchedAt);
    });

    test('rolls back to empty when nothing was cached', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) async => throw StateError('x'),
      );
      await expectLater(
          m.updateData('k', 5), throwsA(isA<OptimisticUpdateException>()));
      expect(m.getCurrentValue('k'), isNull);
      expect(m.isFresh('k'), isFalse);
    });

    test('rollback keeps the invalidated state', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) async => throw StateError('x'),
      );
      await m.getData('k');
      m.invalidate('k');
      await m.updateData('k', 5).then((_) {}, onError: (_) {});
      expect(m.isFresh('k'), isFalse);
    });

    test('failure is also emitted on the stream', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) async => throw StateError('x'),
      );
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      await m.updateData('k', 5).then((_) {}, onError: (_) {});
      await pump();
      expect(errors.single, isA<OptimisticUpdateException>());
      await sub.cancel();
    });

    test('updateFilter replaces, falls back to old data, or throws', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, d) async => d,
        updateFilter: (_, r) => (r as int) > 100 ? null : r * 2,
      );
      expect(await m.updateData('k', 5), 10);
      // null result with a previous value -> previous value
      expect(await m.updateData('k', 500), 5);
      // null result and nothing cached before -> DataFilteredException
      await expectLater(
          m.updateData('other', 500), throwsA(isA<DataFilteredException>()));
    });

    test('a newer update supersedes the previous one', () async {
      final calls = <Completer<int>>[];
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, __) {
          final c = Completer<int>();
          calls.add(c);
          return c.future;
        },
      );
      m.updateData('k', 1).ignore();
      final second = m.updateData('k', 2);
      calls[1].complete(2);
      expect(await second, 2);
      expect(m.getCurrentValue('k'), 2);
    });
  });

  group('streams', () {
    test('getStream replays the current value to late subscribers', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      await m.getData('k');
      expect(await m.getStream('k').first, 1);
    });

    test('a cached read re-emits the value after an error', () async {
      var fail = false;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => fail ? throw StateError('x') : 1,
      );
      await m.getData('k');
      fail = true;
      await m.getData('k', forceRefresh: true).then((_) {}, onError: (_) {});
      fail = false;
      await m.getData('k'); // cache hit restores the value for new listeners
      expect(await m.getStream('k').first, 1);
    });

    test('clearCache emits null to subscribers', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      await m.getData('k');
      final values = <int?>[];
      final sub = m.getStream('k').listen(values.add);
      await pump();
      m.clearCache();
      await pump();
      expect(values, [1, null]);
      await sub.cancel();
    });

    test('evict closes the stream and starts fresh', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        replayErrors: false,
      );
      await m.getData('k');
      var done = false;
      m.getStream('k').listen((_) {}, onDone: () => done = true);
      m.evict('k');
      await pump();
      expect(done, isTrue);
      expect(m.getCurrentValue('k'), isNull);
      expect(await m.getData('k'), 1);
    });

    test('watch can be listened to more than once', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++n,
        maxAge: const Duration(hours: 1),
      );
      final w = m.watch('k');
      expect(await w.first, 1);
      expect(await w.first, 1); // fresh: no refetch
      expect(n, 1);
    });
  });

  group('invalidateAll / clearCache with in-flight fetches', () {
    test('invalidateAll discards in-flight fetches', () async {
      final c = Completer<int>();
      final m = ReactiveDataManager<String, int>(fetcher: (_) => c.future);
      final f = m.getData('k');
      m.invalidateAll();
      c.complete(1);
      expect(await f, 1);
      expect(m.getCurrentValue('k'), isNull);
    });

    test('a fetch after clearCache is accepted again', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => ++n);
      await m.getData('k');
      m.clearCache();
      expect(await m.getData('k'), 2);
      expect(m.getCurrentValue('k'), 2);
    });
  });

  test('a superseded fetch that fails follows the successor', () async {
    final calls = <Completer<int>>[];
    final m = ReactiveDataManager<String, int>(fetcher: (_) {
      final c = Completer<int>();
      calls.add(c);
      return c.future;
    });
    final errors = <Object>[];
    final sub = m.getStream('k').listen((_) {}, onError: errors.add);
    final old = m.getData('k');
    final newer = m.getData('k', forceRefresh: true);
    calls[0].completeError(StateError('old'));
    await pump();
    expect(errors, isEmpty); // the discarded failure is not emitted
    calls[1].complete(2);
    expect(await old, 2);
    expect(await newer, 2);
    await sub.cancel();
  });

  group('dispose', () {
    test('discards in-flight fetches without hanging or writing', () async {
      final c = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) => c.future,
        replayErrors: false,
      );
      m.getStream('k').listen((_) {});
      final f = m.getData('k');
      m.dispose();
      c.complete(3);
      expect(await f, 3);
      expect(m.getCurrentValue('k'), isNull);
    });

    test('cancels active updates', () async {
      final c = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) => c.future,
      );
      final u = m.updateData('k', 2);
      expect(m.getCurrentValue('k'), 2);
      m.dispose();
      expect(m.getCurrentValue('k'), isNull);
      c.complete(1);
      expect(await u, 1); // completes with its own result
      expect(m.getCurrentValue('k'), isNull); // and touches nothing

      final failing = Completer<int>();
      final m2 = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) => failing.future,
      );
      await m2.getData('k');
      final u2 = expectLater(
        m2.updateData('k', 2),
        throwsA(isA<OptimisticUpdateException>()),
      );
      m2.dispose();
      failing.completeError(StateError('x'));
      await u2;
      expect(m2.getCurrentValue('k'), isNull); // no rollback after dispose
    });
  });

  group('ReactiveValue full API', () {
    test('getData/refresh/stream/currentValue/fetchedAt', () async {
      var n = 0;
      final now = DateTime(2026);
      final v = ReactiveValue<int>(fetcher: () async => ++n, clock: () => now);
      expect(v.currentValue, isNull);
      expect(v.fetchedAt, isNull);
      expect(await v.getData(), 1);
      expect(v.fetchedAt, now);
      expect(await v.stream.first, 1);
      v.refresh();
      await pump();
      expect(v.currentValue, 2);
      expect(await v.getData(forceRefresh: true), 3);
      expect(await v.getData(maxAge: Duration.zero), 4);
    });

    test('updateData with updater, updateFilter and fetchFilter', () async {
      final v = ReactiveValue<int>(
        fetcher: () async => 1,
        fetchFilter: (d) => d + 100,
        updater: (d) async => d,
        updateFilter: (r) => (r as int) + 1,
      );
      expect(await v.getData(), 101);
      expect(await v.updateData(5), 6);
      expect(v.currentValue, 5);
    });

    test('mutate invalidates, clear drops the value', () async {
      var n = 0;
      final v = ReactiveValue<int>(fetcher: () async => ++n);
      await v.getData();
      expect(await v.mutate(() async => 'r'), 'r');
      expect(v.isFresh(), isFalse);
      await v.getData();
      await v.mutate(() async {}, invalidate: false);
      expect(v.isFresh(), isTrue);
      v.clear();
      expect(v.currentValue, isNull);
    });

    test('watch(fetch: false) does not fetch', () async {
      var n = 0;
      final v = ReactiveValue<int>(fetcher: () async => ++n);
      final sub = v.watch(fetch: false).listen((_) {});
      await pump();
      expect(n, 0);
      await sub.cancel();
    });

    test('errorMapper, replayErrors and storage are forwarded', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      final v = ReactiveValue<int>(
        fetcher: () async => throw StateError('x'),
        errorMapper: (e, s) => 'mapped',
        replayErrors: false,
        storage: storage,
        storageVersion: 3,
      );
      await expectLater(v.getData(), throwsA('mapped'));
      final ok = ReactiveValue<int>(
        fetcher: () async => 1,
        storage: storage,
        storageVersion: 3,
      );
      await ok.getData();
      await pump();
      expect(storage.entries.values.single.version, 3);
    });

    test('cancellable forwards every option', () async {
      final v = ReactiveValue<int>.cancellable(
        fetcher: (_) async => 1,
        fetchFilter: (d) => d + 1,
        updater: (d) async => d,
        updateFilter: (r) => r,
        maxAge: const Duration(seconds: 1),
        errorMapper: (e, s) => e,
        replayErrors: false,
      );
      expect(await v.getData(), 2);
      expect(await v.updateData(7), 7);
      v.patch((c) => c + 1);
      expect(v.currentValue, 8);
      v.set(9);
      expect(v.currentValue, 9);
      v.dispose();
    });
  });

  group('storage types', () {
    test('StoredEntry defaults version to 0', () {
      final e = StoredEntry<int>(1, DateTime(2026));
      expect(e.value, 1);
      expect(e.fetchedAt, DateTime(2026));
      expect(e.version, 0);
    });

    test('InMemoryReactiveStorage read/write/delete/clear', () async {
      final s = InMemoryReactiveStorage<String, int>();
      expect(await s.read('a'), isNull);
      await s.write('a', StoredEntry(1, DateTime(2026)));
      await s.write('b', StoredEntry(2, DateTime(2026)));
      expect((await s.read('a'))!.value, 1);
      await s.delete('a');
      expect(await s.read('a'), isNull);
      await s.clear();
      expect(s.entries, isEmpty);
    });

    test('hydration dropped when evicted while reading', () async {
      final gate = Completer<void>();
      final storage = _SlowStorage(gate.future)
        ..entries['k'] = StoredEntry(7, DateTime(2026));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: storage,
      );
      final f = m.getData('k');
      await pump();
      m.evict('k');
      gate.complete();
      expect(await f, 1); // stored 7 was dropped, fetched instead
    });

    test('exceptions are ReactiveDataExceptions', () {
      expect(const OptimisticUpdateException(), isA<ReactiveDataException>());
      expect(const DataFilteredException(), isA<ReactiveDataException>());
    });
  });
}

class _SlowStorage extends InMemoryReactiveStorage<String, int> {
  _SlowStorage(this.gate);
  final Future<void> gate;
  @override
  Future<StoredEntry<int>?> read(String key) async {
    await gate;
    return entries[key];
  }
}
