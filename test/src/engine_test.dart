import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/src/engine/entry_registry.dart';
import 'package:reactive_data_manager/src/engine/freshness.dart';
import 'package:reactive_data_manager/src/engine/operation.dart';
import 'package:reactive_data_manager/src/engine/storage_queue.dart';

class _E extends RegistryEntry {}

class _FailingStorage extends InMemoryReactiveStorage<String, int> {
  @override
  Future<StoredEntry<int>?> read(String key) async => throw StateError('x');

  @override
  Future<void> write(String key, StoredEntry<int> entry) async =>
      throw StateError('x');
}

void main() {
  group('Operation', () {
    test('discard aborts but callers keep the own outcome', () async {
      final op = Operation<int>();
      op.discard();
      expect(op.discarded, isTrue);
      expect(op.signal.aborted, isTrue);
      op.resolve(1);
      op.resolve(2);
      expect(await op.future, 1);
    });

    test('discardWith re-points callers to the replacement', () async {
      final old = Operation<int>();
      final next = Operation<int>();
      old.discardWith(next.future);
      old.resolve(1); // ignored: already completed
      next.resolve(2);
      expect(await old.future, 2);
      expect(old.signal.aborted, isTrue);
    });

    test('fail delivers the error once; an unawaited failure is ignored',
        () async {
      final op = Operation<int>()..fail(StateError('a'), StackTrace.empty);
      op.fail(StateError('b'), StackTrace.empty);
      await expectLater(op.future, throwsStateError);
      Operation<int>().fail(StateError('c'), StackTrace.empty); // no zone error
    });
  });

  group('InFlight', () {
    test('join per lane, finish only the current op, takeAll', () {
      final lanes = InFlight<String, Operation<int>>();
      final a = Operation<int>();
      final b = Operation<int>();
      lanes['x'] = a;
      lanes['y'] = b;
      expect(lanes['x'], same(a));
      lanes.finish('x', b); // not the current one of 'x'
      expect(lanes['x'], same(a));
      lanes.finish('x', a);
      expect(lanes['x'], isNull);
      expect(lanes.all, [b]);
      expect(lanes.takeAll(), [b]);
      expect(lanes.isEmpty, isTrue);
      expect(lanes.take('y'), isNull);
    });
  });

  group('Freshness', () {
    test('expiry against the clock, per-call override, missing time', () {
      var now = DateTime(2026);
      final f = Freshness(() => now, const Duration(seconds: 10));
      final at = DateTime(2026);
      expect(f.isExpired(at), isFalse);
      now = now.add(const Duration(seconds: 10));
      expect(f.isExpired(at), isTrue);
      expect(f.isExpired(at, maxAge: const Duration(minutes: 1)), isFalse);
      expect(f.isExpired(null), isTrue);
      expect(Freshness(() => now, null).isExpired(null), isFalse);
    });
  });

  group('StorageQueue', () {
    test('without storage everything is a no-op', () async {
      final q = StorageQueue<String, int>(null, 0)
        ..write('a', 1, DateTime(2026))
        ..delete('a')
        ..clear();
      expect(await q.read('a'), isNull);
    });

    test('version check deletes foreign entries; errors are swallowed',
        () async {
      final storage = InMemoryReactiveStorage<String, int>();
      final q = StorageQueue<String, int>(storage, 2)
        ..write('a', 1, DateTime(2026));
      await pumpEventQueue(); // writes are queued, reads are not
      final entry = await q.read('a');
      expect(entry!.version, 2);
      expect(q.accept('a', entry), isTrue);
      expect(
          q.accept('a', StoredEntry(1, DateTime(2026), version: 1)), isFalse);
      await pumpEventQueue();
      expect(storage.entries, isEmpty);

      final failing = StorageQueue<String, int>(_FailingStorage(), 0)
        ..write('a', 1, DateTime(2026))
        ..write('b', 2, DateTime(2026));
      expect(await failing.read('a'), isNull);
      await pumpEventQueue();
    });
  });

  group('EntryRegistry', () {
    test('LRU over unwatched entries and eviction timers', () {
      fakeAsync((async) {
        final evicted = <String>[];
        late final EntryRegistry<String, _E> reg;
        reg = EntryRegistry<String, _E>(
          maxEntries: 1,
          evictAfterUnwatched: const Duration(seconds: 5),
          onEvict: (k, e) {
            evicted.add(k);
            reg.remove(k, e);
          },
        );
        final a = _E();
        final b = _E();
        reg['a'] = a;
        reg.watch(a);
        reg['b'] = b;
        reg.unwatched('b', b);
        expect(evicted, isEmpty);
        expect(reg.unwatch(a), isTrue);
        reg.unwatched('a', a); // 'b' is now the least recently watched
        expect(evicted, ['b']);
        expect(reg.keys, ['a']);
        async.elapse(const Duration(seconds: 5));
        expect(evicted, ['b', 'a']);

        final c = _E();
        reg['c'] = c;
        reg.unwatched('c', c);
        reg.watch(c); // cancels the timer
        async.elapse(const Duration(seconds: 10));
        expect(reg.isCurrent('c', c), isTrue);
        expect(c.watchers, 1);
        reg.cancelEviction(c);
        reg.clear();
        expect(reg.snapshot(), isEmpty);
      });
    });

    test('touch restarts the timer of an unwatched current entry only', () {
      fakeAsync((async) {
        final evicted = <String>[];
        final reg = EntryRegistry<String, _E>(
          evictAfterUnwatched: const Duration(seconds: 5),
          onEvict: (k, e) => evicted.add(k),
        );
        final a = _E();
        final watched = _E();
        final stale = _E();
        reg['a'] = a;
        reg.unwatched('a', a);
        reg['w'] = watched;
        reg.watch(watched);
        reg['s'] = stale;
        reg['s'] = _E(); // `stale` is no longer the current entry
        async.elapse(const Duration(seconds: 4));
        reg.touch('a', a); // restarted: due at 9 s instead of 5 s
        reg.touch('w', watched); // watched: no timer
        reg.touch('s', stale); // replaced: no timer
        async.elapse(const Duration(seconds: 4));
        expect(evicted, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(evicted, ['a']);
        async.elapse(const Duration(minutes: 1));
        expect(evicted, ['a']);
      });
    });
  });
}
