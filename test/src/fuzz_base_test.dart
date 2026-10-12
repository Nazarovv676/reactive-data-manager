import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// Seeded random operation sequences against [ReactiveDataManager], checked
/// against oracles that must hold for any interleaving: no hung future,
/// nothing uncaught in the zone, and at quiescence every live `watchState` and
/// `getStream` listener agrees with `getCurrentValue`.
///
/// Everything runs under `fakeAsync` (fetches and updates complete through the
/// test, `maxAge`/eviction timers use the fake clock), so a seed is
/// deterministic and fast.
void runSeed(int seed) {
  final rnd = Random(seed);
  final pending = <Completer<int>>[];
  final upd = <Completer<Object?>>[];
  final zoneErrors = <String>[];
  final keys = ['a', 'b', 'c', 'd'];
  final lastState = <String, DataState<int>>{};
  final lastValue = <StreamSubscription<int?>, int?>{};
  final doneSubs = <StreamSubscription<int?>>{};
  final stateSubs = <String, List<StreamSubscription<DataState<int>>>>{};
  final valueSubs = <String, List<StreamSubscription<int?>>>{};
  var total = 0;
  var done = 0;
  var next = 0;
  String? violation;

  // Every awaited future must complete (with a value or an error).
  void track(Future<Object?> f) {
    total++;
    f.then<void>((_) => done++, onError: (Object _) => done++);
  }

  runZonedGuarded(() {
    fakeAsync((async) {
      final clock = async.getClock(DateTime(2026));
      final m = ReactiveDataManager<String, int>.cancellable(
        fetcher: (k, signal) {
          final c = Completer<int>();
          if (rnd.nextBool()) {
            signal.whenAborted.then((_) {
              if (!c.isCompleted) c.completeError('cancelled');
            });
          }
          pending.add(c);
          return c.future;
        },
        updater: rnd.nextBool()
            ? (k, v) {
                final c = Completer<Object?>();
                upd.add(c);
                return c.future;
              }
            : null,
        maxAge: rnd.nextBool() ? null : const Duration(milliseconds: 1),
        clock: clock.now,
        replayErrors: rnd.nextBool(),
        storage: rnd.nextBool() ? InMemoryReactiveStorage<String, int>() : null,
        maxEntries: rnd.nextBool() ? null : 1 + rnd.nextInt(2),
        evictAfterUnwatched: rnd.nextBool()
            ? null
            : Duration(microseconds: 1 + rnd.nextInt(300)),
      );

      for (var step = 0; step < 200; step++) {
        final k = keys[rnd.nextInt(keys.length)];
        switch (rnd.nextInt(20)) {
          case 0:
          case 1:
            track(m.getData(k));
          case 2:
            track(m.getData(k, forceRefresh: true));
          case 3:
            m.refresh(k);
          case 4:
            m.prefetch(k);
          case 5:
            m.invalidate(k);
          case 6:
            m.invalidateWhere((x) => x == k || x == 'c');
          case 7:
            if (rnd.nextInt(3) == 0) m.invalidateAll();
          case 8:
            m.set(k, 1000 + step);
          case 9:
            m.patch(k, (v) => v + 1);
          case 10:
            track(m.updateData(k, 5000 + step));
          case 11:
            if (rnd.nextInt(3) == 0) {
              m.evict(k);
              // `evict` closes the key's streams: its current getStream
              // listeners are done. (With `replayErrors: false` the stream is
              // an `Rx.merge`, whose done event never fires under fakeAsync.)
              doneSubs.addAll(valueSubs[k] ?? const []);
            }
          case 12:
            if (rnd.nextInt(6) == 0) m.clearCache();
          case 13:
            stateSubs.putIfAbsent(k, () => []).add(m
                .watchState(k, fetch: rnd.nextBool())
                .listen((s) => lastState[k] = s));
          case 14:
            late StreamSubscription<int?> sub;
            sub = m.getStream(k).listen(
                  (v) => lastValue[sub] = v,
                  onError: (Object e) => lastValue[sub] = -999,
                  onDone: () => doneSubs.add(sub),
                );
            valueSubs.putIfAbsent(k, () => []).add(sub);
          case 15:
            final l = stateSubs[k];
            if (l != null && l.isNotEmpty) l.removeAt(0).cancel();
            final l2 = valueSubs[k];
            if (l2 != null && l2.isNotEmpty) l2.removeAt(0).cancel();
          case 16:
            track(m.mutate(k, () async => rnd.nextBool() ? 1 : throw 'x'));
          default:
            for (var i = rnd.nextInt(3); i >= 0 && pending.isNotEmpty; i--) {
              final c = pending.removeAt(rnd.nextInt(pending.length));
              if (!c.isCompleted) {
                rnd.nextInt(6) == 0
                    ? c.completeError('net')
                    : c.complete(next++);
              }
            }
            if (upd.isNotEmpty && rnd.nextBool()) {
              final c = upd.removeAt(0);
              rnd.nextBool() ? c.complete(null) : c.completeError('upd');
            }
        }
        async.elapse(Duration(microseconds: rnd.nextInt(100)));
      }

      // Drain: complete everything that is still pending.
      for (var i = 0; i < 500 && (pending.isNotEmpty || upd.isNotEmpty); i++) {
        if (pending.isNotEmpty) {
          final c = pending.removeAt(0);
          if (!c.isCompleted) c.complete(next++);
        }
        if (upd.isNotEmpty) upd.removeAt(0).complete(null);
        async.elapse(Duration.zero);
      }
      async.elapse(const Duration(seconds: 1));
      if (done != total) violation ??= 'future hung ($done of $total)';

      // Consistency at quiescence.
      for (final k in keys) {
        final cur = m.getCurrentValue(k);
        if (stateSubs[k]?.isNotEmpty ?? false) {
          final s = lastState[k];
          if (s == null ||
              s.data != cur ||
              s.hasData != (cur != null) ||
              s.isLoading) {
            violation ??= 'watchState($k) last=$s vs current=$cur';
          }
        }
        for (final sub in valueSubs[k] ?? const <StreamSubscription<int?>>[]) {
          // A listener of an evicted key was told "done"; A4: a getStream
          // replay of an old value or error is not a mismatch.
          if (doneSubs.contains(sub)) continue;
          if (lastValue[sub] != -999 && lastValue[sub] != cur) {
            violation ??=
                'getStream($k) live sub last=${lastValue[sub]} vs current=$cur';
          }
        }
      }
      for (final l in [...stateSubs.values, ...valueSubs.values]) {
        for (final s in l) {
          s.cancel();
        }
      }
      async.elapse(Duration.zero);
      m.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  }, (e, s) => zoneErrors.add('$e'));

  if (zoneErrors.isNotEmpty) violation ??= 'zone errors: ${zoneErrors.take(3)}';
  if (violation != null) fail('seed $seed: $violation');
}

void main() {
  for (var seed = 0; seed < 80; seed++) {
    test('base fuzz seed $seed', () => runSeed(seed));
  }
}
