import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// Seeded random operation sequences against [ReactivePagedManager], checked
/// against oracles that must hold for any interleaving: no hung future, no
/// future that throws, no duplicate ids, no internal error (including the
/// debug-build page-count invariant) and nothing uncaught in the zone.
///
/// Everything runs under `fakeAsync` (fetches and mutations complete through
/// fake timers), so a seed is deterministic and fast.
typedef Item = ({String id, int v});

class _Fetcher {
  _Fetcher(this.rnd);

  final Random rnd;
  final pending =
      <(PageRequest<String, int>, Completer<PageResult<Item, int>>)>[];

  Future<PageResult<Item, int>> call(PageRequest<String, int> r) {
    final c = Completer<PageResult<Item, int>>();
    pending.add((r, c));
    return c.future;
  }

  int? cursor() => rnd.nextInt(10) < 3 ? null : rnd.nextInt(8);

  void answerOne() {
    if (pending.isEmpty) return;
    final (req, c) = pending.removeAt(rnd.nextInt(pending.length));
    final roll = rnd.nextInt(20);
    if (roll == 0) {
      c.completeError(StateError('net'));
    } else if (roll == 1 && req.direction != PageDirection.initial) {
      c.completeError(const PageCursorExpiredException());
    } else {
      final n = rnd.nextInt(5);
      final items = [
        for (var i = 0; i < n; i++) (id: 'i${rnd.nextInt(20)}', v: 0),
      ];
      c.complete(PageResult(
        items,
        next: cursor(),
        previous: cursor(),
        totalCount: rnd.nextBool() ? 40 : null,
      ));
    }
  }
}

void runSeed(int seed) {
  final rnd = Random(seed);
  final fetcher = _Fetcher(rnd);
  final reported = <Object>[];
  final zoneErrors = <Object>[];
  final queries = ['q0', 'q1', 'q2'];
  final subs = <String, List<StreamSubscription<PagedState<Item>>>>{};
  var total = 0;
  var done = 0;
  String? violation;

  // [mayThrow] futures (`mutate` rethrows the user's error) may fail; the
  // loading futures never do.
  void track(Future<Object?> f, {bool mayThrow = false}) {
    total++;
    f.then<void>((_) => done++, onError: (Object e) {
      done++;
      if (!mayThrow) violation ??= 'a loading future threw: $e';
    });
  }

  runZonedGuarded(() {
    fakeAsync((async) {
      final m = ReactivePagedManager<String, Item, int>(
        fetchPage: fetcher.call,
        idOf: (i) => i.id,
        maxItems: rnd.nextBool() ? null : 4 + rnd.nextInt(8),
        retainWhenUnwatched:
            rnd.nextBool() ? Retention.all : Retention.firstPage,
        maxEntries: rnd.nextBool() ? null : 1 + rnd.nextInt(3),
        maxUnproductivePages: 1 + rnd.nextInt(3),
        refreshMode: RefreshMode.values[rnd.nextInt(3)],
        storage: rnd.nextBool() ? InMemoryReactiveStorage() : null,
        onError: (q, d, e, s) => reported.add(e),
      );

      void check(String where) {
        for (final q in queries) {
          final s = m.peek(q);
          if (s == null) continue;
          final ids = s.items.map((i) => i.id).toList();
          if (ids.toSet().length != ids.length) {
            violation ??= 'dup ids in $q after $where: $ids';
          }
          if ((s.totalCount ?? 0) < 0) violation ??= 'negative total $where';
        }
        for (final e in reported) {
          if (e is AssertionError || e is RangeError || e is TypeError) {
            violation ??= 'internal error reported: $e after $where';
          }
        }
      }

      for (var step = 0; step < 250; step++) {
        final q = queries[rnd.nextInt(queries.length)];
        final id = 'i${rnd.nextInt(20)}';
        final op = rnd.nextInt(17);
        var name = 'op$op';
        switch (op) {
          case 0:
          case 1:
            name = 'loadNext';
            track(m.loadNext(q));
          case 2:
            name = 'loadPrevious';
            track(m.loadPrevious(q));
          case 3:
            name = 'refresh';
            track(m.refresh(q,
                mode: RefreshMode.values[rnd.nextInt(3)],
                anchor: rnd.nextInt(4) == 0 ? rnd.nextInt(5) : null));
          case 4:
            name = 'patch';
            m.patchItem(id, (x) => (id: x.id, v: x.v + 1));
          case 5:
            name = 'remove';
            m.removeItem(id);
          case 6:
            name = 'upsert';
            m.upsertItem(q, (id: id, v: 99),
                at: rnd.nextBool() ? PagedEnd.head : PagedEnd.tail,
                move: rnd.nextBool());
          case 7:
            name = 'invalidate';
            m.invalidate(q);
          case 8:
            name = 'evict';
            if (rnd.nextInt(4) == 0) m.evict(q);
          case 9:
            name = 'clear';
            if (rnd.nextInt(8) == 0) m.clearCache();
          case 10:
            name = 'watch';
            subs.putIfAbsent(q, () => []).add(m.watch(q).listen((_) {}));
          case 11:
            name = 'unwatch';
            final l = subs[q];
            if (l != null && l.isNotEmpty) {
              l.removeAt(rnd.nextInt(l.length)).cancel();
            }
          case 12:
            name = 'mutate';
            final c = Completer<void>();
            track(
              m.mutate(() => c.future, optimistic: (e) {
                switch (rnd.nextInt(3)) {
                  case 0:
                    e.patchItem(id, (x) => (id: x.id, v: -1));
                  case 1:
                    e.removeItem(id);
                  default:
                    e.upsertItem(q, (id: id, v: 7), move: rnd.nextBool());
                }
              }),
              mayThrow: true,
            );
            final ok = rnd.nextBool();
            Timer(Duration(microseconds: rnd.nextInt(50)),
                () => ok ? c.complete() : c.completeError('fail'));
          case 13:
            name = 'prefetch';
            m.prefetch(q);
          default:
            name = 'answer';
            for (var k = rnd.nextInt(3); k >= 0; k--) {
              fetcher.answerOne();
            }
        }
        async.elapse(Duration(microseconds: rnd.nextInt(100)));
        check('step $step $name');
        if (violation != null) break;
      }

      // Drain: answer everything that is still pending.
      for (var i = 0; i < 2000 && fetcher.pending.isNotEmpty; i++) {
        fetcher.answerOne();
        async.elapse(Duration.zero);
        check('drain');
      }
      async.elapse(const Duration(milliseconds: 5));
      for (var i = 0; i < 2000 && fetcher.pending.isNotEmpty; i++) {
        fetcher.answerOne();
        async.elapse(Duration.zero);
      }
      async.elapse(const Duration(seconds: 1));
      if (done != total) {
        violation ??= 'a future hung ($done of $total completed, '
            'pending requests: ${fetcher.pending.length})';
      }
      for (final l in subs.values) {
        for (final s in l) {
          s.cancel();
        }
      }
      async.elapse(Duration.zero);
      check('end');
      m.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  }, (e, s) => zoneErrors.add('$e\n$s'));

  if (zoneErrors.isNotEmpty) violation ??= 'zone error: ${zoneErrors.first}';
  if (violation != null) fail('seed $seed: $violation');
}

void main() {
  for (var seed = 0; seed < 40; seed++) {
    test('paged fuzz seed $seed', () => runSeed(seed));
  }
}
