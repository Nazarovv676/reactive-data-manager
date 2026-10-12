import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/src/engine/storage_queue.dart';

/// A storage whose reads and writes are completed by hand.
class SlowStorage<K, V> implements ReactiveStorage<K, V> {
  final reads = <K>[];
  final readGates = <Completer<StoredEntry<V>?>>[];
  final writeGates = <Completer<void>>[];
  final written = <K, StoredEntry<V>>{};
  bool holdWrites = false;

  @override
  Future<StoredEntry<V>?> read(K key) {
    reads.add(key);
    final c = Completer<StoredEntry<V>?>();
    readGates.add(c);
    return c.future;
  }

  @override
  Future<void> write(K key, StoredEntry<V> entry) {
    written[key] = entry;
    if (!holdWrites) return Future.value();
    final c = Completer<void>();
    writeGates.add(c);
    return c.future;
  }

  @override
  Future<void> delete(K key) async => written.remove(key);

  @override
  Future<void> clear() async => written.clear();
}

const _timeout = Duration(seconds: 2);

void main() {
  group('StorageQueue.readTimeout', () {
    test('a slow read reads as null at the timeout; the late result is dropped',
        () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final q = StorageQueue<String, int>(storage, 0, readTimeout: _timeout);
        StoredEntry<int>? got;
        var done = false;
        q.read('a').then((e) {
          got = e;
          done = true;
        });
        async.flushMicrotasks();
        expect(storage.reads, ['a']);
        async.elapse(const Duration(milliseconds: 1999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue);
        expect(got, isNull);
        storage.readGates.single.complete(StoredEntry(1, DateTime(2026)));
        async.flushMicrotasks();
        expect(got, isNull);
      });
    });

    test('a read within the limit returns the entry and cancels its timer', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final q = StorageQueue<String, int>(storage, 0, readTimeout: _timeout);
        StoredEntry<int>? got;
        q.read('a').then((e) => got = e);
        async.elapse(const Duration(seconds: 1));
        storage.readGates.single.complete(StoredEntry(7, DateTime(2026)));
        async.flushMicrotasks();
        expect(got!.value, 7);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a throwing adapter still reads as null and cancels the timer', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final q = StorageQueue<String, int>(storage, 0, readTimeout: _timeout);
        var done = false;
        StoredEntry<int>? got = StoredEntry(0, DateTime(2026));
        q.read('a').then((e) {
          got = e;
          done = true;
        });
        async.flushMicrotasks();
        storage.readGates.single.completeError(StateError('corrupt'));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(got, isNull);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the limit includes the wait behind queued writes', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>()..holdWrites = true;
        final q = StorageQueue<String, int>(storage, 0, readTimeout: _timeout);
        q.write('a', 1, DateTime(2026)); // stuck
        var done = false;
        q.read('a').then((e) => done = true);
        async.elapse(_timeout);
        expect(done, isTrue);
        // The write finishes later: the abandoned read never hits the adapter.
        storage.writeGates.single.complete();
        async.flushMicrotasks();
        expect(storage.reads, isEmpty);
      });
    });

    test('without a limit a read waits as long as the adapter takes', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final q = StorageQueue<String, int>(storage, 0);
        StoredEntry<int>? got;
        q.read('a').then((e) => got = e);
        async.elapse(const Duration(days: 1));
        expect(got, isNull);
        expect(async.pendingTimers, isEmpty);
        storage.readGates.single.complete(StoredEntry(3, DateTime(2026)));
        async.flushMicrotasks();
        expect(got!.value, 3);
      });
    });
  });

  group('ReactiveDataManager.storageReadTimeout', () {
    test('a stuck read does not block getData; the late value is dropped', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        var fetches = 0;
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async {
            fetches++;
            return 42;
          },
          storage: storage,
          storageReadTimeout: _timeout,
        );
        int? got;
        m.getData('k').then((v) => got = v);
        async.elapse(const Duration(seconds: 1));
        expect(fetches, 0); // still reading
        async.elapse(const Duration(seconds: 1));
        expect(got, 42);
        expect(fetches, 1);
        storage.readGates.single.complete(StoredEntry(1, DateTime(2026)));
        async.flushMicrotasks();
        expect(m.getCurrentValue('k'), 42);
        // evict forgets the timed-out read: the next getData reads again.
        m.evict('k');
        async.flushMicrotasks();
        m.getData('k').ignore();
        async.flushMicrotasks();
        expect(storage.reads, ['k', 'k']);
        m.dispose();
      });
    });

    test('a timed-out read is not retried while the key stays in memory', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 42,
          storage: storage,
          storageReadTimeout: _timeout,
          maxAge: const Duration(minutes: 1),
        );
        final values = <int?>[];
        m.getStream('k').listen(values.add);
        async.elapse(_timeout);
        expect(storage.reads, ['k']);
        expect(values, isEmpty); // nothing restored, nothing fetched
        m.getData('k').ignore();
        async.flushMicrotasks();
        expect(storage.reads, ['k']);
        expect(values, [42]);
        m.dispose();
      });
    });

    test('a fast read restores the persisted value', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final m = ReactiveDataManager<String, int>(
          fetcher: (k) async => 42,
          storage: storage,
          storageReadTimeout: _timeout,
          clock: () => DateTime(2026),
          maxAge: const Duration(minutes: 1),
        );
        int? got;
        m.getData('k').then((v) => got = v);
        async.elapse(const Duration(milliseconds: 500));
        storage.readGates.single.complete(StoredEntry(1, DateTime(2026)));
        async.flushMicrotasks();
        expect(got, 1);
        expect(async.pendingTimers, isEmpty);
        m.dispose();
      });
    });

    test('ReactiveValue forwards storageReadTimeout', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final v = ReactiveValue<int>(
          fetcher: () async => 5,
          storage: storage,
          storageReadTimeout: _timeout,
        );
        int? got;
        v.getData().then((x) => got = x);
        async.elapse(_timeout);
        expect(got, 5);
        v.dispose();
      });
    });

    test('ReactiveValue.cancellable forwards storageReadTimeout', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, int>();
        final v = ReactiveValue<int>.cancellable(
          fetcher: (signal) async => 6,
          storage: storage,
          storageReadTimeout: _timeout,
        );
        int? got;
        v.getData().then((x) => got = x);
        async.elapse(_timeout);
        expect(got, 6);
        v.dispose();
      });
    });
  });

  group('ReactivePagedManager.storageReadTimeout', () {
    test('a late snapshot is dropped', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, PagedSnapshot<int>>();
        final m = ReactivePagedManager<String, int, int>(
          fetchPage: (r) async => const PageResult([1]),
          idOf: (i) => i,
          storage: storage,
          storageReadTimeout: _timeout,
        );
        final states = <PagedState<int>>[];
        final sub = m.watch('q', fetch: false).listen(states.add);
        async.elapse(_timeout);
        storage.readGates.single
            .complete(StoredEntry(const PagedSnapshot([9]), DateTime(2026)));
        async.flushMicrotasks();
        expect(m.peek('q')!.hasLoaded, isFalse);
        expect(states.every((s) => s.items.isEmpty), isTrue);
        sub.cancel();
        m.dispose();
      });
    });

    test('a snapshot within the limit is restored', () {
      fakeAsync((async) {
        final storage = SlowStorage<String, PagedSnapshot<int>>();
        final m = ReactivePagedManager<String, int, int>(
          fetchPage: (r) async => const PageResult([1]),
          idOf: (i) => i,
          storage: storage,
          storageReadTimeout: _timeout,
        );
        final sub = m.watch('q', fetch: false).listen((_) {});
        async.elapse(const Duration(seconds: 1));
        storage.readGates.single
            .complete(StoredEntry(const PagedSnapshot([9]), DateTime(2026)));
        async.flushMicrotasks();
        expect(m.peek('q')!.items, [9]);
        sub.cancel();
        m.dispose();
      });
    });
  });
}
