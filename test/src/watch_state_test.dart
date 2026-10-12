import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// A fetcher whose calls are completed by hand.
class Gate {
  final calls = <Completer<int>>[];
  Future<int> call(String key) {
    final c = Completer<int>();
    calls.add(c);
    return c.future;
  }
}

Future<void> pump() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final t0 = DateTime(2026);

/// Collects the states (and any stream error, which must never happen).
class Recorder {
  Recorder(Stream<DataState<int>> stream) {
    sub = stream.listen(
      states.add,
      onError: (Object e) => streamErrors.add(e),
      onDone: () => done = true,
    );
  }
  final states = <DataState<int>>[];
  final streamErrors = <Object>[];
  bool done = false;
  late final StreamSubscription<DataState<int>> sub;

  DataState<int> get last => states.last;
  Future<void> cancel() => sub.cancel();
}

ReactiveDataManager<String, int> make(
  Gate gate, {
  Duration? maxAge,
  DateTime Function()? clock,
  bool replayErrors = true,
  Object Function(Object, StackTrace)? errorMapper,
  ReactiveStorage<String, int>? storage,
  Future<dynamic> Function(String, int)? updater,
  int? maxEntries,
}) =>
    ReactiveDataManager<String, int>(
      fetcher: gate.call,
      maxAge: maxAge,
      clock: clock ?? () => t0,
      replayErrors: replayErrors,
      errorMapper: errorMapper,
      storage: storage,
      updater: updater,
      maxEntries: maxEntries,
    );

const loading = DataState<int>(isLoading: true);
DataState<int> data(int v, {bool loading = false, bool stale = false}) =>
    DataState<int>(
      data: v,
      hasData: true,
      fetchedAt: t0,
      isLoading: loading,
      isStale: stale,
    );

