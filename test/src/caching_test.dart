import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// A fetcher whose calls are completed by hand.
class Gate {
  final calls = <Completer<int>>[];
  final signals = <Future<void>>[];
  Future<int> call(String key, [Future<void>? cancel]) {
    final c = Completer<int>();
    calls.add(c);
    if (cancel != null) signals.add(cancel);
    return c.future;
  }
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('A: bugs', () {
    test('A1: concurrent getData joins one fetch, all futures complete',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final a = m.getData('k');
      final b = m.getData('k');
      final c = m.getData('k');
      expect(gate.calls, hasLength(1));
      gate.calls[0].complete(7);
      expect(await Future.wait([a, b, c]), [7, 7, 7]);
      expect(gate.calls, hasLength(1));
    });

    test('A1: joined callers all receive the error', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final a = expectLater(m.getData('k'), throwsStateError);
      final b = expectLater(m.getData('k'), throwsStateError);
      gate.calls[0].completeError(StateError('boom'));
      await Future.wait([a, b]);
      expect(gate.calls, hasLength(1));
    });

    test('forceRefresh supersedes: both callers get the newer result',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final a = m.getData('k');
      final b = m.getData('k', forceRefresh: true);
      expect(gate.calls, hasLength(2));
      gate.calls[0].complete(1); // older result is never written
      await pump();
      expect(m.getCurrentValue('k'), isNull);
      gate.calls[1].complete(2);
      expect(await a, 2);
      expect(await b, 2);
      expect(m.getCurrentValue('k'), 2);
    });

    test('A2: a cached read does not touch an in-flight forced refresh',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final first = m.getData('k');
      gate.calls[0].complete(1);
      await first;
      final refresh = m.getData('k', forceRefresh: true);
      expect(await m.getData('k'), 1);
      gate.calls[1].complete(2);
      expect(await refresh.timeout(const Duration(seconds: 1)), 2);
      expect(m.getCurrentValue('k'), 2);
    });

    test('A3: clearCache discards results of fetches started before it',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final inflight = m.getData('k');
      m.clearCache();
      gate.calls[0].complete(42);
      await inflight; // does not hang
      expect(m.getCurrentValue('k'), isNull);
      expect(m.isFresh('k'), isFalse);
    });

    test('A3: evict discards results of fetches started before it', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final inflight = m.getData('k');
      m.evict('k');
      gate.calls[0].complete(42);
      await inflight;
      expect(m.getCurrentValue('k'), isNull);
      expect(m.fetchedAt('k'), isNull);
    });

    test('A4: replayErrors false does not replay the old error', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('boom'),
        replayErrors: false,
      );
      await m.getData('k').then((_) {}, onError: (_) {});
      Object? got;
      final sub =
          m.getStream('k').listen((_) {}, onError: (Object e) => got = e);
      await pump();
      expect(got, isNull);
      // live listeners still get new errors
      await m.getData('k', forceRefresh: true).then((_) {}, onError: (_) {});
      await pump();
      expect(got, isA<StateError>());
      await sub.cancel();
    });

    test('A4: errors are replayed by default (unchanged)', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('boom'),
      );
      await m.getData('k').then((_) {}, onError: (_) {});
      await expectLater(m.getStream('k'), emitsError(isA<StateError>()));
    });
  });

  group('freshness', () {
    late DateTime now;
    late int calls;
    late ReactiveDataManager<String, int> m;

    setUp(() {
      now = DateTime(2026);
      calls = 0;
      m = ReactiveDataManager<String, int>(
        fetcher: (_) async => ++calls,
        maxAge: const Duration(seconds: 20),
        clock: () => now,
      );
    });

    test('maxAge, fetchedAt and isFresh use the injected clock', () async {
      expect(m.isFresh('k'), isFalse);
      expect(m.fetchedAt('k'), isNull);
      await m.getData('k');
      expect(m.fetchedAt('k'), DateTime(2026));
      now = now.add(const Duration(seconds: 19));
      expect(m.isFresh('k'), isTrue);
      expect(await m.getData('k'), 1);
      now = now.add(const Duration(seconds: 1));
      expect(m.isFresh('k'), isFalse);
      expect(m.isFresh('k', maxAge: const Duration(minutes: 1)), isTrue);
      expect(await m.getData('k'), 2);
      expect(await m.getData('k', maxAge: Duration.zero), 3);
    });

    test('invalidate keeps the value but refetches on next read', () async {
      await m.getData('k');
      m.invalidate('k');
      expect(m.getCurrentValue('k'), 1);
      expect(m.isFresh('k'), isFalse);
      expect(await m.getData('k'), 2);
      expect(m.isFresh('k'), isTrue);
    });

    test('invalidate discards an in-flight fetch, old value stays visible',
        () async {
      final gate = Gate();
      final g = ReactiveDataManager<String, int>(fetcher: gate.call);
      final first = g.getData('k');
      gate.calls[0].complete(1);
      await first;
      final refresh = g.getData('k', forceRefresh: true);
      g.invalidate('k');
      gate.calls[1].complete(99);
      await refresh;
      expect(g.getCurrentValue('k'), 1);
      expect(g.isFresh('k'), isFalse);
    });

    test('invalidateAll marks every key stale', () async {
      await m.getData('a');
      await m.getData('b');
      m.invalidateAll();
      expect(m.isFresh('a'), isFalse);
      expect(m.isFresh('b'), isFalse);
    });

    test('mutate invalidates after success and after failure', () async {
      await m.getData('k');
      expect(await m.mutate('k', () async => 'ok'), 'ok');
      expect(m.isFresh('k'), isFalse);
      await m.getData('k');
      await expectLater(
        m.mutate<void>('k', () async => throw StateError('x')),
        throwsStateError,
      );
      expect(m.isFresh('k'), isFalse);
      await m.getData('k');
      await m.mutate('k', () async {}, invalidate: false);
      expect(m.isFresh('k'), isTrue);
    });
  });

  group('refresh / watch', () {
    test('refresh is fire-and-forget; errors only on the stream', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('boom'),
      );
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      m.refresh('k');
      await pump();
      expect(errors, hasLength(1));
      await sub.cancel();
    });

    test('watch fetches, skips nulls and emits non-null values', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => ++n);
      final values = <int>[];
      final sub = m.watch('k').listen(values.add);
      await pump();
      expect(values, [1]);
      m.clearCache(); // null event is filtered
      m.refresh('k');
      await pump();
      expect(values, [1, 2]);
      await sub.cancel();
    });

    test('watch(fetch: false) does not fetch', () async {
      var n = 0;
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => ++n);
      final sub = m.watch('k', fetch: false).listen((_) {});
      await pump();
      expect(n, 0);
      await sub.cancel();
    });
  });

  group('set / patch', () {
    test('set writes synchronously and discards an older in-flight fetch',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = m.getData('k');
      m.set('k', 5);
      expect(m.getCurrentValue('k'), 5);
      expect(m.fetchedAt('k'), isNotNull);
      gate.calls[0].complete(1);
      await f;
      expect(m.getCurrentValue('k'), 5);
    });

    test('patch transforms the cached value, no-op when uncached', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      m.patch('k', (v) => v + 1);
      expect(m.getCurrentValue('k'), isNull);
      await m.getData('k');
      m.patch('k', (v) => v + 10);
      expect(m.getCurrentValue('k'), 11);
    });

    test('patch keeps invalidated state, set clears it', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      await m.getData('k');
      m.invalidate('k');
      m.patch('k', (v) => v + 1);
      expect(m.isFresh('k'), isFalse);
      m.set('k', 3);
      expect(m.isFresh('k'), isTrue);
    });
  });

  group('cancellation signal', () {
    test('superseded, invalidated, cleared and evicted fetches get the signal',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>.cancellable(
        fetcher: gate.call,
      );
      Future<bool> fired(int i) async {
        var done = false;
        gate.signals[i].then((_) => done = true);
        await pump();
        return done;
      }

      m.getData('a').ignore(); // #0
      m.getData('a', forceRefresh: true).ignore(); // #1 supersedes #0
      expect(await fired(0), isTrue);
      expect(await fired(1), isFalse);
      m.getData('b').ignore(); // #2
      m.invalidate('b');
      expect(await fired(2), isTrue);
      m.getData('d').ignore(); // #3
      m.evict('d');
      expect(await fired(3), isTrue);
      m.getData('c').ignore(); // #4
      expect(await fired(4), isFalse);
      m.clearCache();
      expect(await fired(4), isTrue);
      expect(await fired(1), isTrue); // cleared too
    });

    test('one-argument fetchers keep working', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      expect(await m.getData('k'), 1);
    });
  });

  group('typed errors', () {
    test('errorMapper surfaces the typed error on stream and future', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('raw'),
        errorMapper: (e, s) => 'mapped:${(e as StateError).message}',
      );
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      await expectLater(m.getData('k'), throwsA('mapped:raw'));
      await pump();
      expect(errors, ['mapped:raw']);
      await sub.cancel();
    });
  });

  group('ReactiveValue', () {
    test('shares join, maxAge, invalidate, watch, set and patch', () async {
      var n = 0;
      var now = DateTime(2026);
      final v = ReactiveValue<int>(
        fetcher: () async => ++n,
        maxAge: const Duration(seconds: 10),
        clock: () => now,
      );
      final a = v.getData();
      final b = v.getData();
      expect(await a, 1);
      expect(await b, 1);
      expect(n, 1);
      expect(v.isFresh(), isTrue);
      now = now.add(const Duration(seconds: 10));
      expect(v.isFresh(), isFalse);
      expect(await v.getData(), 2);
      v.patch((c) => c + 1);
      expect(v.currentValue, 3);
      v.set(10);
      expect(v.currentValue, 10);
      v.invalidate();
      expect(v.isFresh(), isFalse);
      expect(await v.watch().first, 10);
      v.dispose();
    });

    test('cancellable gets the signal', () async {
      final signals = <Future<void>>[];
      final v = ReactiveValue<int>.cancellable(fetcher: (cancel) {
        signals.add(cancel);
        return Completer<int>().future;
      });
      v.getData().ignore();
      v.invalidate();
      var fired = false;
      signals.single.then((_) => fired = true);
      await pump();
      expect(fired, isTrue);
    });
  });

  group('persistence', () {
    late InMemoryReactiveStorage<String, int> storage;
    late DateTime now;
    late int calls;

    ReactiveDataManager<String, int> make({int version = 0}) =>
        ReactiveDataManager<String, int>(
          fetcher: (_) async => 100 + ++calls,
          maxAge: const Duration(minutes: 1),
          clock: () => now,
          storage: storage,
          storageVersion: version,
        );

    setUp(() {
      storage = InMemoryReactiveStorage();
      now = DateTime(2026);
      calls = 0;
    });

    test('fresh persisted entry is emitted with original fetchedAt, no network',
        () async {
      storage.entries['k'] = StoredEntry(7, DateTime(2026));
      now = DateTime(2026).add(const Duration(seconds: 30));
      final m = make();
      expect(await m.getData('k'), 7);
      expect(calls, 0);
      expect(m.fetchedAt('k'), DateTime(2026));
    });

    test('stale persisted entry is emitted first, then refetched', () async {
      storage.entries['k'] = StoredEntry(7, DateTime(2026));
      now = DateTime(2026).add(const Duration(minutes: 5));
      final m = make();
      final seen = <int?>[];
      final sub = m.getStream('k').listen(seen.add);
      expect(await m.getData('k'), 101);
      await pump();
      expect(seen, [7, 101]);
      await sub.cancel();
    });

    test('concurrent hydrations join', () async {
      final reads = <String>[];
      final counting = _CountingStorage(storage, reads);
      storage.entries['k'] = StoredEntry(7, DateTime(2026));
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        clock: () => now,
        storage: counting,
      );
      await Future.wait([m.getData('k'), m.getData('k'), m.getData('k')]);
      expect(reads, ['k']);
    });

    test('write-through on fetch, set/updateData and rollback', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        updater: (k, v) async => throw StateError('no'),
        clock: () => now,
        storage: storage,
      );
      await m.getData('k');
      await pump();
      expect(storage.entries['k']!.value, 1);
      m.set('k', 2);
      await pump();
      expect(storage.entries['k']!.value, 2);
      await m.updateData('k', 3).then((_) {}, onError: (_) {});
      await pump();
      expect(storage.entries['k']!.value, 2); // rolled back and persisted
    });

    test('failures are never persisted', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => throw StateError('x'),
        storage: storage,
      );
      await m.getData('k').then((_) {}, onError: (_) {});
      await pump();
      expect(storage.entries, isEmpty);
    });

    test('invalidate keeps persisted value; evict and clearCache delete it',
        () async {
      final m = make();
      await m.getData('a');
      await m.getData('b');
      m.invalidate('a');
      await pump();
      expect(storage.entries.keys, containsAll(['a', 'b']));
      m.evict('a');
      await pump();
      expect(storage.entries.keys, ['b']);
      m.clearCache();
      await pump();
      expect(storage.entries, isEmpty);
    });

    test('invalidateAll before hydration marks persisted entries stale',
        () async {
      storage.entries['k'] = StoredEntry(7, DateTime(2026));
      final m = make();
      m.invalidateAll();
      now = DateTime(2026).add(const Duration(seconds: 1));
      expect(await m.getData('k'), 101);
    });

    test('storage errors never fail getData', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) async => 1,
        storage: _ThrowingStorage(),
      );
      expect(await m.getData('k'), 1);
      m.set('k', 2);
      m.evict('k');
      m.clearCache();
      await pump();
      expect(await m.getData('k'), 1);
    });

    test('storageVersion mismatch ignores and deletes the old entry', () async {
      storage.entries['k'] = StoredEntry(7, DateTime(2026), version: 1);
      final m = make(version: 2);
      expect(await m.getData('k'), 101);
      await pump();
      expect(storage.entries['k']!.version, 2);
    });
  });
}

class _CountingStorage implements ReactiveStorage<String, int> {
  _CountingStorage(this.inner, this.reads);
  final InMemoryReactiveStorage<String, int> inner;
  final List<String> reads;
  @override
  Future<StoredEntry<int>?> read(String key) async {
    reads.add(key);
    await pump();
    return inner.read(key);
  }

  @override
  Future<void> write(String key, StoredEntry<int> entry) =>
      inner.write(key, entry);
  @override
  Future<void> delete(String key) => inner.delete(key);
  @override
  Future<void> clear() => inner.clear();
}

class _ThrowingStorage implements ReactiveStorage<String, int> {
  @override
  Future<StoredEntry<int>?> read(String key) => throw StateError('corrupt');
  @override
  Future<void> write(String key, StoredEntry<int> entry) =>
      throw StateError('w');
  @override
  Future<void> delete(String key) => throw StateError('d');
  @override
  Future<void> clear() => throw StateError('c');
}
