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
