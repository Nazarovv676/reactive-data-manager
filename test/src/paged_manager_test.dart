import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

typedef Item = ({String id, int v});

Item it(String id, [int v = 0]) => (id: id, v: v);
List<Item> items(Iterable<String> ids) => [for (final i in ids) it(i)];

Future<void> pump() => Future<void>.delayed(Duration.zero);

/// A page fetcher whose requests are completed by hand.
class Script {
  final reqs = <PageRequest<String, int>>[];
  final _calls = <Completer<PageResult<Item, int>>>[];

  Future<PageResult<Item, int>> call(PageRequest<String, int> r) {
    reqs.add(r);
    final c = Completer<PageResult<Item, int>>();
    _calls.add(c);
    return c.future;
  }

  void ok(int i, List<Item> list, {int? next, int? previous, int? total}) =>
      _calls[i].complete(
          PageResult(list, next: next, previous: previous, totalCount: total));

  void fail(int i, Object e) => _calls[i].completeError(e);
}

ReactivePagedManager<String, Item, int> make(
  Script s, {
  Duration? maxAge,
  int? maxEntries,
  Duration? evictAfterUnwatched,
  Retention retention = Retention.all,
  int maxUnproductive = 3,
  DateTime Function()? clock,
  void Function(String, PageDirection, Object, StackTrace)? onError,
}) =>
    ReactivePagedManager<String, Item, int>(
      fetchPage: s.call,
      idOf: (i) => i.id,
      maxAge: maxAge,
      maxEntries: maxEntries,
      evictAfterUnwatched: evictAfterUnwatched,
      retainWhenUnwatched: retention,
      maxUnproductivePages: maxUnproductive,
      onError: onError,
      clock: clock ?? DateTime.now,
    );

/// Loads the first page of [q] with [list] and the given next cursor.
Future<void> seed(
  ReactivePagedManager<String, Item, int> m,
  Script s,
  String q,
  List<Item> list, {
  int? next,
  int? previous,
}) async {
  final f = m.refresh(q);
  s.ok(s.reqs.length - 1, list, next: next, previous: previous);
  await f;
}

