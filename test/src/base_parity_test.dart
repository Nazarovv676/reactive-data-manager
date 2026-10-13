import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// A fetcher whose calls are completed by hand.
class Gate {
  final calls = <Completer<int>>[];
  final keys = <String>[];
  final signals = <AbortSignal>[];
  Future<int> call(String key, [AbortSignal? signal]) {
    final c = Completer<int>();
    calls.add(c);
    keys.add(key);
    if (signal != null) signals.add(signal);
    return c.future;
  }
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

bool fired(AbortSignal signal) => signal.aborted;

void main() {
  group('invalidate refetches a watched key', () {
    test('watch: refetches immediately, listeners get the new value', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final seen = <int>[];
      final sub = m.watch('k').listen(seen.add);
      gate.calls[0].complete(1);
      await pump();
      m.invalidate('k');
      expect(gate.calls, hasLength(2));
      expect(m.getCurrentValue('k'), 1); // stale-while-revalidate
      gate.calls[1].complete(2);
      await pump();
      expect(seen, [1, 2]);
      expect(m.isFresh('k'), isTrue);
      await sub.cancel();
    });

    test('an unwatched key is only marked stale', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      m.invalidate('k');
      expect(gate.calls, isEmpty);
      expect(m.isFresh('k'), isFalse);
      // Also after the last listener left.
      final sub = m.getStream('k').listen((_) {});
      await pump();
      await sub.cancel();
      m.invalidate('k');
      expect(gate.calls, isEmpty);
    });

    test('a getStream listener counts as watching (also without replay)',
        () async {
      for (final replay in [true, false]) {
        final gate = Gate();
        final m = ReactiveDataManager<String, int>(
          fetcher: gate.call,
          replayErrors: replay,
        );
        m.set('k', 1);
        final sub = m.getStream('k').listen((_) {});
        m.invalidate('k');
        expect(gate.calls, hasLength(1), reason: 'replayErrors: $replay');
        await sub.cancel();
      }
    });

    test('a watched key without a value refetches too', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final sub = m.watch('k', fetch: false).listen((_) {});
      m.invalidate('k');
      expect(gate.calls, hasLength(1));
      await sub.cancel();
    });

