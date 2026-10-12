import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/testing.dart';

/// A fetcher whose calls are completed by hand.
class Gate {
  final calls = <Completer<int>>[];
  Future<int> call(String key) {
    final c = Completer<int>();
    calls.add(c);
    return c.future;
  }
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

typedef Scripted = ScriptedPageFetcher<String, int, int>;

void main() {
  group('ReactiveDataManager.prefetch', () {
    test('starts a fetch when nothing is cached', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.prefetch('k');
      expect(gate.calls, hasLength(1));
      gate.calls[0].complete(1);
      await pump();
      expect(m.getCurrentValue('k'), 1);
    });

    test('joins the fetch in flight', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final f = m.getData('k');
      m.prefetch('k');
      m.prefetch('k');
      expect(gate.calls, hasLength(1));
      gate.calls[0].complete(2);
      expect(await f, 2);
    });

    test('does nothing when the value is fresh', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.set('k', 3);
      m.prefetch('k');
      expect(gate.calls, isEmpty);
    });

    test('refetches a stale value', () async {
      var now = DateTime(2026);
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        maxAge: const Duration(seconds: 10),
        clock: () => now,
      );
      m.set('k', 3);
      now = now.add(const Duration(seconds: 10));
      m.prefetch('k');
      expect(gate.calls, hasLength(1));
      m.invalidate('k');
      m.prefetch('k'); // the invalidated fetch was detached: a new one starts
      expect(gate.calls, hasLength(2));
    });

    test('a failure is delivered through the stream only', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      final errors = <Object>[];
      final sub = m.getStream('k').listen((_) {}, onError: errors.add);
      m.prefetch('k');
      gate.calls[0].completeError(StateError('boom'));
      await pump();
      expect(errors, [isA<StateError>()]);
      await sub.cancel();
    });

    test('a failure without listeners is not an unhandled error', () async {
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(fetcher: gate.call);
      m.prefetch('k');
      gate.calls[0].completeError(StateError('boom'));
      await pump();
      await pump();
      expect(m.getCurrentValue('k'), isNull);
    });

    test('waits for a persisted value and keeps it when fresh', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(9, DateTime(2026));
      final gate = Gate();
      final m = ReactiveDataManager<String, int>(
        fetcher: gate.call,
        storage: storage,
        clock: () => DateTime(2026),
        maxAge: const Duration(minutes: 1),
      );
      m.prefetch('k');
      await pump();
      await pump();
      expect(m.getCurrentValue('k'), 9);
      expect(gate.calls, isEmpty);
    });

    test('ReactiveValue.prefetch', () async {
      var calls = 0;
      final v = ReactiveValue<int>(fetcher: () async => ++calls);
      v.prefetch();
      v.prefetch();
      await pump();
      expect(v.currentValue, 1);
      v.prefetch(); // fresh: no fetch
      await pump();
      expect(calls, 1);
    });
  });

  group('ReactivePagedManager.prefetch', () {
    ReactivePagedManager<String, int, int> make(
      Scripted s, {
      Duration? maxAge,
      DateTime Function()? clock,
      ReactiveStorage<String, PagedSnapshot<int>>? storage,
      int? maxEntries,
      void Function(String, PageDirection, Object, StackTrace)? onError,
    }) =>
        ReactivePagedManager<String, int, int>(
          fetchPage: s.call,
          idOf: (i) => i,
          maxAge: maxAge,
          clock: clock ?? DateTime.now,
          storage: storage,
          maxEntries: maxEntries,
          onError: onError,
        );

    test('loads the first page of an unknown query', () async {
      final s = Scripted();
      final m = make(s);
      m.prefetch('q');
      expect(s.requests.single.direction, PageDirection.initial);
      expect(m.peek('q')!.isLoadingInitial, isTrue);
      s.completeLast([1, 2], next: 2);
      await pump();
      expect(m.peek('q')!.items, [1, 2]);
    });

    test('does nothing while a head load runs or when fresh', () async {
      final s = Scripted();
      final m = make(s);
      m.prefetch('q');
      m.prefetch('q');
      expect(s.requests, hasLength(1));
      s.completeLast([1], next: 2);
      await pump();
      m.prefetch('q');
      expect(s.requests, hasLength(1));
    });

    test('does not disturb a loadNext in flight on fresh data', () async {
      final s = Scripted();
      final m = make(s);
      m.prefetch('q');
      s.completeLast([1], next: 2);
      await pump();
      final n = m.loadNext('q');
      m.prefetch('q');
      expect(s.requests, hasLength(2));
      s.completeLast([2]);
      expect((await n).items, [1, 2]);
    });

    test('refetches an invalidated or expired query', () async {
      var now = DateTime(2026);
      final s = Scripted();
      final m = make(s, maxAge: const Duration(seconds: 10), clock: () => now);
      m.prefetch('q');
      s.completeLast([1]);
      await pump();
      m.invalidate('q');
      m.prefetch('q');
      expect(s.requests, hasLength(2));
      s.completeLast([1, 2]);
      await pump();
      expect(m.peek('q')!.isStale, isFalse);
      now = now.add(const Duration(seconds: 10));
      m.prefetch('q');
      expect(s.requests, hasLength(3));
      s.completeLast([1, 2, 3]);
      await pump();
      expect(m.peek('q')!.items, [1, 2, 3]);
    });

    test('revalidates a snapshot restored from storage', () async {
      final storage = InMemoryReactiveStorage<String, PagedSnapshot<int>>();
      storage.entries['q'] =
          StoredEntry(const PagedSnapshot([7]), DateTime(2026));
      final s = Scripted();
      final m = make(s, storage: storage, clock: () => DateTime(2026));
      final sub = m.watch('q', fetch: false).listen((_) {});
      await pump();
      await pump();
      expect(m.peek('q')!.items, [7]);
      expect(s.requests, isEmpty);
      m.prefetch('q');
      expect(s.requests, hasLength(1));
      s.completeLast([8]);
      await pump();
      expect(m.peek('q')!.items, [8]);
      await sub.cancel();
    });

    test('a failure lands in the state and onError, never thrown', () async {
      final s = Scripted();
      final errors = <Object>[];
      final m = make(s, onError: (q, d, e, st) => errors.add(e));
      m.prefetch('q');
      s.failLast(StateError('boom'));
      await pump();
      expect(m.peek('q')!.hasInitialError, isTrue);
      expect(errors, [isA<StateError>()]);
      // A failed first load counts as "nothing loaded": prefetch retries.
      m.prefetch('q');
      expect(s.requests, hasLength(2));
    });

    test('prefetched queries are unwatched entries (LRU)', () async {
      final s = Scripted();
      final m = make(s, maxEntries: 1);
      m.prefetch('a');
      m.prefetch('b');
      expect(m.cachedQueries, ['b']);
      expect(s.requests.first.signal.aborted, isTrue);
    });

    test('no-op after dispose', () async {
      final s = Scripted();
      final m = make(s);
      await m.dispose();
      m.prefetch('q');
      expect(s.requests, isEmpty);
      expect(m.peek('q'), isNull);
    });
  });
}
