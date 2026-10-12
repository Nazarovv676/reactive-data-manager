import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/testing.dart';

typedef Item = ({String id, int v});

Item it(String id, [int v = 0]) => (id: id, v: v);
List<Item> items(Iterable<String> ids) => [for (final i in ids) it(i)];
List<String> ids(PagedState<Item>? s) => [for (final i in s!.items) i.id];

Future<void> pump() => Future<void>.delayed(Duration.zero);
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

typedef Scripted = ScriptedPageFetcher<String, Item, int>;
typedef Manager = ReactivePagedManager<String, Item, int>;

Manager make(
  Scripted s, {
  Object? Function(Item)? idOf,
  RefreshMode mode = RefreshMode.firstPage,
  ReactiveStorage<String, PagedSnapshot<Item>>? storage,
  bool Function(String)? persistWhen,
  void Function(String, PageDirection, Object, StackTrace)? onError,
}) =>
    ReactivePagedManager<String, Item, int>(
      fetchPage: s.call,
      idOf: idOf ?? ((i) => i.id),
      refreshMode: mode,
      storage: storage,
      persistWhen: persistWhen,
      onError: onError,
    );

Future<void> seed(
  Manager m,
  Scripted s,
  String q,
  List<Item> list, {
  int? next,
  int? previous,
}) async {
  final f = m.refresh(q);
  s.completeLast(list, next: next, previous: previous);
  await f;
}

extension on Future<PagedState<Item>> {
  Future<PagedState<Item>> get bounded => timeout(const Duration(seconds: 1));
}