void main() {
  group('loading', () {
    test('refresh loads the first page and exposes the state', () async {
      final s = Script();
      final m = make(s);
      final f = m.refresh('q');
      expect(m.peek('q')!.isLoadingInitial, isTrue);
      s.ok(0, items(['a', 'b']), next: 2, total: 10);
      final st = await f;
      expect(st.items, items(['a', 'b']));
      expect(st.hasLoaded, isTrue);
      expect(st.next.hasMore, isTrue);
      expect(st.previous.hasMore, isFalse);
      expect(st.totalCount, 10);
      expect(st.fetchedAt, isNotNull);
      expect(st.isRefreshing, isFalse);
      expect(s.reqs.single.direction, PageDirection.initial);
      expect(s.reqs.single.cursor, isNull);
    });

    test('concurrent loadNext shares one request, no duplicate page', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final f = [m.loadNext('q'), m.loadNext('q'), m.loadNext('q')];
      expect(s.reqs, hasLength(2));
      expect(s.reqs[1].direction, PageDirection.next);
      expect(s.reqs[1].cursor, 2);
      expect(m.peek('q')!.next.isLoading, isTrue);
      s.ok(1, items(['c', 'd']), next: 3);
      final states = await Future.wait(f);
      for (final st in states) {
        expect(st.items.map((i) => i.id), ['a', 'b', 'c', 'd']);
      }
      expect(s.reqs, hasLength(2));
    });

    test('loadNext without a first page starts the initial load', () async {
      final s = Script();
      final m = make(s);
      final f = m.loadNext('q');
      expect(s.reqs.single.direction, PageDirection.initial);
      s.ok(0, items(['a']));
      expect((await f).items, items(['a']));
    });

    test('loadNext during the initial load joins it', () async {
      final s = Script();
      final m = make(s);
      final a = m.refresh('q');
      final b = m.loadNext('q');
      expect(s.reqs, hasLength(1));
      s.ok(0, items(['a']), next: 2);
      expect((await a).items, items(['a']));
      expect((await b).items, items(['a']));
    });

    test('loadNext without more pages is a no-op', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final st = await m.loadNext('q');
      expect(st.items, items(['a']));
      expect(s.reqs, hasLength(1));
    });

    test('loadPrevious prepends and is independent of loadNext', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['c', 'd']), next: 3, previous: 1);
      final n = m.loadNext('q');
      final p = m.loadPrevious('q');
      expect(s.reqs, hasLength(3));
      expect(s.reqs[2].direction, PageDirection.previous);
      expect(s.reqs[2].cursor, 1);
      s.ok(2, items(['a', 'b']));
      s.ok(1, items(['e']));
      await Future.wait([n, p]);
      expect(m.peek('q')!.items.map((i) => i.id), ['a', 'b', 'c', 'd', 'e']);
      expect(m.peek('q')!.previous.hasMore, isFalse);
    });

    test('refresh anchor is sent as the cursor; a different anchor supersedes',
        () async {
      final s = Script();
      final m = make(s);
      final a = m.refresh('q', anchor: 5);
      final same = m.refresh('q', anchor: 5);
      expect(s.reqs, hasLength(1));
      expect(s.reqs[0].cursor, 5);
      final b = m.refresh('q', anchor: 9);
      expect(s.reqs, hasLength(2));
      expect(s.reqs[0].signal.aborted, isTrue);
      s.ok(1, items(['z']));
      expect((await a).items, items(['z']));
      expect((await same).items, items(['z']));
      expect((await b).items, items(['z']));
    });

    test('refresh while loadNext: next result discarded, signal fired',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final next = m.loadNext('q');
      final refresh = m.refresh('q');
      expect(s.reqs[1].signal.aborted, isTrue);
      s.ok(2, items(['a2']));
      s.ok(1, items(['late'])); // older response arrives after: ignored
      expect((await next).items, items(['a2']));
      expect((await refresh).items, items(['a2']));
      await pump();
      expect(m.peek('q')!.items, items(['a2']));
    });

    test('refresh keeps previous items visible while refreshing', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      final mid = m.peek('q')!;
      expect(mid.isRefreshing, isTrue);
      expect(mid.items, items(['a']));
      s.ok(1, items(['b']));
      expect((await f).items, items(['b']));
    });
  });

  group('merging', () {
    test('shifting offsets: overlapping ids are not duplicated', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b', 'c']), next: 3);
      final f = m.loadNext('q');
      // a new item at the head shifted the list: 'c' comes again
      s.ok(1, [it('c', 9), it('d'), it('e')], next: 6);
      final st = await f;
      expect(st.items.map((i) => i.id), ['a', 'b', 'c', 'd', 'e']);
      expect(st.items[2].v, 9); // existing position, new value
    });

    test('loadedCount reflects local removals', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b', 'c']), next: 3);
      m.removeItem('b');
      m.loadNext('q').ignore();
      expect(s.reqs[1].loadedCount, 2);
    });

    test('items without identity are never deduped', () async {
      final s = Script();
      final m = ReactivePagedManager<String, int, int>(
        fetchPage: (r) async => PageResult([1, 1, 2],
            next: r.direction == PageDirection.initial ? 2 : null),
        idOf: (_) => null,
      );
      await m.refresh('q');
      final st = await m.loadNext('q');
      expect(st.items, [1, 1, 2, 1, 1, 2]);
      expect(s.reqs, isEmpty);
    });

    test('unproductive pages exhaust the edge after maxUnproductivePages',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.ok(1, items(['a']), next: 3);
      await pump();
      s.ok(2, items(['a']), next: 4);
      await pump();
      s.ok(3, items(['a']), next: 5);
      final st = await f;
      expect(s.reqs, hasLength(4)); // 1 initial + 3 unproductive
      expect(st.next.hasMore, isFalse);
    });

    test('an unproductive page followed by a productive one continues',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.ok(1, items(['a']), next: 3);
      await pump();
      s.ok(2, items(['b']), next: 4);
      final st = await f;
      expect(st.items.map((i) => i.id), ['a', 'b']);
      expect(st.next.hasMore, isTrue);
    });

    test('a cursor that does not move exhausts the edge immediately', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.ok(1, items(['b']), next: 2);
      final st = await f;
      expect(s.reqs, hasLength(2));
      expect(st.next.hasMore, isFalse);
    });
  });

  group('invalidate / evict / clear with loads in flight', () {
    for (final action
        in <String, void Function(ReactivePagedManager<String, Item, int>)>{
      'evict': (m) => m.evict('q'),
      'clearCache': (m) => m.clearCache(),
      'invalidate': (m) => m.invalidate('q'),
    }.entries) {
      test('${action.key}: results are never written, futures resolve',
          () async {
        final s = Script();
        final m = make(s);
        await seed(m, s, 'q', items(['a']), next: 2, previous: 0);
        final n = m.loadNext('q');
        final p = m.loadPrevious('q');
        final h = m.refresh('q');
        // refresh superseded both edges; loadNext/Previous futures follow it
        action.value(m);
        for (var i = 1; i < s.reqs.length; i++) {
          expect(s.reqs[i].signal.aborted, isTrue, reason: 'request $i');
        }
        for (var i = 1; i < s.reqs.length; i++) {
          s.ok(i, items(['zzz']));
        }
        await Future.wait([n, p, h]).timeout(const Duration(seconds: 1));
        await pump();
        expect(m.peek('q')?.items.any((i) => i.id == 'zzz') ?? false, isFalse);
      });
    }

    test('evict resets a watched query in place without closing the stream',
        () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      var done = false;
      final sub = m.watch('q').listen(states.add, onDone: () => done = true);
      await pump();
      s.ok(0, items(['a']));
      await pump();
      m.evict('q');
      await pump();
      expect(done, isFalse);
      expect(states.last.hasLoaded, isFalse);
      expect(states.last.items, isEmpty);
      expect(s.reqs, hasLength(1)); // no automatic refetch
      await sub.cancel();
    });

    test('clearCache starts no refetch and bumps in-flight loads', () async {
      final s = Script();
      final m = make(s);
      final f = m.refresh('q');
      m.clearCache();
      s.ok(0, items(['a']));
      await f;
      expect(m.peek('q'), isNull);
      expect(s.reqs, hasLength(1));
    });

    test('invalidate of an unwatched query only marks it stale', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      m.invalidate('q');
      expect(m.peek('q')!.isStale, isTrue);
      expect(m.peek('q')!.items, items(['a']));
      expect(s.reqs, hasLength(1));
    });

    test('invalidate of a watched query refetches and keeps items', () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.ok(0, items(['a']));
      await pump();
      m.invalidate('q');
      expect(s.reqs, hasLength(2));
      await pump();
      expect(states.last.items, items(['a']));
      expect(states.last.isRefreshing, isTrue);
      s.ok(1, items(['b']));
      await pump();
      expect(states.last.items, items(['b']));
      expect(states.last.isStale, isFalse);
      await sub.cancel();
    });

    test('invalidateWhere and invalidateAll', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'a1', items(['x']));
      await seed(m, s, 'a2', items(['x']));
      await seed(m, s, 'b1', items(['x']));
      m.invalidateWhere((q) => q.startsWith('a'));
      expect(m.peek('a1')!.isStale, isTrue);
      expect(m.peek('a2')!.isStale, isTrue);
      expect(m.peek('b1')!.isStale, isFalse);
      m.invalidateAll();
      expect(m.peek('b1')!.isStale, isTrue);
    });

    test('invalidate/evict of an unknown query does nothing', () {
      final m = make(Script());
      m.invalidate('nope');
      m.evict('nope');
      expect(m.peek('nope'), isNull);
    });
  });

  group('local edits and rebase', () {
    test('patchItem applies to every cached query, emits only for changes',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q1', [it('a'), it('b')]);
      await seed(m, s, 'q2', [it('a'), it('c')]);
      await seed(m, s, 'q3', [it('c')]);
      final emissions = <String, int>{};
      final subs = [
        for (final q in ['q1', 'q2', 'q3'])
          m.watch(q, fetch: false).listen((_) {
            emissions[q] = (emissions[q] ?? 0) + 1;
          }),
      ];
      await pump();
      emissions.clear();
      m.patchItem('a', (i) => it(i.id, 7));
      await pump();
      expect(m.peek('q1')!.items.first.v, 7);
      expect(m.peek('q2')!.items.first.v, 7);
      expect(emissions, {'q1': 1, 'q2': 1});
      m.patchItem('a', (i) => it(i.id, 8), where: (q) => q == 'q1');
      expect(m.peek('q1')!.items.first.v, 8);
      expect(m.peek('q2')!.items.first.v, 7);
      for (final sub in subs) {
        await sub.cancel();
      }
    });

    test('removeItem removes everywhere and adjusts totalCount', () async {
      final s = Script();
      final m = make(s);
      final f = m.refresh('q1');
      s.ok(0, [it('a'), it('b')], total: 5);
      await f;
      await seed(m, s, 'q2', [it('a')]);
      m.removeItem('a');
      expect(m.peek('q1')!.items, [it('b')]);
      expect(m.peek('q1')!.totalCount, 4);
      expect(m.peek('q2')!.items, isEmpty);
    });

    test('patch made mid-flight survives an older page containing the item',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', [it('a'), it('b')], next: 2);
      final f = m.loadNext('q');
      m.patchItem('b', (i) => it(i.id, 5));
      m.patchItem('c', (i) => it(i.id, 6)); // not loaded yet: replayed
      s.ok(1, [it('b', 0), it('c', 0), it('d', 0)]);
      final st = await f;
      expect(st.items, [it('a'), it('b', 5), it('c', 6), it('d')]);
    });

    test('remove made mid-flight keeps the item out of the arriving page',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      m.removeItem('c');
      s.ok(1, items(['c', 'd']));
      expect((await f).items.map((i) => i.id), ['a', 'd']);
    });

    test('upsert made mid-flight survives a replacing refresh', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      m.upsertItem('q', it('socket'));
      s.ok(1, items(['a', 'b']));
      expect((await f).items.map((i) => i.id), ['socket', 'a', 'b']);
    });

    test('patch made mid-flight is replayed onto a replacing refresh',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', [it('a')]);
      final f = m.refresh('q');
      m.patchItem('a', (i) => it(i.id, 3));
      s.ok(1, [it('a', 0)]);
      expect((await f).items, [it('a', 3)]);
    });

    test('upsert at the head is ignored while a previous page exists',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['b']), previous: 1);
      m.upsertItem('q', it('new'));
      expect(m.peek('q')!.items, items(['b']));
      // a present item is still replaced in place
      m.upsertItem('q', it('b', 4));
      expect(m.peek('q')!.items, [it('b', 4)]);
    });

    test('upsert at the head inserts, move relocates, tail needs end loaded',
        () async {
      final s = Script();
      final m = make(s);
      final f = m.refresh('q');
      s.ok(0, [it('a'), it('b')], next: 2, total: 2);
      await f;
      m.upsertItem('q', it('new'));
      expect(m.peek('q')!.items.map((i) => i.id), ['new', 'a', 'b']);
      expect(m.peek('q')!.totalCount, 3);
      m.upsertItem('q', it('b', 1), move: true);
      expect(m.peek('q')!.items.map((i) => i.id), ['b', 'new', 'a']);
      m.upsertItem('q', it('tail'), at: PagedEnd.tail); // next page exists
      expect(m.peek('q')!.items.map((i) => i.id), ['b', 'new', 'a']);
      final n = m.loadNext('q');
      s.ok(1, items(['z']));
      await n;
      m.upsertItem('q', it('tail'), at: PagedEnd.tail);
      expect(m.peek('q')!.items.last.id, 'tail');
    });

    test('upsert into an unknown query does nothing', () {
      final m = make(Script());
      m.upsertItem('nope', it('a'));
      expect(m.peek('nope'), isNull);
    });
  });

  group('errors', () {
    test('initial error is in the state; retry on re-watch', () async {
      final s = Script();
      final errors = <Object>[];
      final m = make(s, onError: (q, d, e, st) => errors.add(e));
      final f = m.refresh('q');
      s.fail(0, StateError('boom'));
      final st = await f; // never throws
      expect(st.hasInitialError, isTrue);
      expect(st.refreshError!.errorAs<StateError>(), isNotNull);
      expect(st.refreshError!.errorAs<ArgumentError>(), isNull);
      expect(errors, hasLength(1));
      final sub = m.watch('q').listen((_) {});
      await pump();
      expect(s.reqs, hasLength(2)); // retried
      await sub.cancel();
    });

    test('load-more error keeps items; the next loadNext retries', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.fail(1, StateError('x'));
      final st = await f;
      expect(st.items, items(['a']));
      expect(st.next.error, isNotNull);
      expect(st.next.hasMore, isTrue);
      final retry = m.loadNext('q');
      expect(m.peek('q')!.next.error, isNull);
      s.ok(2, items(['b']));
      expect((await retry).items.map((i) => i.id), ['a', 'b']);
    });

    test('load-previous error is reported on the previous edge', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['b']), previous: 1);
      final f = m.loadPrevious('q');
      s.fail(1, StateError('x'));
      expect((await f).previous.error, isNotNull);
    });

    test('refresh error keeps items and is cleared by the next head load',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      s.fail(1, StateError('x'));
      final st = await f;
      expect(st.items, items(['a']));
      expect(st.refreshError, isNotNull);
      expect(st.isRefreshing, isFalse);
      expect(st.hasInitialError, isFalse);
      final again = m.refresh('q');
      expect(m.peek('q')!.refreshError, isNull);
      s.ok(2, items(['b']));
      await again;
    });

    test('a late subscriber gets the state, not a stream error', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      s.fail(1, StateError('x'));
      await f;
      final late = await m.watch('q', fetch: false).first;
      expect(late.refreshError, isNotNull);
      expect(late.items, items(['a']));
    });

    test('a throwing onError cannot break the manager', () async {
      final s = Script();
      final m = make(s, onError: (q, d, e, st) => throw StateError('bad'));
      final f = m.refresh('q');
      s.fail(0, StateError('x'));
      expect((await f).hasInitialError, isTrue);
    });

    test('an expired cursor refreshes the first page instead of failing',
        () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.fail(1, const PageCursorExpiredException());
      await pump();
      expect(s.reqs[2].direction, PageDirection.initial);
      s.ok(2, items(['fresh']));
      final st = await f;
      expect(st.items, items(['fresh']));
      expect(st.next.error, isNull);
    });
  });

  group('watch, freshness and eviction', () {
    test('watch loads once, emits states and does not refetch when fresh',
        () async {
      final s = Script();
      final m = make(s, maxAge: const Duration(hours: 1));
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      expect(states.last.isLoadingInitial, isTrue);
      s.ok(0, items(['a']));
      await pump();
      expect(states.last.items, items(['a']));
      final second = m.watch('q').listen((_) {});
      await pump();
      expect(s.reqs, hasLength(1));
      await second.cancel();
      await sub.cancel();
    });

    test('watch(fetch: false) only observes', () async {
      final s = Script();
      final m = make(s);
      final st = await m.watch('q', fetch: false).first;
      expect(st.hasLoaded, isFalse);
      expect(s.reqs, isEmpty);
    });

    test('a stale (maxAge) query is refetched on watch', () async {
      var now = DateTime(2026);
      final s = Script();
      final m = make(s, maxAge: const Duration(minutes: 1), clock: () => now);
      await seed(m, s, 'q', items(['a']));
      expect(m.peek('q')!.isStale, isFalse);
      now = now.add(const Duration(minutes: 2));
      expect(m.peek('q')!.isStale, isTrue);
      final sub = m.watch('q').listen((_) {});
      await pump();
      expect(s.reqs, hasLength(2));
      await sub.cancel();
    });

    test('maxEntries evicts the least recently watched unwatched query',
        () async {
      final s = Script();
      final m = make(s, maxEntries: 2);
      await seed(m, s, 'a', items(['1']));
      await seed(m, s, 'b', items(['1']));
      // watch a then leave: a becomes the most recently unwatched
      final sub = m.watch('a', fetch: false).listen((_) {});
      await pump();
      await sub.cancel();
      await seed(m, s, 'c', items(['1']));
      expect(m.cachedQueries.toSet(), {'a', 'c'}); // b was the LRU
    });

    test('maxEntries never evicts a watched query', () async {
      final s = Script();
      final m = make(s, maxEntries: 1);
      final sub = m.watch('a', fetch: false).listen((_) {});
      await pump();
      await seed(m, s, 'b', items(['1']));
      await seed(m, s, 'c', items(['1']));
      expect(m.cachedQueries, contains('a'));
      expect(m.cachedQueries.length, 2); // a (watched) + newest unwatched
      await sub.cancel();
    });

    test('evictAfterUnwatched evicts after the duration, cancelled by re-watch',
        () {
      fakeAsync((async) {
        final s = Script();
        final m = make(s, evictAfterUnwatched: const Duration(seconds: 30));
        final f = m.refresh('a');
        s.ok(0, items(['1']));
        async.flushMicrotasks();
        expect(m.cachedQueries, ['a']);
        async.elapse(const Duration(seconds: 29));
        // re-watch cancels the timer
        final sub = m.watch('a', fetch: false).listen((_) {});
        async.elapse(const Duration(minutes: 5));
        expect(m.cachedQueries, ['a']);
        // unwatch restarts it
        sub.cancel();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 29));
        expect(m.cachedQueries, ['a']);
        async.elapse(const Duration(seconds: 2));
        expect(m.cachedQueries, isEmpty);
        f.ignore();
      });
    });

    test('Retention.firstPage trims to the first page on unwatch', () async {
      final s = Script();
      final m = make(s, retention: Retention.firstPage);
      final sub = m.watch('q').listen((_) {});
      await pump();
      s.ok(0, items(['a', 'b']), next: 2);
      await pump();
      final n = m.loadNext('q');
      s.ok(1, items(['c', 'd']), next: 3);
      await n;
      expect(m.peek('q')!.items, hasLength(4));
      await sub.cancel();
      final st = m.peek('q')!;
      expect(st.items.map((i) => i.id), ['a', 'b']);
      expect(st.next.hasMore, isTrue);
      final again = m.loadNext('q');
      expect(s.reqs.last.cursor, 2); // back to page 2
      s.ok(2, items(['c']));
      await again;
    });
  });

  group('loadNext / loadPrevious on an uncached query', () {
    for (final forward in [true, false]) {
      final name = forward ? 'loadNext' : 'loadPrevious';

      test('$name caches the query and loads its first page', () async {
        final s = Script();
        final m = make(s);
        expect(m.peek('q'), isNull);
        final f = forward ? m.loadNext('q') : m.loadPrevious('q');
        expect(m.cachedQueries, ['q']);
        expect(m.peek('q')!.isLoadingInitial, isTrue);
        expect(s.reqs.single.direction, PageDirection.initial);
        expect(s.reqs.single.cursor, isNull);
        s.ok(0, items(['a']), next: 2);
        final st = await f;
        expect(st.items, items(['a']));
        expect(st.hasLoaded, isTrue);
      });

      test('$name on a cached but unloaded query also loads the first page',
          () async {
        final s = Script();
        final m = make(s);
        await m.watch('q', fetch: false).first; // cached, nothing loaded
        final f = forward ? m.loadNext('q') : m.loadPrevious('q');
        expect(s.reqs.single.direction, PageDirection.initial);
        s.ok(0, items(['a']));
        expect((await f).items, items(['a']));
      });
    }
  });

  group('watch: first emission', () {
    bool idleEmpty(PagedState<Item> s) => !s.hasLoaded && !s.isRefreshing;

    test('a new query emits a loading state first (isRefreshing)', () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      expect(states, isNotEmpty);
      expect(states.first.isRefreshing, isTrue);
      expect(states.first.isLoadingInitial, isTrue);
      expect(states.first.hasLoaded, isFalse);
      s.ok(0, items(['a']));
      await pump();
      expect(states.last.items, items(['a']));
      expect(states.last.isRefreshing, isFalse);
      // no idle empty state before the load
      expect(states.where(idleEmpty), isEmpty);
      await sub.cancel();
    });

    test('never emits an idle state immediately followed by a loading one',
        () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.ok(0, items(['a']));
      await pump();
      for (var i = 1; i < states.length; i++) {
        final pair = (states[i - 1], states[i]);
        expect(
          !pair.$1.isRefreshing && pair.$2.isRefreshing,
          isFalse,
          reason: 'idle -> loading at $i: $states',
        );
      }
      expect(states.first, states.firstWhere((x) => x.isRefreshing));
      await sub.cancel();
    });

    test('an unloaded entry created by another call also starts loading',
        () async {
      final s = Script();
      final m = make(s);
      // cached but never loaded
      await m.watch('q', fetch: false).first;
      expect(m.peek('q')!.hasLoaded, isFalse);
      expect(m.peek('q')!.isRefreshing, isFalse);
      final first = await m.watch('q').first;
      expect(first.isLoadingInitial, isTrue);
      expect(s.reqs, hasLength(1));
    });

    test('watch(fetch: false) still emits the idle state first', () async {
      final s = Script();
      final m = make(s);
      final first = await m.watch('q', fetch: false).first;
      expect(first.isRefreshing, isFalse);
      expect(first.hasLoaded, isFalse);
      expect(first.isLoadingInitial, isFalse);
      expect(s.reqs, isEmpty);
    });

    test('a stale watched query emits its items with isRefreshing first',
        () async {
      var now = DateTime(2026);
      final s = Script();
      final m = make(s, maxAge: const Duration(minutes: 1), clock: () => now);
      await seed(m, s, 'q', items(['a']));
      now = now.add(const Duration(minutes: 2));
      final first = await m.watch('q').first;
      expect(first.items, items(['a']));
      expect(first.isRefreshing, isTrue);
    });

    test('after evict a watched query emits an idle reset state', () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.ok(0, items(['a']));
      await pump();
      expect(states.where(idleEmpty), isEmpty);
      m.evict('q');
      await pump();
      final reset = states.last;
      expect(reset.isRefreshing, isFalse); // distinguishable from "loading"
      expect(reset.hasLoaded, isFalse);
      expect(reset.items, isEmpty);
      expect(idleEmpty(reset), isTrue);
      expect(s.reqs, hasLength(1)); // no refetch
      await sub.cancel();
    });

    test('after clearCache a watched query emits an idle reset state',
        () async {
      final s = Script();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      m.clearCache(); // discards the in-flight first load
      await pump();
      expect(states.first.isRefreshing, isTrue);
      expect(idleEmpty(states.last), isTrue);
      await sub.cancel();
    });
  });

  group('more edge cases', () {
    test('whenAborted completes when the request is superseded', () async {
      final s = Script();
      final m = make(s);
      final a = m.refresh('q');
      var fired = false;
      s.reqs[0].signal.whenAborted.then((_) => fired = true);
      final b = m.refresh('q', anchor: 1);
      await pump();
      expect(fired, isTrue);
      s.ok(1, items(['x']));
      await Future.wait([a, b]);
    });

    test('removeItem honours where', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q1', [it('a')]);
      await seed(m, s, 'q2', [it('a')]);
      m.removeItem('a', where: (q) => q == 'q1');
      expect(m.peek('q1')!.items, isEmpty);
      expect(m.peek('q2')!.items, [it('a')]);
    });

    test('previous edge: loop and unproductive pages exhaust it', () async {
      final s = Script();
      final m = make(s);
      await seed(m, s, 'q', items(['b']), previous: 5);
      final loop = m.loadPrevious('q');
      s.ok(1, items(['a']), previous: 5);
      expect((await loop).previous.hasMore, isFalse);

      final s2 = Script();
      final m2 = make(s2, maxUnproductive: 2);
      await seed(m2, s2, 'q', items(['b']), previous: 5);
      final f = m2.loadPrevious('q');
      s2.ok(1, items(['b']), previous: 4);
      await pump();
      s2.ok(2, items(['b']), previous: 3);
      expect((await f).previous.hasMore, isFalse);
    });

    test('Retention.firstPage discards an in-flight next on unwatch', () async {
      final s = Script();
      final m = make(s, retention: Retention.firstPage);
      final sub = m.watch('q').listen((_) {});
      await pump();
      s.ok(0, items(['a']), next: 2);
      await pump();
      final n = m.loadNext('q');
      s.ok(1, items(['b']), next: 3);
      await n;
      final more = m.loadNext('q');
      await sub.cancel();
      s.ok(2, items(['c']));
      await more.timeout(const Duration(seconds: 1));
      expect(m.peek('q')!.items, items(['a']));
    });
  });

  group('dispose', () {
    test('resolves pending futures, closes streams, later calls are no-ops',
        () async {
      final s = Script();
      final m = make(s);
      var done = false;
      m.watch('q').listen((_) {}, onDone: () => done = true);
      await pump();
      final f = m.loadNext('q');
      await m.dispose();
      await f.timeout(const Duration(seconds: 1));
      await pump();
      expect(done, isTrue);
      expect(m.cachedQueries, isEmpty);
      expect((await m.refresh('q')).hasLoaded, isFalse);
      expect((await m.loadNext('q')).hasLoaded, isFalse);
      expect((await m.loadPrevious('q')).hasLoaded, isFalse);
      expect((await m.watch('q').first).hasLoaded, isFalse);
      await m.dispose(); // idempotent
    });
  });

  group('state', () {
    test('isEmpty / isLoadingInitial / hasInitialError', () {
      const empty = PagedState<int>(hasLoaded: true);
      expect(empty.isEmpty, isTrue);
      expect(const PagedState<int>().isEmpty, isFalse);
      expect(
        const PagedState<int>(hasLoaded: true, next: PagedEdge(hasMore: true))
            .isEmpty,
        isFalse,
      );
      expect(
          const PagedState<int>(isRefreshing: true).isLoadingInitial, isTrue);
      expect(
        PagedState<int>(
                refreshError: PagedError(StateError('x'), StackTrace.empty))
            .hasInitialError,
        isTrue,
      );
    });
  });
}
