import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Fetcher whose every call is completed by hand, per key.
class Gate {
  final calls = <(String, Completer<int>)>[];
  Future<int> call(String key) {
    final c = Completer<int>();
    calls.add((key, c));
    return c.future;
  }

  Completer<int> at(int i) => calls[i].$2;
}

void main() {
  group('different keys run independently', () {
    test('parallel fetches for many keys, one call each', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final futures = [
        for (final k in ['a', 'b', 'c']) m.getData(k)
      ];
      final again = [
        for (final k in ['a', 'b', 'c']) m.getData(k)
      ];
      expect(gate.calls.map((c) => c.$1), ['a', 'b', 'c']);
      gate.at(2).complete(3);
      gate.at(0).complete(1);
      gate.at(1).complete(2);
      expect(await Future.wait(futures), [1, 2, 3]);
      expect(await Future.wait(again), [1, 2, 3]);
    });

    test('invalidating or clearing one key leaves another key in flight',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final a = m.getData('a');
      final b = m.getData('b');
      m.invalidate('a');
      m.evict('a');
      gate.at(0).complete(1);
      gate.at(1).complete(2);
      await Future.wait([a, b]);
      expect(m.getCurrentValue('a'), isNull);
      expect(m.getCurrentValue('b'), 2);
    });
  });

  group('fetch lifecycle races', () {
    test('after invalidate a new getData starts a fresh fetch', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final old = m.getData('k');
      m.invalidate('k');
      final fresh = m.getData('k');
      final joined = m.getData('k');
      expect(gate.calls, hasLength(2));
      gate.at(0).complete(1); // discarded
      await old;
      expect(m.getCurrentValue('k'), isNull);
      gate.at(1).complete(2);
      expect(await fresh, 2);
      expect(await joined, 2);
      expect(m.getCurrentValue('k'), 2);
    });

    test('three forceRefreshes: all callers get the last result', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = [
        m.getData('k'),
        m.getData('k', forceRefresh: true),
        m.getData('k', forceRefresh: true),
      ];
      expect(gate.calls, hasLength(3));
      gate.at(2).complete(3); // newest first
      gate.at(0).complete(1);
      gate.at(1).complete(2);
      expect(await Future.wait(f), [3, 3, 3]);
      expect(m.getCurrentValue('k'), 3);
    });

    test('older result arriving after the newer one never overwrites it',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.getData('k').ignore();
      final newer = m.getData('k', forceRefresh: true);
      gate.at(1).complete(2);
      await newer;
      gate.at(0).complete(1);
      await pump();
      expect(m.getCurrentValue('k'), 2);
    });

    test('a failing newer fetch fails every caller, old value stays', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final first = m.getData('k');
      gate.at(0).complete(1);
      await first;
      final a = m.getData('k', forceRefresh: true);
      final b = m.getData('k', forceRefresh: true);
      final checks = Future.wait([
        expectLater(a, throwsStateError),
        expectLater(b, throwsStateError),
      ]);
      gate.at(2).completeError(StateError('boom'));
      await checks;
      expect(m.getCurrentValue('k'), 1);
      expect(m.isFresh('k'), isTrue);
    });

    test('a failed fetch is not cached: the next getData retries', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final failed = expectLater(m.getData('k'), throwsStateError);
      gate.at(0).completeError(StateError('x'));
      await failed;
      final retry = m.getData('k');
      expect(gate.calls, hasLength(2));
      gate.at(1).complete(5);
      expect(await retry, 5);
    });

    test('fetcher that throws synchronously is reported as an error', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) => throw StateError('sync'),
      );
      await expectLater(m.getData('k'), throwsStateError);
      await expectLater(m.getData('k'), throwsStateError); // not stuck
    });

    test('set during a fetch: waiting callers still complete', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final a = m.getData('k');
      final b = m.getData('k');
      m.set('k', 9);
      gate.at(0).complete(1);
      expect(await Future.wait([a, b]), [1, 1]);
      expect(m.getCurrentValue('k'), 9);
    });

    test('patch during a fetch discards that fetch', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      final f = m.getData('k', forceRefresh: true);
      m.patch('k', (v) => v + 10);
      gate.at(0).complete(500);
      await f;
      expect(m.getCurrentValue('k'), 11);
    });

    test('refresh while a fetch is in flight supersedes it', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = m.getData('k');
      m.refresh('k');
      expect(gate.calls, hasLength(2));
      gate.at(1).complete(2);
      expect(await f, 2);
    });
  });

  group('interleaving with updateData', () {
    // m2 (deliberate change): a fetch that started before the update used to
    // overwrite the optimistic value. It is now detached like by set().
    test(
        'a fetch started before an update never overwrites the optimistic '
        'value; its callers still complete', () async {
      final gate = Gate();
      final update = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        updater: (_, __) => update.future,
      );
      final fetch = m.getData('k');
      final u = m.updateData('k', 7);
      expect(m.getCurrentValue('k'), 7);
      expect(await m.getData('k'), 7); // fresh optimistic value, no join
      gate.at(0).complete(1);
      expect(await fetch, 1);
      expect(m.getCurrentValue('k'), 7);
      update.complete(0);
      expect(await u, 0);
      expect(m.getCurrentValue('k'), 7);
      expect(gate.calls, hasLength(1));
    });

    test('a fetch started during an update wins, and is not rolled back',
        () async {
      final gate = Gate();
      final update = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        updater: (_, __) => update.future,
      );
      m.set('k', 0);
      final u = expectLater(
        m.updateData('k', 7),
        throwsA(isA<OptimisticUpdateException>()),
      );
      final fetch = m.getData('k', forceRefresh: true);
      gate.at(0).complete(5);
      expect(await fetch, 5);
      expect(m.getCurrentValue('k'), 5);
      update.completeError(StateError('x'));
      await u;
      expect(m.getCurrentValue('k'), 5); // no rollback to 0
    });

    test('a failed update does not roll back over a newer set', () async {
      final update = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, __) => update.future,
      );
      expect(await m.getData('k'), 0);
      final u = expectLater(
        m.updateData('k', 1),
        throwsA(isA<OptimisticUpdateException>()),
      );
      m.set('k', 2);
      update.completeError(StateError('x'));
      await u;
      expect(m.getCurrentValue('k'), 2);
      expect(m.isFresh('k'), isTrue);
    });

    test('a failed update does not roll back over a newer patch', () async {
      final update = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, __) => update.future,
      );
      await m.getData('k');
      final u = m.updateData('k', 1);
      m.patch('k', (v) => v + 10);
      update.completeError(StateError('x'));
      await u.then((_) {}, onError: (_) {});
      expect(m.getCurrentValue('k'), 11);
    });

    test(
        'a failed update without a previous value and no newer write '
        'removes the value', () async {
      final update = Completer<int>();
      final storage = InMemoryReactiveStorage<String, int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, __) => update.future,
        storage: storage,
      );
      final u = m.updateData('k', 1);
      expect(m.getCurrentValue('k'), 1);
      update.completeError(StateError('x'));
      await u.then((_) {}, onError: (_) {});
      expect(m.getCurrentValue('k'), isNull);
      await pump();
      expect(storage.entries, isEmpty);
    });

    test('rollback arriving after evict does not resurrect old data', () async {
      final update = Completer<int>();
      var n = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++n,
        updater: (_, __) => update.future,
      );
      expect(await m.getData('k'), 1);
      final u = expectLater(m.updateData('k', 2), throwsA(anything));
      m.evict('k');
      update.completeError(StateError('late'));
      await u;
      await pump();
      expect(m.getCurrentValue('k'), isNull);
      expect(await m.getData('k'), 2); // fetched again, not the old value
      expect(m.getCurrentValue('k'), 2);
    });

    test('rollback arriving after clearCache does not resurrect old data',
        () async {
      final update = Completer<int>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (_, __) => update.future,
      );
      expect(await m.getData('k'), 1);
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      final u = expectLater(
        m.updateData('k', 2),
        throwsA(isA<OptimisticUpdateException>()),
      );
      m.clearCache();
      update.completeError(StateError('late'));
      await u;
      await pump();
      expect(m.getCurrentValue('k'), isNull);
      expect(errors, isEmpty); // a superseded update emits nothing
      await sub.cancel();
    });

    test(
        'sequential optimistic updates then one failure rolls back to the '
        'value before the failing update', () async {
      var fail = false;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, d) async => fail ? throw StateError('x') : d,
      );
      await m.getData('k');
      await m.updateData('k', 1);
      fail = true;
      await m.updateData('k', 2).then((_) {}, onError: (_) {});
      expect(m.getCurrentValue('k'), 1);
    });
  });

  group('superseded updates', () {
    test(
        'a superseded update completes and its failure does not roll back '
        'the newer value', () async {
      final calls = <Completer<int>>[];
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        updater: (_, __) {
          final c = Completer<int>();
          calls.add(c);
          return c.future;
        },
      );
      await m.getData('k');
      final first = m.updateData('k', 1);
      final second = m.updateData('k', 2);
      final firstDone =
          expectLater(first, throwsA(isA<OptimisticUpdateException>()));
      calls[0].completeError(StateError('x'));
      await firstDone;
      expect(m.getCurrentValue('k'), 2);
      calls[1].complete(2);
      expect(await second, 2);
    });
  });

  group('mutate / invalidate / refresh sequences', () {
    test('mutate invalidates only after the action settles', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => ++n);
      await m.getData('k');
      final action = Completer<String>();
      final r = m.mutate('k', () => action.future);
      await pump();
      expect(m.isFresh('k'), isTrue); // still running
      action.complete('done');
      expect(await r, 'done');
      expect(m.isFresh('k'), isFalse);
    });

    test('mutate + refresh: listeners see old, then new value', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => ++n);
      await m.getData('k');
      final seen = <int>[];
      final sub = m.watch('k', fetch: false).listen(seen.add);
      await m.mutate('k', () async {});
      m.refresh('k');
      await pump();
      expect(seen, [1, 2]);
      await sub.cancel();
    });

    test('a failed mutate with an in-flight fetch discards it', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = m.getData('k');
      await expectLater(
        m.mutate<void>('k', () async => throw StateError('x')),
        throwsStateError,
      );
      gate.at(0).complete(1);
      await f;
      expect(m.getCurrentValue('k'), isNull);
    });

    test('watch refetches a stale value on listen and shows it meanwhile',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final first = m.getData('k');
      gate.at(0).complete(1);
      await first;
      m.invalidate('k');
      final seen = <int>[];
      final sub = m.watch('k').listen(seen.add);
      await pump();
      expect(seen, [1]); // stale value first
      gate.at(1).complete(2);
      await pump();
      expect(seen, [1, 2]);
      await sub.cancel();
    });

    test('watch delivers a fetch error through the stream', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('x'),
        replayErrors: false,
      );
      await expectLater(m.watch('k'), emitsError(isA<StateError>()));
    });
  });

  group('maxAge with async clock changes', () {
    test('value that expires while a fetch is pending joins that fetch',
        () async {
      var now = DateTime(2026);
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        maxAge: const Duration(seconds: 10),
        clock: () => now,
      );
      final first = m.getData('k');
      gate.at(0).complete(1);
      await first;
      now = now.add(const Duration(seconds: 11));
      final a = m.getData('k');
      final b = m.getData('k');
      expect(gate.calls, hasLength(2));
      gate.at(1).complete(2);
      expect(await a, 2);
      expect(await b, 2);
      expect(m.fetchedAt('k'), now);
    });
  });

  group('persistence async ordering', () {
    test('set during hydration wins over the stored value', () async {
      final gate = Completer<void>();
      final storage = _SlowStorage(gate.future)
        ..entries['k'] = StoredEntry(7, DateTime(2026));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: storage,
      );
      final f = m.getData('k');
      await pump();
      m.set('k', 5);
      gate.complete();
      await f;
      expect(m.getCurrentValue('k'), isNot(7));
    });

    test('writes reach storage in call order', () async {
      final log = <String>[];
      final storage = _LoggingStorage(log);
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: storage,
      );
      m.set('k', 1);
      m.set('k', 2);
      m.evict('k');
      m.set('k', 3);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(log, ['w1', 'w2', 'd', 'w3']);
    });

    test('a slow write does not block getData results', () async {
      final storage =
          _LoggingStorage([], delay: const Duration(milliseconds: 50));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: storage,
      );
      expect(await m.getData('k'), 1);
      expect(m.getCurrentValue('k'), 1);
    });

    test('hydrating different keys concurrently', () async {
      final storage = InMemoryReactiveStorage<String, int>()
        ..entries['a'] = StoredEntry(1, DateTime(2026))
        ..entries['b'] = StoredEntry(2, DateTime(2026));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 0,
        storage: storage,
        clock: () => DateTime(2026),
        maxAge: const Duration(hours: 1),
      );
      expect(await Future.wait([m.getData('a'), m.getData('b')]), [1, 2]);
    });

    // B1: no pump between clearCache/evict and the next read. The storage read
    // must be ordered behind the queued delete/clear.
    for (final action in <String, void Function(ReactiveDataManager)>{
      'clearCache': (m) => m.clearCache(),
      'evict': (m) => m.evict('me'),
    }.entries) {
      test('${action.key} then getData right away never resurrects', () async {
        final storage = InMemoryReactiveStorage<String, String>();
        var user = 'alice';
        var calls = 0;
        final m = ReactiveDataManager<String, String>(
          fetcher: (_) async {
            calls++;
            return 'profile-of-$user';
          },
          storage: storage,
        );
        expect(await m.getData('me'), 'profile-of-alice');
        await pump();
        expect(storage.entries['me']!.value, 'profile-of-alice');
        action.value(m);
        user = 'bob';
        expect(await m.getData('me'), 'profile-of-bob');
        expect(calls, 2);
        expect(m.getCurrentValue('me'), 'profile-of-bob');
      });

      test('${action.key} then watch right away never resurrects', () async {
        final storage = InMemoryReactiveStorage<String, String>()
          ..entries['me'] = StoredEntry('profile-of-alice', DateTime(2026));
        final m = ReactiveDataManager<String, String>(
          fetcher: (_) async => 'profile-of-bob',
          storage: storage,
        );
        action.value(m);
        final seen = <String>[];
        final sub = m.watch('me').listen(seen.add);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(seen, ['profile-of-bob']);
        await sub.cancel();
      });
    }

    test('a slow pending write delays a later read until it landed', () async {
      final storage =
          _LoggingStorage([], delay: const Duration(milliseconds: 20));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: storage,
      );
      m.set('k', 5);
      m.evict('k');
      expect(await m.getData('k'), 1);
      expect(storage.log, ['w5', 'd', 'r']);
    });

    test('clearCache after hydration reads storage again only if refilled',
        () async {
      final storage = InMemoryReactiveStorage<String, int>()
        ..entries['k'] = StoredEntry(7, DateTime(2026));
      var n = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++n,
        storage: storage,
      );
      expect(await m.getData('k'), 7);
      m.clearCache(); // no pump: the read below is ordered behind the clear
      expect(await m.getData('k'), 1); // hydrated value was cleared
      expect(n, 1);
    });
  });

  group('throwing user callbacks never hang a future or wedge a key', () {
    test('errorMapper: falls back to the raw error, key is reusable', () async {
      var calls = 0;
      var fail = true;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async {
          calls++;
          if (fail) throw StateError('raw');
          return 1;
        },
        errorMapper: (e, s) => throw ArgumentError('mapper bug'),
      );
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      final a = m.getData('k');
      final b = m.getData('k');
      await expectLater(a, throwsStateError)
          .timeout(const Duration(seconds: 1));
      await expectLater(b, throwsStateError)
          .timeout(const Duration(seconds: 1));
      expect(calls, 1);
      expect(errors.single, isA<StateError>());
      fail = false;
      expect(await m.getData('k'), 1);
      expect(calls, 2);
      await sub.cancel();
    });

    test('fetchFilter: every caller gets its error, key is reusable', () async {
      var calls = 0;
      var bad = true;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++calls,
        fetchFilter: (_, v) => bad ? throw StateError('filter bug') : v,
      );
      final a = m.getData('k');
      final b = m.getData('k');
      await expectLater(a, throwsStateError)
          .timeout(const Duration(seconds: 1));
      await expectLater(b, throwsStateError)
          .timeout(const Duration(seconds: 1));
      bad = false;
      expect(await m.getData('k'), 2);
      expect(m.getCurrentValue('k'), 2);
    });

    test('patch: a throwing transform changes nothing and keeps the fetch',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      final f = m.getData('k', forceRefresh: true);
      expect(
          () => m.patch('k', (_) => throw StateError('x')), throwsStateError);
      expect(m.getCurrentValue('k'), 1);
      gate.at(0).complete(2);
      expect(await f, 2);
      expect(m.getCurrentValue('k'), 2); // the fetch was not discarded
    });

    test('a storage adapter throwing synchronously never fails getData',
        () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: _SyncThrowingStorage(),
      );
      expect(await m.getData('k'), 1);
      m.set('k', 2);
      m.evict('k');
      expect(await m.getData('k'), 1);
      m.clearCache();
      expect(await m.getData('k'), 1);
      await pump();
    });
  });

  group('ReactiveValue async', () {
    test('concurrent getData/watch/refresh share one fetch', () async {
      var n = 0;
      final c = Completer<int>();
      final v = ReactiveValue<int>(fetcher: () {
        n++;
        return c.future;
      });
      final a = v.getData();
      final sub = v.watch().listen((_) {});
      final b = v.getData();
      expect(n, 1);
      c.complete(4);
      expect(await Future.wait([a, b]), [4, 4]);
      await sub.cancel();
    });

    test('clear during a fetch discards its result', () async {
      final c = Completer<int>();
      final v = ReactiveValue<int>(fetcher: () => c.future);
      final f = v.getData();
      v.clear();
      c.complete(1);
      await f;
      expect(v.currentValue, isNull);
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

class _SyncThrowingStorage implements ReactiveStorage<String, int> {
  @override
  Future<StoredEntry<int>?> read(String key) => throw StateError('read');
  @override
  Future<void> write(String key, StoredEntry<int> entry) =>
      throw StateError('write');
  @override
  Future<void> delete(String key) => throw StateError('delete');
  @override
  Future<void> clear() => throw StateError('clear');
}

class _LoggingStorage implements ReactiveStorage<String, int> {
  _LoggingStorage(this.log, {this.delay = Duration.zero});
  final List<String> log;
  final Duration delay;
  @override
  Future<StoredEntry<int>?> read(String key) async {
    log.add('r');
    return null;
  }

  @override
  Future<void> write(String key, StoredEntry<int> entry) async {
    await Future<void>.delayed(delay);
    log.add('w${entry.value}');
  }

  @override
  Future<void> delete(String key) async {
    await Future<void>.delayed(delay);
    log.add('d');
  }

  @override
  Future<void> clear() async => log.add('c');
}
