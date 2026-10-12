import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/testing.dart';

typedef Item = ({String id, int v});

Item it(String id, [int v = 0]) => (id: id, v: v);
List<Item> items(Iterable<String> ids) => [for (final i in ids) it(i)];
List<String> ids(PagedState<Item>? s) => [for (final i in s!.items) i.id];

Future<void> pump() => Future<void>.delayed(Duration.zero);

typedef Scripted = ScriptedPageFetcher<String, Item, int>;
typedef Manager = ReactivePagedManager<String, Item, int>;

Manager make(
  Scripted s, {
  int maxUnproductive = 3,
  int? maxItems,
  Duration? maxAge,
  DateTime Function()? clock,
  ReactiveStorage<String, PagedSnapshot<Item>>? storage,
}) =>
    ReactivePagedManager<String, Item, int>(
      fetchPage: s.call,
      idOf: (i) => i.id,
      maxUnproductivePages: maxUnproductive,
      maxItems: maxItems,
      maxAge: maxAge,
      clock: clock ?? DateTime.now,
      storage: storage,
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

void main() {
  group('debugCursors', () {
    test('null for a query that is not cached', () {
      final m = make(Scripted());
      expect(m.debugCursors('q'), isNull);
    });

    test('nothing loaded yet: no cursors, no pages', () {
      final s = Scripted();
      final m = make(s);
      m.loadNext('q').ignore();
      expect(m.debugCursors('q'), (next: null, previous: null, pages: 0));
    });

    test('follows loadNext and loadPrevious', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['c']), next: 4, previous: 2);
      expect(m.debugCursors('q'), (next: 4, previous: 2, pages: 1));

      final n = m.loadNext('q');
      expect(s.requests.last.cursor, 4);
      s.completeLast(items(['d']), next: 5, previous: 3);
      await n;
      expect(m.debugCursors('q'), (next: 5, previous: 2, pages: 2));

      final p = m.loadPrevious('q');
      expect(s.requests.last.cursor, 2);
      s.completeLast(items(['b']), next: 3, previous: null);
      await p;
      expect(m.debugCursors('q'), (next: 5, previous: null, pages: 3));
    });

    test('an exhausted edge reports no cursor', () async {
      final s = Scripted();
      final m = make(s, maxUnproductive: 1);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.completeLast(items(['a']), next: 3); // nothing new: exhausted
      await f;
      expect(m.debugCursors('q')!.next, isNull);
    });

    test('a cursor loop reports no cursor', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      final f = m.loadNext('q');
      s.completeLast(items(['b']), next: 2); // same cursor again
      await f;
      expect(m.debugCursors('q'), (next: null, previous: null, pages: 2));
    });

    test('windowing restores the dropped side cursor', () async {
      final s = Scripted();
      final m = make(s, maxItems: 2);
      await seed(m, s, 'q', items(['a', 'b']), next: 2);
      final f = m.loadNext('q');
      s.completeLast(items(['c', 'd']), next: 3, previous: 1);
      await f;
      expect(ids(m.peek('q')), ['c', 'd']);
      expect(m.debugCursors('q'), (next: 3, previous: 1, pages: 1));
    });

    test('a restored snapshot has no cursors', () async {
      final storage = InMemoryReactiveStorage<String, PagedSnapshot<Item>>();
      storage.entries['q'] =
          StoredEntry(PagedSnapshot(items(['a', 'b'])), DateTime(2020));
      final s = Scripted();
      final m = make(s, storage: storage);
      final states = <PagedState<Item>>[];
      final sub = m.watch('q', fetch: false).listen(states.add);
      await pump();
      await pump();
      expect(ids(m.peek('q')), ['a', 'b']);
      expect(m.debugCursors('q'), (next: null, previous: null, pages: 1));
      await sub.cancel();
    });

    test('evict forgets the cursors', () async {
      final s = Scripted();
      final m = make(s);
      await seed(m, s, 'q', items(['a']), next: 2);
      m.evict('q');
      expect(m.debugCursors('q'), isNull);
    });
  });

  group('maxUnproductivePages warning', () {
    test('exhausting the previous edge also stops (debug log path)', () async {
      final s = Scripted();
      final m = make(s, maxUnproductive: 2);
      await seed(m, s, 'q', items(['b']), previous: 1);
      final f = m.loadPrevious('q');
      s.completeLast(items(['b']), previous: 0);
      await pump();
      s.completeLast(items(['b']), previous: -1);
      final st = await f;
      expect(s.requests, hasLength(3));
      expect(st.previous.hasMore, isFalse);
      expect(st.previous.error, isNull);
    });
  });
}
