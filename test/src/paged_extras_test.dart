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

  group('errorMapper', () {
    Manager mapped(
      Scripted s, {
      required Object Function(Object, StackTrace) mapper,
      List<Object>? reported,
      RefreshMode mode = RefreshMode.firstPage,
    }) =>
        ReactivePagedManager<String, Item, int>(
          fetchPage: s.call,
          idOf: (i) => i.id,
          refreshMode: mode,
          errorMapper: mapper,
          onError: (q, d, e, st) => reported?.add(e),
        );

    test('maps head errors into the state and onError', () async {
      final s = Scripted();
      final reported = <Object>[];
      final m =
          mapped(s, mapper: (e, st) => _Failure('$e'), reported: reported);
      final f = m.refresh('q');
      final trace = StackTrace.current;
      s.failLast(StateError('boom'), trace);
      final st = await f;
      expect(st.refreshError!.error, const _Failure('Bad state: boom'));
      expect(st.refreshError!.errorAs<_Failure>()!.message, 'Bad state: boom');
      expect(st.refreshError!.stackTrace, trace);
      expect(st.hasInitialError, isTrue);
      expect(reported, [const _Failure('Bad state: boom')]);
    });

    test('maps next and previous errors', () async {
      final s = Scripted();
      final reported = <Object>[];
      final m = mapped(s, mapper: (e, st) => 'mapped', reported: reported);
      await seed(m, s, 'q', items(['b']), next: 2, previous: 0);
      final n = m.loadNext('q');
      s.failLast(StateError('n'));
      expect((await n).next.error!.error, 'mapped');
      final p = m.loadPrevious('q');
      s.failLast(StateError('p'));
      final st = await p;
      expect(st.previous.error!.error, 'mapped');
      expect(st.previous.error!.errorAs<int>(), isNull);
      expect(reported, ['mapped', 'mapped']);
    });

    test('maps an error of a later page of RefreshMode.allPages', () async {
      final s = Scripted();
      final m =
          mapped(s, mapper: (e, st) => 'mapped', mode: RefreshMode.allPages);
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.completeLast(items(['b']));
      await n;
      final r = m.refresh('q');
      s.completeLast(items(['a']), next: 2);
      await pump();
      s.failLast(StateError('page 2'));
      final st = await r;
      expect(st.refreshError!.error, 'mapped');
      expect(ids(st), ['a', 'b']); // old window kept
    });

    test('a throwing mapper falls back to the raw error', () async {
      final s = Scripted();
      final m = mapped(s, mapper: (e, st) => throw ArgumentError('bug'));
      final f = m.refresh('q');
      final boom = StateError('boom');
      s.failLast(boom);
      expect((await f).refreshError!.error, same(boom));
      // The lane is not wedged.
      final g = m.refresh('q');
      s.completeLast(items(['a']));
      expect(ids(await g), ['a']);
    });

    test('an expired cursor is recovered, never mapped', () async {
      final s = Scripted();
      final mapperCalls = <Object>[];
      final m = mapped(s, mapper: (e, st) {
        mapperCalls.add(e);
        return 'mapped';
      });
      await seed(m, s, 'q', items(['a']), next: 2);
      final n = m.loadNext('q');
      s.failLast(const PageCursorExpiredException());
      await pump();
      expect(s.requests.last.direction, PageDirection.initial);
      s.completeLast(items(['a', 'b']));
      final st = await n;
      expect(ids(st), ['a', 'b']);
      expect(st.next.error, isNull);
      expect(mapperCalls, isEmpty);
    });

    test('errors of a discarded load are not mapped', () async {
      final s = Scripted();
      final mapperCalls = <Object>[];
      final m = mapped(s, mapper: (e, st) {
        mapperCalls.add(e);
        return 'mapped';
      });
      final f = m.refresh('q');
      m.evict('q');
      s.failLast(StateError('late'));
      await f;
      await pump();
      expect(mapperCalls, isEmpty);
    });
  });
}

class _Failure {
  const _Failure(this.message);
  final String message;

  @override
  bool operator ==(Object other) =>
      other is _Failure && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