void main() {
  group('DataState', () {
    test('value equality, getters, errorAs, toString', () {
      final trace = StackTrace.current;
      final a = DataState<int>(
        data: 1,
        hasData: true,
        isLoading: true,
        error: 'e',
        stackTrace: trace,
        fetchedAt: t0,
        isStale: true,
      );
      final b = DataState<int>(
        data: 1,
        hasData: true,
        isLoading: true,
        error: 'e',
        stackTrace: trace,
        fetchedAt: t0,
        isStale: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(data(1)));
      expect(a, isNot(const DataState<int>()));
      expect(a.hasError, isTrue);
      expect(a.isLoadingInitial, isFalse);
      expect(loading.isLoadingInitial, isTrue);
      expect(a.errorAs<String>(), 'e');
      expect(a.errorAs<int>(), isNull);
      expect(const DataState<int>().errorAs<String>(), isNull);
      expect(const DataState<int>().hasError, isFalse);
      expect(a.toString(), 'DataState(data: 1, loading, stale, error: e)');
      expect(const DataState<int>().toString(), 'DataState(no data)');
      expect(identical(a, a) && a == a, isTrue);
    });

    test('a null value is data too', () {
      const s = DataState<int?>(hasData: true);
      expect(s.data, isNull);
      expect(s, isNot(const DataState<int?>()));
      expect(s.toString(), 'DataState(data: null)');
    });
  });

  group('watchState', () {
    test('fetches when missing: loading, then data', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      await pump();
      expect(r.states, [loading]);
      gate.calls.single.complete(1);
      await pump();
      expect(r.states, [loading, data(1)]);
      expect(r.streamErrors, isEmpty);
      await r.cancel();
    });

    test('fetch: false only observes', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k', fetch: false));
      await pump();
      expect(r.states, [const DataState<int>()]);
      expect(gate.calls, isEmpty);
      m.set('k', 3);
      await pump();
      expect(r.states, [const DataState<int>(), data(3)]);
      await r.cancel();
    });

    test('a fresh value: one state, no fetch', () async {
      final gate = Gate();
      final m = make(gate);
      m.set('k', 2);
      final r = Recorder(m.watchState('k'));
      await pump();
      expect(r.states, [data(2)]);
      expect(gate.calls, isEmpty);
      await r.cancel();
    });

    test('a stale value is kept while it is refetched', () async {
      var now = t0;
      final gate = Gate();
      final m =
          make(gate, maxAge: const Duration(minutes: 1), clock: () => now);
      m.set('k', 1);
      now = t0.add(const Duration(minutes: 1));
      final r = Recorder(m.watchState('k'));
      await pump();
      expect(r.states, [data(1, loading: true, stale: true)]);
      gate.calls.single.complete(2);
      await pump();
      expect(r.last, DataState<int>(data: 2, hasData: true, fetchedAt: now));
      await r.cancel();
    });

    test('errors are state, never stream errors; data is kept', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      final trace = StackTrace.current;
      gate.calls[0].completeError(StateError('boom'), trace);
      await pump();
      expect(r.last.isLoading, isFalse);
      expect(r.last.hasData, isFalse);
      expect(r.last.errorAs<StateError>(), isA<StateError>());
      expect(r.last.stackTrace, trace);
      expect(r.last.hasError, isTrue);

      // The next fetch clears the error when it starts.
      m.refresh('k');
      await pump();
      expect(r.last, loading);
      gate.calls[1].complete(1);
      await pump();
      expect(r.last, data(1));

      // A failing refresh keeps the data next to the error.
      m.refresh('k');
      gate.calls[2].completeError('again');
      await pump();
      expect(r.last.data, 1);
      expect(r.last.hasData, isTrue);
      expect(r.last.error, 'again');
      expect(r.streamErrors, isEmpty);
      await r.cancel();
    });

    test('late listeners get the error in the state, no replay', () async {
      for (final replay in [true, false]) {
        final gate = Gate();
        final m = make(gate, replayErrors: replay);
        m.getData('k').ignore();
        gate.calls[0].completeError('boom');
        await pump();
        final r = Recorder(m.watchState('k', fetch: false));
        await pump();
        final state = r.states.single;
        expect(state.error, 'boom');
        expect(state.stackTrace, isNotNull);
        expect(state.hasData || state.isLoading, isFalse);
        expect(r.streamErrors, isEmpty);
        await r.cancel();
      }
    });

    test('errorMapper applies to the state', () async {
      final gate = Gate();
      final m = make(gate, errorMapper: (e, s) => 'mapped');
      final r = Recorder(m.watchState('k'));
      gate.calls[0].completeError(StateError('x'));
      await pump();
      expect(r.last.error, 'mapped');
      await r.cancel();
    });

    test('a write clears the error', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      gate.calls[0].completeError('boom');
      await pump();
      m.set('k', 4);
      await pump();
      expect(r.last, data(4));
      await r.cancel();
    });

    test('invalidate: unwatched marks stale; watched refetches', () async {
      final gate = Gate();
      final m = make(gate);
      m.set('k', 1);
      final r = Recorder(m.watchState('k'));
      await pump();
      m.invalidate('k');
      await pump();
      expect(gate.calls, hasLength(1));
      expect(r.states, [data(1), data(1, loading: true, stale: true)]);
      gate.calls[0].complete(2);
      await pump();
      expect(r.last, data(2));
      await r.cancel();

      // Unwatched now: only marked.
      m.invalidate('k');
      expect(gate.calls, hasLength(1));
      expect(m.isFresh('k'), isFalse);
    });

    test('race: listen during a fetch, then invalidate, then set', () async {
      final gate = Gate();
      final m = make(gate);
      final first = m.getData('k');
      final r = Recorder(m.watchState('k')); // joins the fetch in flight
      await pump();
      expect(gate.calls, hasLength(1));
      expect(r.states, [loading]);
      m.invalidate('k'); // watched: the fetch is detached and restarted
      expect(gate.calls, hasLength(2));
      m.set('k', 5); // detaches the refetch too
      await pump();
      expect(r.states, [loading, data(5)]);
      gate.calls[0].complete(1);
      gate.calls[1].complete(2);
      expect(await first, 1);
      await pump();
      expect(r.states, [loading, data(5)]); // neither result was written
      expect(m.getCurrentValue('k'), 5);
      await r.cancel();
    });

    test('race: invalidate of a watched key while its fetch runs', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      await pump();
      m.invalidate('k');
      gate.calls[1].complete(2); // the refetch wins
      await pump();
      gate.calls[0].complete(1); // detached: ignored
      await pump();
      expect(r.states, [loading, data(2)]);
      await r.cancel();
    });

    test('race: a superseded fetch failing late changes nothing', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      await pump();
      m.refresh('k');
      gate.calls[0].completeError('old');
      await pump();
      expect(r.states, [loading]);
      gate.calls[1].complete(3);
      await pump();
      expect(r.states, [loading, data(3)]);
      await r.cancel();
    });

    test('set, patch and updateData (with rollback) emit', () async {
      final gate = Gate();
      final update = Completer<void>();
      final m = make(gate, updater: (k, v) => update.future);
      final r = Recorder(m.watchState('k', fetch: false));
      m.set('k', 1);
      await pump();
      m.patch('k', (v) => v + 1);
      await pump();
      final u = m.updateData('k', 10);
      await pump();
      update.completeError('rejected');
      await expectLater(u, throwsA(isA<OptimisticUpdateException>()));
      await pump();
      expect(r.states.map((s) => s.data), [null, 1, 2, 10, 2]);
      expect(r.last.errorAs<OptimisticUpdateException>(), isNotNull);
      expect(r.streamErrors, isEmpty);
      await r.cancel();
    });

    test('a rollback to "no value" emits the empty state with the error',
        () async {
      final gate = Gate();
      final update = Completer<void>();
      final m = make(gate, updater: (k, v) => update.future);
      final r = Recorder(m.watchState('k', fetch: false));
      final u = m.updateData('k', 10);
      await pump();
      update.completeError('rejected');
      await expectLater(u, throwsA(isA<OptimisticUpdateException>()));
      await pump();
      expect(r.last.hasData, isFalse);
      expect(r.last.hasError, isTrue);
      await r.cancel();
    });

    test('clearCache resets every watched key; in-flight fetches stop',
        () async {
      final gate = Gate();
      final m = make(gate);
      m.set('a', 1);
      final a = Recorder(m.watchState('a'));
      final b = Recorder(m.watchState('b'));
      await pump();
      expect(b.last, loading);
      m.clearCache();
      await pump();
      expect(a.last, const DataState<int>());
      expect(b.last, const DataState<int>());
      await a.cancel();
      await b.cancel();
    });

    test('evict resets the state and the stream keeps working', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      gate.calls[0].complete(1);
      await pump();
      m.evict('k');
      await pump();
      expect(r.done, isFalse);
      expect(r.last, const DataState<int>());
      // Still watched: invalidate refetches.
      m.invalidate('k');
      expect(gate.calls, hasLength(2));
      gate.calls[1].complete(7);
      await pump();
      expect(r.last, data(7));
      await r.cancel();
    });

    test('equal states are not re-emitted', () async {
      final gate = Gate();
      final m = make(gate);
      m.set('k', 1);
      final r = Recorder(m.watchState('k'));
      await pump();
      await m.getData('k'); // fresh: nothing changes
      m.set('k', 1); // same value, same clock
      m.invalidate('other');
      await pump();
      expect(r.states, [data(1)]);
      await r.cancel();
    });

    test('several listeners; cancelling one keeps the other', () async {
      final gate = Gate();
      final m = make(gate);
      final a = Recorder(m.watchState('k', fetch: false));
      final b = Recorder(m.watchState('k', fetch: false));
      await pump();
      await a.cancel();
      m.set('k', 1);
      await pump();
      expect(a.states, [const DataState<int>()]);
      expect(b.last, data(1));
      await b.cancel();
      m.invalidate('k'); // nobody watches: no refetch
      expect(gate.calls, isEmpty);
    });

    test('a watched key is not evicted by maxEntries', () async {
      final gate = Gate();
      final m = make(gate, maxEntries: 1);
      m.set('a', 1);
      final r = Recorder(m.watchState('a'));
      await pump();
      m.set('b', 2);
      m.set('c', 3);
      expect(m.getCurrentValue('a'), 1);
      expect(m.getCurrentValue('b'), isNull);
      await r.cancel();
    });

    test('dispose closes the stream; listening afterwards', () async {
      final gate = Gate();
      final m = make(gate);
      final r = Recorder(m.watchState('k'));
      await pump();
      m.dispose();
      await pump();
      expect(r.done, isTrue);
      final late = Recorder(m.watchState('k'));
      await pump();
      expect(late.states, [const DataState<int>()]);
      expect(late.done, isTrue);
      expect(gate.calls, hasLength(1));
    });

    test('hydration: reading, then the restored value', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(9, t0);
      final gate = Gate();
      final m = make(gate, storage: storage);
      final r = Recorder(m.watchState('k', fetch: false));
      await pump();
      expect(r.states, [loading, data(9)]);
      expect(gate.calls, isEmpty);
      await r.cancel();
    });

    test('hydration of a stale value refetches without flicker', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(9, t0);
      final gate = Gate();
      final m = make(gate,
          storage: storage,
          maxAge: const Duration(minutes: 1),
          clock: () => t0.add(const Duration(hours: 1)));
      final r = Recorder(m.watchState('k'));
      await pump();
      expect(r.states, [
        loading,
        data(9, loading: true, stale: true),
      ]);
      gate.calls.single.complete(1);
      await pump();
      expect(r.last.data, 1);
      expect(r.last.isLoading, isFalse);
      expect(r.last.isStale, isFalse);
      await r.cancel();
    });

    test('hydration with nothing stored ends the reading state', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      final gate = Gate();
      final m = make(gate, storage: storage);
      final r = Recorder(m.watchState('k', fetch: false));
      await pump();
      expect(r.states, [loading, const DataState<int>()]);
      await r.cancel();
    });

    test('hydration + invalidate before the read finished', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(9, t0);
      final gate = Gate();
      final m = make(gate, storage: storage);
      final r = Recorder(m.watchState('k', fetch: false));
      m.invalidate('k'); // watched: refetch after the read
      await pump();
      expect(r.last, data(9, loading: true, stale: true));
      gate.calls.single.complete(10);
      await pump();
      expect(r.last, data(10));
      await r.cancel();
    });

    test('hydration races a set: memory wins', () async {
      final storage = InMemoryReactiveStorage<String, int>();
      storage.entries['k'] = StoredEntry(9, t0);
      final gate = Gate();
      final m = make(gate, storage: storage);
      final r = Recorder(m.watchState('k', fetch: false));
      m.set('k', 1);
      await pump();
      expect(r.last, data(1));
      expect(r.states.where((s) => s.data == 9), isEmpty);
      await r.cancel();
    });

    test('a state is emitted once per operation', () {
      fakeAsync((async) {
        final gate = Gate();
        final m = make(gate);
        final states = <DataState<int>>[];
        m.watchState('k').listen(states.add);
        async.flushMicrotasks();
        gate.calls.single.complete(1);
        async.flushMicrotasks();
        // No intermediate "data + still loading" state.
        expect(states, [loading, data(1)]);
      });
    });

    test('ReactiveValue.watchState', () async {
      var n = 0;
      final v = ReactiveValue<int>(fetcher: () async => ++n, clock: () => t0);
      final states = <DataState<int>>[];
      final sub = v.watchState().listen(states.add);
      await pump();
      expect(states, [loading, data(1)]);
      v.invalidate(); // watched: refetches
      await pump();
      expect(states.last, data(2));
      await sub.cancel();
      final passive = <DataState<int>>[];
      final sub2 = v.watchState(fetch: false).listen(passive.add);
      await pump();
      expect(passive, [data(2)]);
      expect(n, 2);
      await sub2.cancel();
    });
  });
}
