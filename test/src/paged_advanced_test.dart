import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/testing.dart';

typedef Item = ({String id, int v});

Item it(String id, [int v = 0]) => (id: id, v: v);
List<Item> items(Iterable<String> ids) => [for (final i in ids) it(i)];
List<String> ids(PagedState<Item>? s) => [for (final i in s!.items) i.id];

Future<void> pump() => Future<void>.delayed(Duration.zero);

ReactivePagedManager<String, Item, int> make(
  ScriptedPageFetcher<String, Item, int> s, {
  RefreshMode mode = RefreshMode.firstPage,
  int maxRefreshPages = 10,
  int? maxItems,
  ReactiveStorage<String, PagedSnapshot<Item>>? storage,
  bool Function(String)? persistWhen,
  int storageVersion = 0,
  Duration? maxAge,
  DateTime Function()? clock,
}) =>
    ReactivePagedManager<String, Item, int>(
      fetchPage: s.call,
      idOf: (i) => i.id,
      refreshMode: mode,
      maxRefreshPages: maxRefreshPages,
      maxItems: maxItems,
      storage: storage,
      persistWhen: persistWhen,
      storageVersion: storageVersion,
      maxAge: maxAge,
      clock: clock ?? DateTime.now,
    );

Future<void> seed(
  ReactivePagedManager<String, Item, int> m,
  ScriptedPageFetcher<String, Item, int> s,
  String q,
  List<Item> list, {
  int? next,
  int? previous,
}) async {
  final f = m.refresh(q);
  s.completeLast(list, next: next, previous: previous);
  await f;
}