void main() {
  group('M1: throwing user callbacks never hang a future or wedge a lane', () {
    test('idOf throwing while merging a next page', () async {
      final s = Scripted();
      final reported = <Object>[];
      final m = make(
        s,
        idOf: (i) => i.id == 'bad' ? throw StateError('idOf bug') : i.id,
        onError: (_, __, e, ___) => reported.add(e),
      );
      await seed(m, s, 'q', items(['a']), next: 2);
      final first = m.loadNext('q');
      final joined = m.loadNext('q');
      s.completeLast(items(['bad']), next: 3);
      final st = await first.bounded;
      expect(await joined.bounded, same(st));
      expect(st.next.isLoading, isFalse);
      expect(st.next.error!.error, isA<StateError>());
      expect(reported.single, isA<StateError>());
      expect(ids(st), ['a']);
      // The lane is reusable.
      final again = m.loadNext('q');
      expect(s.requests, hasLength(3));
      s.completeLast(items(['b']));
      expect(ids(await again.bounded), ['a', 'b']);
    });

    test('idOf throwing while merging a previous page', () async {
      final s = Scripted();
      final m = make(
        s,
        idOf: (i) => i.id == 'bad' ? throw StateError('idOf bug') : i.id,
      );
      await seed(m, s, 'q', items(['a']), previous: 0);
      final f = m.loadPrevious('q');
      s.completeLast(items(['bad']), previous: -1);
      final st = await f.bounded;
      expect(st.previous.error, isNotNull);
      expect(st.previous.isLoading, isFalse);
      final again = m.loadPrevious('q');
      s.completeLast(items(['z']));
      expect(ids(await again.bounded), ['z', 'a']);
    });

    test('idOf throwing while applying a head load', () async {
      final s = Scripted();
      var bad = true;
      final m = make(
        s,
        idOf: (i) => bad && i.id == 'bad' ? throw StateError('x') : i.id,
      );
      final first = m.refresh('q');
      final joined = m.loadNext('q');
      s.completeLast(items(['bad']));
      final st = await first.bounded;
      expect(await joined.bounded, same(st));
      expect(st.hasInitialError, isTrue);
      expect(st.isRefreshing, isFalse);
      bad = false;
      final again = m.refresh('q');
      s.completeLast(items(['bad', 'ok']));
      expect(ids(await again.bounded), ['bad', 'ok']);
    });

    for (final mode in RefreshMode.values) {
      test('a replayed patch transform throwing on a head load ($mode)',
          () async {
        final s = Scripted();
        final m = make(s, mode: mode);
        await seed(m, s, 'q', items(['a', 'b']), next: 2);
        final f = m.refresh('q');
        var calls = 0;
        m.patchItem('a', (i) {
          if (++calls > 1) throw StateError('replay bug');
          return it(i.id, 1);
        });
        s.completeLast(items(['a', 'b']), next: 2);
        final st = await f.bounded;
        expect(st.refreshError!.error, isA<StateError>());
        expect(st.isRefreshing, isFalse);
        expect(st.items, [it('a', 1), it('b')]); // previous items stay
        final again = m.refresh('q');
        s.completeLast(items(['c']));
        expect(ids(await again.bounded), ['c']);
      });
    }

    test('a replayed patch transform throwing on a next page', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      m.patchItem('b', (_) => throw StateError('replay bug')); // absent here
      s.completeLast(items(['b']), next: 3);
      final st = await f.bounded;
      expect(st.next.error!.error, isA<StateError>());
      expect(st.next.isLoading, isFalse);
      final again = m.loadNext('q');
      s.completeLast(items(['c']));
      expect(ids(await again.bounded), ['a', 'c']);
    });

    test('persistWhen throwing: the load succeeds, the error is reported',
        () async {
      final s = Scripted();
      final storage = InMemoryReactiveStorage<String, PagedSnapshot<Item>>();
      final reported = <Object>[];
      final m = make(
        s,
        storage: storage,
        persistWhen: (_) => throw StateError('persistWhen bug'),
        onError: (_, __, e, ___) => reported.add(e),
      );
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.completeLast(items(['a']), next: 2);
      await settle();
      expect(ids(states.last), ['a']);
      expect(states.last.refreshError, isNull);
      expect(storage.entries, isEmpty);
      expect(reported, isNotEmpty);
      expect(reported, everyElement(isA<StateError>()));
      final n = m.loadNext('q');
      s.completeLast(items(['b']));
      expect(ids(await n.bounded), ['a', 'b']);
      await sub.cancel();
    });

    test('a storage adapter throwing synchronously never wedges a lane',
        () async {
      final s = Scripted();
      final m = make(s, storage: _SyncThrowing());
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.completeLast(items(['a']), next: 2);
      await settle();
      final n = m.loadNext('q');
      s.completeLast(items(['b']));
      expect(ids(await n.bounded), ['a', 'b']);
      m.evict('q');
      final r = m.refresh('q');
      s.completeLast(items(['c']));
      expect(ids(await r.bounded), ['c']);
      m.clearCache();
      await settle();
      await sub.cancel();
    });
  });

  group('M2: an expired cursor always refreshes the first page', () {
    for (final mode in [RefreshMode.mergeHead, RefreshMode.allPages]) {
      test('with refreshMode: $mode', () async {
        final s = Scripted();
        final m = make(s, mode: mode);
        await seed(m, s, 'q', items(['a', 'b']), next: 2);
        final n1 = m.loadNext('q');
        s.completeLast(items(['c', 'd']), next: 3);
        await n1;
        final f = m.loadNext('q');
        s.failLast(const PageCursorExpiredException());
        await pump();
        expect(s.requests.last.direction, PageDirection.initial);
        expect(s.requests.last.cursor, isNull);
        s.completeLast(items(['a', 'b']), next: 2);
        final st = await f.bounded;
        expect(s.requests, hasLength(4)); // no follow-up page requests
        expect(s.pending, 0);
        expect(ids(st), ['a', 'b']);
        expect(st.next.hasMore, isTrue);
        // The new cursor is the fresh one, not the expired tail cursor.
        final n2 = m.loadNext('q');
        expect(s.requests.last.cursor, 2);
        s.completeLast(items(['c']));
        expect(ids(await n2.bounded), ['a', 'b', 'c']);
        expect(m.peek('q')!.next.hasMore, isFalse);
      });
    }

    test('an explicit refresh still uses the default mode', () async {
      final s = Scripted();
      final m = make(s, mode: RefreshMode.allPages);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']), next: 3);
      await n;
      final r = m.refresh('q');
      s.completeLast(items(['a']), next: 2);
      await pump();
      expect(s.requests.last.direction, PageDirection.next);
      s.completeLast(items(['b']));
      expect(ids(await r.bounded), ['a', 'b']);
    });
  });

  group('M3: the offset = loadedCount recipe', () {
    test('moves past an all-duplicate page within one loadNext', () async {
      // Server list; three items get inserted at the head after page 1.
      var server = [for (var i = 0; i < 20; i++) 'i$i'];
      const limit = 3;
      final requests = <(int?, int)>[];
      final m = ReactivePagedManager<String, Item, int>(
        idOf: (i) => i.id,
        fetchPage: (req) async {
          final offset =
              req.direction == PageDirection.initial ? 0 : req.loadedCount;
          requests.add((req.cursor, offset));
          final page = server.skip(offset).take(limit).toList();
          return PageResult(
            items(page),
            next: page.length < limit ? null : offset + page.length,
          );
        },
      );
      expect(ids(await m.refresh('q')), ['i0', 'i1', 'i2']);
      server = ['n0', 'n1', 'n2', ...server];
      final st = await m.loadNext('q');
      expect(requests, [(null, 0), (3, 3), (6, 6)]);
      expect(ids(st), ['i0', 'i1', 'i2', 'i3', 'i4', 'i5']);
      expect(st.next.hasMore, isTrue);
    });

    test('later calls keep moving although the held count lags', () async {
      var server = [for (var i = 0; i < 12; i++) 'i$i'];
      const limit = 3;
      final requests = <(int?, int)>[];
      final m = ReactivePagedManager<String, Item, int>(
        idOf: (i) => i.id,
        fetchPage: (req) async {
          final offset =
              req.direction == PageDirection.initial ? 0 : req.loadedCount;
          requests.add((req.cursor, offset));
          final page = server.skip(offset).take(limit).toList();
          return PageResult(
            items(page),
            next: page.length < limit ? null : offset + page.length,
          );
        },
      );
      await m.refresh('q');
      server = ['n0', 'n1', 'n2', ...server];
      await m.loadNext('q');
      // Held: i0..i5 (server 3..8). offset 6 returns duplicates whose next
      // cursor (9) equals the requested one; the call continues at offset 9.
      final st = await m.loadNext('q');
      expect(requests.skip(3), [(9, 6), (9, 9)]);
      expect(ids(st).skip(6), ['i6', 'i7', 'i8']);
      expect(st.next.hasMore, isTrue);
    });

    test('an empty page with the same cursor exhausts the edge immediately',
        () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.completeLast([], next: 2);
      final st = await f.bounded;
      expect(s.requests, hasLength(2));
      expect(st.next.hasMore, isFalse);
    });

    test(
        'duplicates with a cursor that does not move stop after '
        'maxUnproductivePages', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      for (var i = 0; i < 3; i++) {
        await pump();
        expect(s.requests.last.cursor, 2);
        expect(s.requests.last.loadedCount, 1 + i);
        s.completeLast(items(['a']), next: 2);
      }
      final st = await f.bounded;
      expect(s.requests, hasLength(4));
      expect(st.next.hasMore, isFalse);
    });
  });

  group('m3: configuration edge values', () {
    ReactivePagedManager<String, Item, int> build({
      int? maxEntries,
      int maxRefreshPages = 10,
      int? maxItems,
      int maxUnproductivePages = 3,
    }) =>
        ReactivePagedManager<String, Item, int>(
          fetchPage: Scripted().call,
          idOf: (i) => i.id,
          maxEntries: maxEntries,
          maxRefreshPages: maxRefreshPages,
          maxItems: maxItems,
          maxUnproductivePages: maxUnproductivePages,
        );

    test('values below 1 are rejected', () {
      for (final v in [0, -1]) {
        expect(() => build(maxEntries: v), throwsArgumentError);
        expect(() => build(maxRefreshPages: v), throwsArgumentError);
        expect(() => build(maxItems: v), throwsArgumentError);
        expect(() => build(maxUnproductivePages: v), throwsArgumentError);
      }
      expect(
        () => build(maxEntries: 0),
        throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'maxEntries')),
      );
      build(
        maxEntries: 1,
        maxRefreshPages: 1,
        maxItems: 1,
        maxUnproductivePages: 1,
      );
    });

    test('maxEntries: 1 keeps the query a call is working on', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        maxEntries: 1,
      );
      final a = m.refresh('a');
      s.completeLast(items(['1']));
      expect(ids(await a.bounded), ['1']);
      final b = m.refresh('b');
      expect(m.cachedQueries, ['b']);
      s.completeLast(items(['2']));
      expect(ids(await b.bounded), ['2']);
      final states = <PagedState<Item>>[];
      var done = false;
      final sub = m
          .watch('c', fetch: false)
          .listen(states.add, onDone: () => done = true);
      await pump();
      expect(done, isFalse);
      expect(m.cachedQueries, ['c']); // b was the least recently used
      expect(states.single.hasLoaded, isFalse);
      await sub.cancel();
      expect(m.cachedQueries, ['c']);
    });

    test('maxUnproductivePages: 1 stops after the first unproductive page',
        () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        maxUnproductivePages: 1,
      );
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.completeLast(items(['a']), next: 3);
      final st = await f.bounded;
      expect(s.requests, hasLength(2));
      expect(st.next.hasMore, isFalse);
    });

    test('maxRefreshPages: 1 makes allPages a first-page refresh', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        refreshMode: RefreshMode.allPages,
        maxRefreshPages: 1,
      );
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']), next: 3);
      await n;
      final r = m.refresh('q');
      s.completeLast(items(['a']), next: 2);
      final st = await r.bounded;
      expect(s.requests, hasLength(3));
      expect(ids(st), ['a']);
      expect(st.next.hasMore, isTrue);
    });

    test('maxItems: 1 keeps at least one page', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        maxItems: 1,
      );
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), previous: 1, next: 3);
      final st = await n.bounded;
      expect(ids(st), ['c', 'd']);
      expect(st.previous.hasMore, isTrue);
    });
  });

  group('m4: page accounting survives mergeHead and replayed edits', () {
    test('mergeHead with a bumped item, then Retention.firstPage', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        retainWhenUnwatched: Retention.firstPage,
      );
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.completeLast(items(['a', 'b']), next: 2);
      await pump();
      final n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3);
      await n;
      final r = m.refresh('q', mode: RefreshMode.mergeHead);
      s.completeLast(items(['d', 'a', 'b']), next: 7); // d bumped to the top
      expect(ids(await r.bounded), ['d', 'a', 'b', 'c']);
      expect(m.peek('q')!.next.hasMore, isTrue);
      await sub.cancel();
      final trimmed = m.peek('q')!;
      expect(ids(trimmed), ['d', 'a', 'b']); // only the fresh first page
      expect(trimmed.next.hasMore, isTrue);
      final more = m.loadNext('q');
      expect(s.requests.last.cursor, 7); // continues after the fresh page
      s.completeLast(items(['c', 'e']));
      expect(ids(await more.bounded), ['d', 'a', 'b', 'c', 'e']);
    });

    test('mergeHead keeps the page boundaries of the spliced tail', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        maxItems: 4,
      );
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      var n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      await n;
      final r = m.refresh('q', mode: RefreshMode.mergeHead);
      s.completeLast(items(['x', 'a', 'b']), next: 2);
      expect(ids(await r.bounded), ['x', 'a', 'b', 'c', 'd']);
      // Over maxItems on the next load: whole pages drop from the head side
      // only when their boundary cursor is known (it is not after a splice).
      n = m.loadNext('q');
      s.completeLast(items(['e']), next: 4, previous: 3);
      final st = await n.bounded;
      expect(ids(st), ['x', 'a', 'b', 'c', 'd', 'e']);
      expect(st.previous.hasMore, isFalse);
    });

    test('maxItems after an allPages refresh with replayed edits', () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        refreshMode: RefreshMode.allPages,
        maxItems: 4,
      );
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      var n = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      await n;
      final r = m.refresh('q');
      m.removeItem('a'); // replayed onto the refreshed pages
      s.completeLast(items(['a', 'b']), next: 2);
      await pump();
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      expect(ids(await r.bounded), ['b', 'c', 'd']);
      n = m.loadNext('q');
      s.completeLast(items(['e', 'f']), next: 4, previous: 2);
      final st = await n.bounded;
      // Exactly the first page (now just 'b') was dropped.
      expect(ids(st), ['c', 'd', 'e', 'f']);
      expect(st.previous.hasMore, isTrue);
      final p = m.loadPrevious('q');
      expect(s.requests.last.cursor, 1);
      s.completeLast(items(['b']));
      expect(ids(await p.bounded).first, 'b');
    });

    test('Retention.firstPage after a refresh with a replayed upsert',
        () async {
      final s = Scripted();
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: s.call,
        idOf: (i) => i.id,
        refreshMode: RefreshMode.allPages,
        retainWhenUnwatched: Retention.firstPage,
      );
      final sub = m.watch('q').listen((_) {});
      await pump();
      s.completeLast(items(['a', 'b']), next: 2);
      await pump();
      final n = m.loadNext('q');
      s.completeLast(items(['c', 'd']));
      await n;
      final r = m.refresh('q');
      m.upsertItem('q', it('z')); // at the head, replayed
      s.completeLast(items(['a', 'b']), next: 2);
      await pump();
      s.completeLast(items(['c', 'd']));
      expect(ids(await r.bounded), ['z', 'a', 'b', 'c', 'd']);
      await sub.cancel();
      expect(ids(m.peek('q')), ['z', 'a', 'b']);
      expect(m.peek('q')!.next.hasMore, isTrue);
    });
  });

  group('m5: upsertItem gate', () {
    test('ignored on a never-loaded entry (e.g. after an initial error)',
        () async {
      final s = Scripted();
      final m = make(s);
      final f = m.refresh('q');
      m.upsertItem('q', it('x')); // first load in flight
      m.upsertItem('q', it('y'), at: PagedEnd.tail);
      s.failLast(StateError('down'));
      final st = await f.bounded;
      expect(st.hasInitialError, isTrue);
      m.upsertItem('q', it('x'));
      m.upsertItem('q', it('y'), at: PagedEnd.tail);
      expect(m.peek('q')!.items, isEmpty);
      expect(m.peek('q')!.hasLoaded, isFalse);
      final r = m.refresh('q');
      s.completeLast(items(['a']));
      expect(ids(await r.bounded), ['a']);
    });

    test('ignored on a hydrated entry; applied after revalidation', () async {
      final storage = InMemoryReactiveStorage<String, PagedSnapshot<Item>>()
        ..entries['q'] = StoredEntry(
          PagedSnapshot(items(['a', 'b'])),
          DateTime(2025),
        );
      final s = Scripted();
      final m = make(s, storage: storage);
      final sub = m.watch('q').listen((_) {});
      await settle();
      expect(ids(m.peek('q')), ['a', 'b']); // restored, revalidating
      m.upsertItem('q', it('z'), at: PagedEnd.tail);
      m.upsertItem('q', it('h'));
      expect(ids(m.peek('q')), ['a', 'b']);
      m.upsertItem('q', it('a', 5)); // present: replaced in place
      expect(m.peek('q')!.items.first, it('a', 5));
      s.completeLast(items(['a', 'b', 'c', 'd']), next: 2);
      await settle();
      expect(ids(m.peek('q')), ['a', 'b', 'c', 'd']);
      m.upsertItem('q', it('h'));
      expect(ids(m.peek('q')), ['h', 'a', 'b', 'c', 'd']);
      await sub.cancel();
    });

    test('a replayed tail insert is dropped when the new response has more',
        () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b']));
      final f = m.refresh('q');
      m.upsertItem('q', it('z'), at: PagedEnd.tail); // tail loaded right now
      expect(ids(m.peek('q')), ['a', 'b', 'z']);
      s.completeLast(items(['a', 'b', 'c', 'd']), next: 2);
      final st = await f.bounded;
      expect(ids(st), ['a', 'b', 'c', 'd']); // z is in an unloaded region
      expect(st.next.hasMore, isTrue);
    });

    test('a replayed head insert is dropped when a previous page appeared',
        () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      m.upsertItem('q', it('h'));
      s.completeLast(items(['a']), previous: 0);
      expect(ids(await f.bounded), ['a']);
    });

    test('a replayed tail insert is kept when the tail is still loaded',
        () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']));
      final f = m.refresh('q');
      m.upsertItem('q', it('z'), at: PagedEnd.tail);
      m.upsertItem('q', it('a', 1)); // present everywhere
      s.completeLast(items(['a', 'b']));
      expect((await f.bounded).items, [it('a', 1), it('b'), it('z')]);
    });

    test('mergeHead: a tail insert stays in the kept tail', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a', 'b', 'c']));
      final f = m.refresh('q', mode: RefreshMode.mergeHead);
      m.upsertItem('q', it('z'), at: PagedEnd.tail);
      m.upsertItem('q', it('h'));
      s.completeLast(items(['x', 'a', 'b']));
      expect(ids(await f.bounded), ['h', 'x', 'a', 'b', 'c', 'z']);
    });
  });

  group('nits: value equality and dispose', () {
    test('PagedState, PagedEdge and PagedError have value equality', () {
      final st = StackTrace.current;
      final e1 = PagedError('x', st);
      expect(e1, PagedError('x', st));
      expect(e1.hashCode, PagedError('x', st).hashCode);
      expect(e1, isNot(PagedError('y', st)));
      const edge = PagedEdge(hasMore: true);
      expect(edge, const PagedEdge(hasMore: true));
      expect(edge.hashCode, const PagedEdge(hasMore: true).hashCode);
      expect(edge, isNot(const PagedEdge(hasMore: true, isLoading: true)));
      expect(PagedEdge(error: e1), PagedEdge(error: PagedError('x', st)));
      final at = DateTime(2026);
      PagedState<Item> state(List<Item> list, {bool stale = false}) =>
          PagedState<Item>(
            items: List.unmodifiable(list),
            hasLoaded: true,
            refreshError: e1,
            next: edge,
            totalCount: 3,
            fetchedAt: at,
            isStale: stale,
          );
      final a = state(items(['a', 'b']));
      expect(a, state(items(['a', 'b'])));
      expect(a.hashCode, state(items(['a', 'b'])).hashCode);
      expect(a, isNot(state(items(['a', 'c']))));
      expect(a, isNot(state(items(['a']))));
      expect(a, isNot(state(items(['a', 'b']), stale: true)));
      expect(a, isNot(const PagedState<Item>()));
      expect(const PagedState<Item>(), const PagedState<Item>());
      expect(a == a, isTrue);
    });

    test('the manager never emits a state equal to the previous one', () async {
      final s = Scripted();
      final m = make(s);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q').listen(states.add);
      await pump();
      s.completeLast(items(['a', 'b']), next: 2);
      await pump();
      final count = states.length;
      m.upsertItem('q', it('a')); // replaced by an equal item
      m.patchItem('a', (i) => i); // identity transform
      m.upsertItem('q', it('a'));
      await pump();
      expect(states, hasLength(count));
      m.patchItem('a', (i) => it('a', 1));
      await pump();
      expect(states, hasLength(count + 1));
      for (var i = 1; i < states.length; i++) {
        expect(states[i], isNot(states[i - 1]));
      }
      await sub.cancel();
    });

    test('after dispose evict/clearCache/loads never touch storage', () async {
      final storage = InMemoryReactiveStorage<String, PagedSnapshot<Item>>();
      final s = Scripted();
      final m = make(s, storage: storage);
      await seed(m, s, 'q', items(['a']));
      await settle();
      expect(storage.entries.keys, ['q']);
      await m.dispose();
      m.evict('q');
      m.clearCache();
      await settle();
      expect(storage.entries.keys, ['q']);
      expect(await m.refresh('q'), const PagedState<Item>());
      expect(s.requests, hasLength(1));
    });
  });

  group('edge lanes in flight at evict / clearCache / invalidate', () {
    for (final watched in [false, true]) {
      for (final action in <String, void Function(Manager)>{
        'evict': (m) => m.evict('q'),
        'clearCache': (m) => m.clearCache(),
        'invalidate': (m) => m.invalidate('q'),
      }.entries) {
        final name = action.key;
        test('$name, ${watched ? 'watched' : 'unwatched'}', () async {
          final s = Scripted();
          final m = make(s);
          final states = <PagedState<Item>>[];
          var done = false;
          StreamSubscription<PagedState<Item>>? sub;
          if (watched) {
            sub = m.watch('q').listen(states.add, onDone: () => done = true);
            await pump();
            s.completeLast(items(['a']), next: 2, previous: 0);
            await pump();
          } else {
            await seed(m, s, 'q', items(['a']), next: 2, previous: 0);
          }
          final n = m.loadNext('q');
          final p = m.loadPrevious('q');
          expect(s.requests, hasLength(3));
          expect(m.peek('q')!.next.isLoading, isTrue);
          expect(m.peek('q')!.previous.isLoading, isTrue);

          action.value(m);

          expect(s.requests[1].signal.aborted, isTrue);
          expect(s.requests[2].signal.aborted, isTrue);
          final refetches = name == 'invalidate' && watched;
          expect(s.requests, hasLength(refetches ? 4 : 3));
          // Late edge responses are never written.
          s.complete(1, items(['late-next']), next: 3);
          s.complete(2, items(['late-prev']), previous: -1);
          if (refetches) s.complete(3, items(['a', 'b']), next: 2);
          final results = await Future.wait([n.bounded, p.bounded]);
          await pump();
          final now = m.peek('q');
          for (final st in [...results, if (now != null) now]) {
            expect(st.next.isLoading, isFalse);
            expect(st.previous.isLoading, isFalse);
            expect(ids(st), isNot(contains('late-next')));
            expect(ids(st), isNot(contains('late-prev')));
          }
          switch (name) {
            case 'invalidate' when watched:
              expect(ids(results[0]), ['a', 'b']); // follow the refetch
              expect(results[1], same(results[0]));
              expect(ids(now), ['a', 'b']);
              expect(now!.isStale, isFalse);
            case 'invalidate':
              expect(ids(results[0]), ['a']);
              expect(results[0].isStale, isTrue);
              expect(ids(now), ['a']);
              expect(now!.isStale, isTrue);
            default:
              expect(results[0].hasLoaded, isFalse);
              expect(results[0].items, isEmpty);
              if (watched) {
                expect(now!.hasLoaded, isFalse);
              } else {
                expect(now, isNull);
              }
          }
          expect(done, isFalse); // a watched stream stays open
          // The lanes are reusable.
          final r = m.refresh('q');
          s.completeLast(items(['x']), next: 9);
          await r.bounded;
          final again = m.loadNext('q');
          expect(s.requests.last.cursor, 9);
          s.completeLast(items(['y']));
          expect(ids(await again.bounded), ['x', 'y']);
          if (watched) {
            await pump();
            expect(ids(states.last), ['x', 'y']);
          }
          await sub?.cancel();
        });
      }
    }
  });
}

class _SyncThrowing implements ReactiveStorage<String, PagedSnapshot<Item>> {
  @override
  Future<StoredEntry<PagedSnapshot<Item>>?> read(String key) =>
      throw StateError('r');
  @override
  Future<void> write(String key, StoredEntry<PagedSnapshot<Item>> entry) =>
      throw StateError('w');
  @override
  Future<void> delete(String key) => throw StateError('d');
  @override
  Future<void> clear() => throw StateError('c');
}