    test(
        'fetch in flight: detached (no signal), callers get its result, '
        'the refetch wins', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>.cancellable(
        fetcher: gate.call,
      );
      final seen = <int?>[];
      final sub = m.getStream('k').listen(seen.add);
      final first = m.getData('k');
      m.invalidate('k');
      expect(gate.calls, hasLength(2));
      expect(fired(gate.signals[0]), isFalse);
      gate.calls[0].complete(1);
      expect(await first, 1);
      await pump();
      expect(m.getCurrentValue('k'), isNull); // detached result not cached
      gate.calls[1].complete(2);
      await pump();
      expect(m.getCurrentValue('k'), 2);
      expect(seen, [2]);
      await sub.cancel();
    });

    test('a joined getData after invalidate gets the refetched value',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final sub = m.getStream('k').listen((_) {});
      m.set('k', 1);
      m.invalidate('k');
      final joined = m.getData('k');
      expect(gate.calls, hasLength(1));
      gate.calls[0].complete(2);
      expect(await joined, 2);
      await sub.cancel();
    });

    test('a failing refetch goes to the stream only', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      m.invalidate('k');
      gate.calls[0].completeError(StateError('boom'));
      await pump();
      expect(errors, [isA<StateError>()]);
      expect(m.getCurrentValue('k'), 1);
      await sub.cancel();
    });

    test('invalidateWhere refetches the matching watched keys', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('a1', 1);
      m.set('a2', 1);
      m.set('b', 1);
      final subs = [
        m.getStream('a1').listen((_) {}),
        m.getStream('b').listen((_) {}),
        m.getStream('a3').listen((_) {}), // watched, nothing cached
      ];
      m.invalidateWhere((k) => k.startsWith('a'));
      expect(gate.keys, unorderedEquals(['a1', 'a3']));
      expect(m.isFresh('a2'), isFalse);
      expect(m.isFresh('b'), isTrue);
      for (final s in subs) {
        await s.cancel();
      }
    });

    test('invalidateWhere detaches an in-flight fetch of an uncached key',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = m.getData('a');
      m.invalidateWhere((k) => k == 'a');
      gate.calls[0].complete(1);
      expect(await f, 1);
      expect(m.getCurrentValue('a'), isNull);
      expect(gate.calls, hasLength(1)); // unwatched: no refetch
    });

    test('invalidateAll refetches every watched key', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('a', 1);
      m.set('b', 1);
      final sub = m.getStream('a').listen((_) {});
      final sub2 = m.getStream('c').listen((_) {});
      final inFlight = m.getData('d');
      m.invalidateAll();
      expect(gate.keys, ['d', 'a', 'c']);
      gate.calls[0].complete(4);
      expect(await inFlight, 4);
      expect(m.getCurrentValue('d'), isNull);
      await sub.cancel();
      await sub2.cancel();
    });

    test('mutate refetches a watched key after the action, also on failure',
        () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      final sub = m.getStream('k').listen((_) {});
      final action = Completer<void>();
      final r = m.mutate('k', () => action.future);
      await pump();
      expect(gate.calls, isEmpty);
      action.complete();
      await r;
      expect(gate.calls, hasLength(1));
      gate.calls[0].complete(2);
      await pump();
      await expectLater(
        m.mutate('k', () async => throw StateError('x')),
        throwsStateError,
      );
      expect(gate.calls, hasLength(2));
      await sub.cancel();
    });

    test('a watched key whose persisted value is still being read', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(1, DateTime(2026));
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        storage: storage,
        clock: () => DateTime(2026),
      );
      final seen = <int?>[];
      final sub = m.getStream('k').listen(seen.add);
      m.invalidate('k'); // before the read finished
      await pump();
      await pump();
      expect(seen, [1]);
      expect(gate.calls, hasLength(1)); // restored value is stale
      gate.calls[0].complete(2);
      await pump();
      expect(seen, [1, 2]);
      await sub.cancel();
    });

    test('ReactiveValue.invalidate refetches while watched', () async {
      var n = 0;
      final v = ReactiveValue<int>(fetcher: () async => ++n);
      final seen = <int>[];
      final sub = v.watch().listen(seen.add);
      await pump();
      v.invalidate();
      await pump();
      expect(seen, [1, 2]);
      await sub.cancel();
      v.invalidate();
      await pump();
      expect(n, 2);
    });

    test('no refetch after dispose', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 1);
      m.getStream('k').listen((_) {});
      m.dispose();
      m.invalidate('k');
      m.invalidateAll();
      expect(gate.calls, isEmpty);
    });
  });

  group('maxEntries', () {
    test('must be at least 1', () {
      for (final v in [0, -1]) {
        expect(
          () => ReactiveDataManager<String, int>(
              fetcher: (_) async => 1, maxEntries: v),
          throwsArgumentError,
        );
        expect(
          () => ReactiveDataManager<String, int>.cancellable(
              fetcher: (_, __) async => 1, maxEntries: v),
          throwsArgumentError,
        );
      }
      ReactiveDataManager<String, int>(fetcher: (_) async => 1, maxEntries: 1);
    });

    test('keeps the most recent unwatched keys', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => k.length,
        maxEntries: 2,
      );
      await m.getData('a');
      await m.getData('bb');
      await m.getData('ccc');
      expect(m.getCurrentValue('a'), isNull);
      expect(m.fetchedAt('a'), isNull);
      expect(m.getCurrentValue('bb'), 2);
      expect(m.getCurrentValue('ccc'), 3);
    });

    test('watched keys are never evicted; LRU follows the last unwatch',
        () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => k.length,
        maxEntries: 1,
      );
      final sub = m.watch('a').listen((_) {});
      await pump();
      await m.getData('b');
      await m.getData('c');
      expect(m.getCurrentValue('a'), 1);
      expect(m.getCurrentValue('b'), isNull);
      await sub.cancel(); // 'a' is now the most recently unwatched
      expect(m.getCurrentValue('a'), 1);
      expect(m.getCurrentValue('c'), isNull);
    });

    test('evicting frees memory only: the persisted value comes back',
        () async {
      final storage = InMemoryReactiveStorage<String, int>();
      var fetches = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async {
          fetches++;
          return 10;
        },
        storage: storage,
        maxEntries: 1,
      );
      await m.getData('a');
      await m.getData('b');
      await pump();
      expect(m.getCurrentValue('a'), isNull);
      expect(storage.entries.keys, containsAll(['a', 'b']));
      expect(await m.getData('a'), 10);
      expect(fetches, 2); // restored from storage, not refetched
    });

    test('an invalidated key stays stale through eviction (storage)', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      var fetches = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => ++fetches,
        storage: storage,
        maxEntries: 1,
      );
      await m.getData('a');
      m.invalidate('a');
      await m.getData('b'); // evicts 'a'
      await pump();
      expect(m.getCurrentValue('a'), isNull);
      expect(await m.getData('a'), 3); // restored stale: refetched
    });

    test('without storage an evicted key starts from scratch', () async {
      var fetches = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => ++fetches,
        maxEntries: 1,
      );
      await m.getData('a');
      m.invalidate('a');
      await m.getData('b');
      expect(m.isFresh('a'), isFalse);
      expect(await m.getData('a'), 3);
      expect(m.isFresh('a'), isTrue);
    });

    test('a fetch in flight is detached, its callers get the result', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>.cancellable(
        fetcher: gate.call,
        maxEntries: 1,
      );
      m.set('a', 1);
      final f = m.getData('a', forceRefresh: true);
      m.set('b', 2); // evicts 'a'
      expect(fired(gate.signals[0]), isFalse);
      gate.calls[0].complete(5);
      expect(await f, 5);
      expect(m.getCurrentValue('a'), isNull);
    });

    test('a running update no longer rolls back an evicted key', () async {
      final update = Completer<void>();
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => 0,
        updater: (k, v) => update.future,
        maxEntries: 1,
      );
      m.set('a', 1);
      final u = m.updateData('a', 2);
      m.set('b', 2); // evicts 'a'
      update.completeError(StateError('x'));
      await expectLater(u, throwsA(isA<OptimisticUpdateException>()));
      expect(m.getCurrentValue('a'), isNull);
    });

    test('a stream obtained before eviction still works', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => k.length,
        maxEntries: 1,
      );
      final stream = m.getStream('a'); // not listened yet
      m.set('b', 2); // evicts 'a'
      final seen = <int?>[];
      final sub = stream.listen(seen.add);
      m.set('a', 1);
      await pump();
      expect(seen, [1]);
      await sub.cancel();
    });

    test('explicit evict of a watched key still closes its stream', () async {
      final m = ReactiveDataManager<String, int>(
        fetcher: (k) async => 1,
        maxEntries: 1,
      );
      m.set('a', 1);
      var done = false;
      final sub = m.getStream('a').listen((_) {}, onDone: () => done = true);
      m.evict('a');
      await pump();
      expect(done, isTrue);
      await sub.cancel();
      m.set('b', 1);
      m.set('c', 1);
      expect(m.getCurrentValue('b'), isNull);
    });
  });

  group('evictAfterUnwatched', () {
    test('drops an unwatched key after the duration', () {
      fakeAsync((async) {
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 1,
          evictAfterUnwatched: const Duration(seconds: 30),
        );
        m.getData('a');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 29));
        expect(m.getCurrentValue('a'), 1);
        async.elapse(const Duration(seconds: 1));
        expect(m.getCurrentValue('a'), isNull);
      });
    });

    test('the timer is cancelled by a re-watch and restarts on unwatch', () {
      fakeAsync((async) {
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 1,
          evictAfterUnwatched: const Duration(seconds: 30),
        );
        final sub = m.watch('a').listen((_) {});
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        expect(m.getCurrentValue('a'), 1); // watched
        sub.cancel();
        async.elapse(const Duration(seconds: 20));
        final again = m.getStream('a').listen((_) {}); // re-watch
        async.elapse(const Duration(seconds: 20));
        expect(m.getCurrentValue('a'), 1); // timer was cancelled
        again.cancel();
        async.elapse(const Duration(seconds: 29));
        expect(m.getCurrentValue('a'), 1);
        async.elapse(const Duration(seconds: 1));
        expect(m.getCurrentValue('a'), isNull);
      });
    });

    test('two listeners: the timer starts only when both left', () {
      fakeAsync((async) {
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 1,
          evictAfterUnwatched: const Duration(seconds: 10),
        );
        final a = m.watch('a').listen((_) {});
        final b = m.getStream('a').listen((_) {});
        async.flushMicrotasks();
        a.cancel();
        async.elapse(const Duration(minutes: 1));
        expect(m.getCurrentValue('a'), 1);
        b.cancel();
        async.elapse(const Duration(seconds: 10));
        expect(m.getCurrentValue('a'), isNull);
      });
    });

    test('dispose cancels the timers', () {
      fakeAsync((async) {
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 1,
          evictAfterUnwatched: const Duration(seconds: 10),
        );
        m.set('a', 1);
        expect(async.pendingTimers, hasLength(1));
        m.dispose();
        expect(async.pendingTimers, isEmpty);
        m.getStream('b'); // after dispose: not registered, no timer
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