void main() {
  group('ScriptedPageFetcher', () {
    test('logs requests, completes and fails them by index or last', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      final a = m.refresh('a');
      expect(s.pending, 1);
      expect(s.requests.single.query, 'a');
      s.complete(0, items(['x']), next: 2, previous: 1, totalCount: 9);
      final st = await a;
      expect(st.totalCount, 9);
      expect(s.pending, 0);
      final b = m.refresh('b');
      s.failLast(StateError('x'));
      expect((await b).hasInitialError, isTrue);
      final c = m.refresh('c');
      s.fail(2, StateError('y'), StackTrace.current);
      expect((await c).hasInitialError, isTrue);
    });
  });

  group('RefreshMode.mergeHead', () {
    test('overlap: splices the fresh head in front, keeps the tail cursor',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['c', 'd']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 3);
      await n;
      // two new items arrived at the head; 'c' overlaps
      final f = m.refresh('q', mode: RefreshMode.mergeHead);
      s.completeLast([it('a', 1), it('b', 1), it('c', 1)], next: 99);
      final st = await f;
      expect(ids(st), ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(st.items[2].v, 1); // fresh copy wins for the overlapped item
      expect(st.next.hasMore, isTrue);
      final more = m.loadNext('q');
      expect(s.requests.last.cursor, 3); // tail cursor unchanged
      s.completeLast(items(['g']));
      expect(ids(await more), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
    });

    test('no overlap: behaves like firstPage', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['c', 'd']), next: 2);
      final f = m.refresh('q', mode: RefreshMode.mergeHead);
      s.completeLast(items(['x', 'y']), next: 7);
      expect(ids(await f), ['x', 'y']);
      m.loadNext('q').ignore();
      expect(s.requests.last.cursor, 7);
    });

    test('on an unloaded query it loads the first page', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, mode: RefreshMode.mergeHead);
      final f = m.refresh('q');
      s.completeLast(items(['a']));
      expect(ids(await f), ['a']);
    });

    test('splice replays local edits made in flight onto the fresh part',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', [it('b'), it('c')], next: 2);
      final f = m.refresh('q', mode: RefreshMode.mergeHead);
      m.patchItem('a', (i) => it(i.id, 5));
      s.completeLast([it('a'), it('b')]);
      final st = await f;
      expect(st.items, [it('a', 5), it('b'), it('c')]);
    });

    test('a different mode supersedes a running refresh', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      final a = m.refresh('q');
      final b = m.refresh('q', mode: RefreshMode.allPages);
      expect(s.requests, hasLength(2));
      expect(s.requests[0].signal.aborted, isTrue);
      s.complete(1, items(['z']));
      expect(ids(await a), ['z']);
      expect(ids(await b), ['z']);
    });
  });

  test('PageCursorExpiredException can be created at runtime', () {
    // ignore: prefer_const_constructors
    expect(PageCursorExpiredException(), isA<Exception>());
  });

  group('page accounting', () {
    test('mergeHead overlapping beyond the first page drops whole pages',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 100);
      await seed(m, s, 'q', items(['c', 'd']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 3, previous: 1);
      await n;
      final f = m.refresh('q', mode: RefreshMode.mergeHead);
      s.completeLast(items(['a', 'b', 'c', 'd', 'e']));
      expect(ids(await f), ['a', 'b', 'c', 'd', 'e', 'f']);
    });

    test('a rolled-back removal in a later page is re-inserted there',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 4);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      await n;
      await expectLater(
        m.mutate<void>(() async => throw StateError('x'),
            optimistic: (e) => e.removeItem('d')),
        throwsStateError,
      );
      expect(ids(m.peek('q')), ['a', 'b', 'c', 'd']);
      final n2 = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 4, previous: 2);
      expect(ids(await n2), ['c', 'd', 'e', 'f']); // counts stayed consistent
    });

    test('mutate edits honour where', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q1', [it('a')]);
      await seed(m, s, 'q2', [it('a')]);
      await m.mutate(
        () async {},
        optimistic: (e) {
          e.patchItem('a', (i) => it(i.id, 3), where: (q) => q == 'q1');
          e.removeItem('a', where: (q) => q == 'q2');
        },
      );
      expect(m.peek('q1')!.items, [it('a', 3)]);
      expect(m.peek('q2')!.items, isEmpty);
    });
  });

  group('RefreshMode.allPages', () {
    test('re-fetches as many pages as were loaded along the new cursors',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      var n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3);
      await n;
      n = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 4);
      await n;
      final f = m.refresh('q', mode: RefreshMode.allPages);
      s.completeLast([it('a', 1), it('b', 1)], next: 12);
      await pump();
      expect(s.requests.last.cursor, 12);
      expect(s.requests.last.direction, PageDirection.next);
      expect(m.peek('q')!.items, hasLength(6)); // old window still visible
      s.completeLast([it('c', 1), it('d', 1)], next: 13);
      await pump();
      expect(s.requests.last.cursor, 13);
      s.completeLast([it('e', 1), it('f', 1)], next: 14);
      final st = await f;
      expect(st.items.every((i) => i.v == 1), isTrue);
      expect(ids(st), ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(st.next.hasMore, isTrue);
      m.loadNext('q').ignore();
      expect(s.requests.last.cursor, 14);
    });

    test('a failure on page k keeps the old window (all-or-nothing)', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']), next: 3);
      await n;
      final f = m.refresh('q', mode: RefreshMode.allPages);
      s.completeLast([it('a', 1)], next: 12);
      await pump();
      s.failLast(StateError('x'));
      final st = await f;
      expect(st.items, items(['a', 'b']));
      expect(st.refreshError, isNotNull);
    });

    test('stops early when the server runs out of pages', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']), next: 3);
      await n;
      final f = m.refresh('q', mode: RefreshMode.allPages);
      s.completeLast([it('a')]); // no next any more
      final st = await f;
      expect(ids(st), ['a']);
      expect(st.next.hasMore, isFalse);
    });

    test('is capped by maxRefreshPages', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxRefreshPages: 2);
      await seed(m, s, 'q', items(['a']), next: 2);
      for (var p = 2; p <= 4; p++) {
        final n = m.loadNext('q');
        s.completeLast(items(['p$p']), next: p + 1);
        await n;
      }
      final f = m.refresh('q', mode: RefreshMode.allPages);
      s.completeLast(items(['a']), next: 12);
      await pump();
      s.completeLast(items(['b']), next: 13);
      final st = await f;
      expect(s.requests, hasLength(4 + 2)); // seed + 3 pages, then 2 re-fetched
      expect(ids(st), ['a', 'b']);
    });

    test('an expired cursor while paging keeps the pages fetched so far',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']), next: 3);
      await n;
      final f = m.refresh('q', mode: RefreshMode.allPages);
      s.completeLast([it('a', 1)], next: 12);
      await pump();
      s.failLast(const PageCursorExpiredException());
      expect(ids(await f), ['a']);
    });

    test('the manager-wide default refreshMode is used', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, mode: RefreshMode.mergeHead);
      await seed(m, s, 'q', items(['b', 'c']), next: 2);
      final f = m.refresh('q');
      s.completeLast(items(['a', 'b']));
      expect(ids(await f), ['a', 'b', 'c']);
    });
  });

  group('maxItems windowing', () {
    test('forward loads drop head pages and restore the previous cursor',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 4);
      await seed(m, s, 'q', items(['a', 'b']), next: 2, previous: null);
      var n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      await n;
      expect(ids(m.peek('q')), ['a', 'b', 'c', 'd']);
      n = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 4, previous: 2);
      final st = await n;
      expect(ids(st), ['c', 'd', 'e', 'f']);
      expect(st.previous.hasMore, isTrue);
      final p = m.loadPrevious('q');
      expect(s.requests.last.cursor, 1); // boundary page's previous cursor
      s.completeLast(items(['a', 'b']), previous: null, next: 2);
      expect(ids(await p), ['a', 'b', 'c', 'd']); // trimmed tail
      expect(m.peek('q')!.next.hasMore, isTrue);
      m.loadNext('q').ignore();
      expect(s.requests.last.cursor, 3); // tail cursor restored from boundary
    });

    test('nothing is trimmed when the boundary cursor is unknown', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 2);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['c', 'd'])); // previous == null: unknown
      expect(ids(await n), ['a', 'b', 'c', 'd']);
    });

    test('local removals keep the page accounting right', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 3);
      await seed(m, s, 'q', items(['a', 'b', 'c']), next: 2);
      m.removeItem('a'); // page 1 now owns 2 items
      m.upsertItem('q', it('new')); // and 3 again
      final n = m.loadNext('q');
      s.completeLast(items(['d', 'e']), next: 3, previous: 1);
      expect(ids(await n), ['d', 'e']);
    });

    test('a single page larger than maxItems is kept', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, maxItems: 1);
      await seed(m, s, 'q', items(['a', 'b']));
      expect(ids(m.peek('q')), ['a', 'b']);
    });
  });

  group('mutate', () {
    Future<ReactivePagedManager<String, Item, int>> two(
        ScriptedPageFetcher<String, Item, int> s) async {
      final m = make(s);
      await seed(m, s, 'q1', [it('a'), it('b'), it('c')]);
      await seed(m, s, 'q2', [it('a'), it('x')]);
      return m;
    }

    test('success keeps the optimistic edits and invalidates touched queries',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      final r = await m.mutate(
        () async {
          expect(m.peek('q1')!.items.first.v, 9); // visible during the action
          return 'ok';
        },
        optimistic: (e) => e.patchItem('a', (i) => it(i.id, 9)),
      );
      expect(r, 'ok');
      expect(m.peek('q1')!.items.first.v, 9);
      expect(m.peek('q2')!.items.first.v, 9);
      expect(m.peek('q1')!.isStale, isTrue);
      expect(m.peek('q2')!.isStale, isTrue);
    });

    test('failure rolls back patch, remove and upsert, then rethrows',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await expectLater(
        m.mutate<void>(
          () async => throw StateError('server said no'),
          optimistic: (e) {
            e.patchItem('a', (i) => it(i.id, 9));
            e.removeItem('b', where: (q) => q == 'q1');
            e.upsertItem('q1', it('n'));
            e.upsertItem('q2', it('x', 4));
          },
        ),
        throwsStateError,
      );
      expect(m.peek('q1')!.items, [it('a'), it('b'), it('c')]);
      expect(m.peek('q2')!.items, [it('a'), it('x')]);
      expect(m.peek('q1')!.isStale, isTrue); // invalidated even on failure
    });

    test('a patch is not rolled back over someone else\'s newer change',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await expectLater(
        m.mutate<void>(
          () async {
            m.patchItem('a', (i) => it(i.id, 77)); // someone else
            throw StateError('x');
          },
          optimistic: (e) => e.patchItem('a', (i) => it(i.id, 9)),
        ),
        throwsStateError,
      );
      expect(m.peek('q1')!.items.first.v, 77);
    });

    test('a removed item is re-inserted after its former predecessor',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await expectLater(
        m.mutate<void>(
          () async {
            m.removeItem('a'); // the predecessor vanishes meanwhile
            throw StateError('x');
          },
          optimistic: (e) => e.removeItem('b', where: (q) => q == 'q1'),
        ),
        throwsStateError,
      );
      // predecessor 'a' is gone: falls back to the original index (1)
      expect(ids(m.peek('q1')), ['c', 'b']);
    });

    test('rollback restores totalCount for removed/inserted items', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      final f = m.refresh('q');
      s.completeLast([it('a'), it('b')], totalCount: 2);
      await f;
      await expectLater(
        m.mutate<void>(
          () async => throw StateError('x'),
          optimistic: (e) {
            e.removeItem('a');
            e.upsertItem('q', it('n'));
          },
        ),
        throwsStateError,
      );
      expect(m.peek('q')!.totalCount, 2);
      expect(ids(m.peek('q')), ['a', 'b']);
    });

    test('invalidateAfter runs regardless of outcome', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await m.mutate(() async {}, invalidateAfter: (q) => q == 'q2');
      expect(m.peek('q2')!.isStale, isTrue);
      expect(m.peek('q1')!.isStale, isFalse);
      await expectLater(
        m.mutate<void>(() async => throw StateError('x'),
            invalidateAfter: (q) => q == 'q1'),
        throwsStateError,
      );
      expect(m.peek('q1')!.isStale, isTrue);
    });

    test('a throwing optimistic callback is undone and rethrown', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await expectLater(
        m.mutate<void>(
          () async {},
          optimistic: (e) {
            e.patchItem('a', (i) => it(i.id, 9));
            throw StateError('bad');
          },
        ),
        throwsStateError,
      );
      expect(m.peek('q1')!.items.first.v, 0);
    });

    test('edits on a query that is not cached are ignored', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = await two(s);
      await m.mutate(
        () async {},
        optimistic: (e) {
          e.upsertItem('nope', it('z'));
          e.patchItem('missing', (i) => i);
          e.removeItem('missing');
        },
      );
      expect(m.peek('nope'), isNull);
    });

    test('items without identity are not undone but do not break', () async {
      final m = ReactivePagedManager<String, int, int>(
        fetchPage: (r) async => const PageResult([1, 2]),
        idOf: (_) => null,
      );
      await m.refresh('q');
      await expectLater(
        m.mutate<void>(
          () async => throw StateError('x'),
          optimistic: (e) => e.upsertItem('q', 3),
        ),
        throwsStateError,
      );
      expect(m.peek('q')!.items, [3, 1, 2]);
    });

    test('mutate during a load: the response is rebased onto the edit',
        () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      final done = m.mutate(
        () async {},
        optimistic: (e) => e.patchItem('b', (i) => it(i.id, 5)),
      );
      s.completeLast(items(['b']));
      await Future.wait([n, done]);
      expect(m.peek('q')!.items.last, it('b', 5));
    });
  });

  group('persistence', () {
    late InMemoryReactiveStorage<String, PagedSnapshot<Item>> storage;
    late DateTime now;

    setUp(() {
      storage = InMemoryReactiveStorage();
      now = DateTime(2026);
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('writes only the first page after a head load', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: storage, clock: () => now);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['c']));
      await n;
      await settle();
      final stored = storage.entries['q']!;
      expect(stored.value.items, items(['a', 'b']));
      expect(stored.fetchedAt, now);
      expect(stored.version, 0);
    });

    test(
        'hydrates: emits the stored items first with the original fetchedAt, '
        'then revalidates', () async {
      storage.entries['q'] = StoredEntry(
        PagedSnapshot(items(['old']), totalCount: 7),
        DateTime(2025),
      );
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: storage, clock: () => now);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      await pump();
      final restored = states.firstWhere((st) => st.hasLoaded);
      expect(ids(restored), ['old']);
      expect(restored.fetchedAt, DateTime(2025));
      expect(restored.totalCount, 7);
      expect(restored.isStale, isTrue);
      expect(s.requests, hasLength(1)); // revalidating
      s.completeLast(items(['new']));
      await pump();
      expect(ids(states.last), ['new']);
      expect(states.last.isStale, isFalse);
      await sub.cancel();
    });

    test('loadNext on a restored entry refreshes the first page first',
        () async {
      storage.entries['q'] = StoredEntry(
        PagedSnapshot(items(['old'])),
        DateTime(2025),
      );
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: storage);
      final f = m.loadNext('q');
      await pump();
      expect(s.requests.single.direction, PageDirection.initial);
      s.completeLast(items(['n1']), next: 2);
      expect(ids(await f), ['n1']);
    });

    test('a faster network result wins over a slower hydration', () async {
      final slow = Completer<void>();
      final inner = InMemoryReactiveStorage<String, PagedSnapshot<Item>>()
        ..entries['q'] =
            StoredEntry(PagedSnapshot(items(['old'])), DateTime(2025));
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: _Slow(inner, slow.future));
      final f = m.refresh('q');
      s.completeLast(items(['fresh']));
      await f;
      slow.complete();
      await pump();
      expect(ids(m.peek('q')), ['fresh']);
      expect(m.peek('q')!.isStale, isFalse);
    });

    test('persistWhen decides which queries are stored', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s,
          storage: storage, persistWhen: (q) => q == 'keep', clock: () => now);
      await seed(m, s, 'keep', items(['a']));
      await seed(m, s, 'skip', items(['b']));
      await settle();
      expect(storage.entries.keys, ['keep']);
    });

    test('evict and clearCache delete persisted entries', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: storage);
      await seed(m, s, 'a', items(['1']));
      await seed(m, s, 'b', items(['2']));
      await settle();
      expect(storage.entries.keys, containsAll(['a', 'b']));
      m.evict('a');
      await settle();
      expect(storage.entries.keys, ['b']);
      m.clearCache();
      await settle();
      expect(storage.entries, isEmpty);
    });

    test('memory eviction keeps the persisted entry and re-hydrates', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        storage: storage,
        maxEntries: 1,
      );
      await seed(m, s, 'a', items(['1']));
      await seed(m, s, 'b', items(['2']));
      await settle();
      expect(m.cachedQueries, ['b']); // a left memory
      expect(storage.entries.keys, containsAll(['a', 'b']));
      final sub = m.watch('a', fetch: false).listen((_) {});
      await settle();
      expect(ids(m.peek('a')), ['1']);
      await sub.cancel();
    });

    test('storage errors never fail a load', () async {
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: _Throwing());
      final f = m.refresh('q');
      s.completeLast(items(['a']));
      expect(ids(await f), ['a']);
      m.evict('q');
      m.clearCache();
      await settle();
    });

    test('a version mismatch ignores and deletes the stored entry', () async {
      storage.entries['q'] = StoredEntry(
          PagedSnapshot(items(['old'])), DateTime(2025),
          version: 1);
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: storage, storageVersion: 2);
      final f = m.refresh('q');
      await pump();
      s.completeLast(items(['new']));
      await f;
      await settle();
      expect(ids(m.peek('q')), ['new']);
      expect(storage.entries['q']!.version, 2); // replaced by the new write
    });

    // B1: no pump between evict/clearCache and the next watch/refresh.
    for (final action
        in <String, void Function(ReactivePagedManager<String, Item, int>)>{
      'clearCache': (m) => m.clearCache(),
      'evict': (m) => m.evict('inbox'),
    }.entries) {
      test('${action.key} then watch right away never emits the old page',
          () async {
        final s = ScriptedPageFetcher<String, Item, int>();
        final m = make(s, storage: storage);
        await seed(m, s, 'inbox', items(['alice-secret']));
        await settle();
        expect(storage.entries, isNotEmpty);
        action.value(m);
        final states = <PagedState<Item>>[];
        final sub = m.watch('inbox').listen(states.add);
        await settle();
        expect(
          states.expand((st) => st.items).map((i) => i.id),
          isNot(contains('alice-secret')),
        );
        s.completeLast(items(['bob']));
        await settle();
        expect(ids(states.last), ['bob']);
        expect(states.any((st) => st.hasLoaded && st.items.isEmpty), isFalse);
        await sub.cancel();
      });

      test('${action.key} then loadNext right away fetches, not hydrates',
          () async {
        final s = ScriptedPageFetcher<String, Item, int>();
        final m = make(s, storage: storage);
        await seed(m, s, 'inbox', items(['alice-secret']), next: 2);
        await settle();
        action.value(m);
        final f = m.loadNext('inbox');
        await settle();
        expect(m.peek('inbox')!.items, isEmpty);
        s.completeLast(items(['bob']));
        expect(ids(await f), ['bob']);
      });
    }

    test('evict during hydration drops the stored snapshot', () async {
      final slow = Completer<void>();
      final inner = InMemoryReactiveStorage<String, PagedSnapshot<Item>>()
        ..entries['q'] =
            StoredEntry(PagedSnapshot(items(['old'])), DateTime(2025));
      final s = ScriptedPageFetcher<String, Item, int>();
      final m = make(s, storage: _Slow(inner, slow.future));
      final sub = m.watch('q', fetch: false).listen((_) {});
      await pump();
      m.evict('q');
      slow.complete();
      await pump();
      expect(m.peek('q')!.hasLoaded, isFalse);
      await sub.cancel();
    });
  });

  group('base manager: invalidateWhere / patchWhere', () {
    test('invalidateWhere marks only matching cached keys', () async {
      final m = ReactiveDataManager<String, int>(fetcher: (_) async => 1);
      await m.getData('a1');
      await m.getData('a2');
      await m.getData('b1');
      m.invalidateWhere((k) => k.startsWith('a'));
      expect(m.isFresh('a1'), isFalse);
      expect(m.isFresh('a2'), isFalse);
      expect(m.isFresh('b1'), isTrue);
    });

    test('patchWhere replaces values across keys and discards fetches',
        () async {
      final c = Completer<int>();
      var calls = 0;
      final m = ReactiveDataManager<String, int>(
        fetcher: (_) => ++calls <= 2 ? Future.value(1) : c.future,
      );
      await m.getData('a');
      await m.getData('b');
      final refresh = m.getData('a', forceRefresh: true);
      m.invalidate('b');
      m.patchWhere((k, v) => k == 'a' ? v + 10 : null);
      c.complete(500);
      await refresh;
      expect(m.getCurrentValue('a'), 11);
      expect(m.getCurrentValue('b'), 1);
      expect(m.isFresh('b'), isFalse); // untouched, still invalidated
      m.invalidate('a');
      m.patchWhere((k, v) => v + 1);
      expect(m.isFresh('a'), isFalse); // patch keeps the invalidated state
      expect(m.getCurrentValue('b'), 2);
    });
  });
}

class _Slow implements ReactiveStorage<String, PagedSnapshot<Item>> {
  _Slow(this.inner, this.gate);
  final InMemoryReactiveStorage<String, PagedSnapshot<Item>> inner;
  final Future<void> gate;
  @override
  Future<StoredEntry<PagedSnapshot<Item>>?> read(String key) async {
    await gate;
    return inner.read(key);
  }

  @override
  Future<void> write(String key, StoredEntry<PagedSnapshot<Item>> entry) =>
      inner.write(key, entry);
  @override
  Future<void> delete(String key) => inner.delete(key);
  @override
  Future<void> clear() => inner.clear();
}

class _Throwing implements ReactiveStorage<String, PagedSnapshot<Item>> {
  @override
  Future<StoredEntry<PagedSnapshot<Item>>?> read(String key) =>
      throw StateError('corrupt');
  @override
  Future<void> write(String key, StoredEntry<PagedSnapshot<Item>> entry) =>
      throw StateError('w');
  @override
  Future<void> delete(String key) => throw StateError('d');
  @override
  Future<void> clear() => throw StateError('c');
}
