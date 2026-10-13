import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

/// A `getData` of an unwatched key counts as use for automatic eviction.
void main() {
  const timeout = Duration(seconds: 30);

  ReactiveDataManager<String, int> make(List<String> fetched, {int? max}) {
    return ReactiveDataManager<String, int>(
      fetcher: (key) async {
        fetched.add(key);
        return fetched.length;
      },
      evictAfterUnwatched: timeout,
      maxEntries: max,
    );
  }

  test('getData every 10 s keeps an unwatched key past the 30 s timer', () {
    fakeAsync((async) {
      final fetched = <String>[];
      final m = make(fetched);
      m.getData('k').ignore();
      async.flushMicrotasks();
      for (var i = 0; i < 6; i++) {
        async.elapse(const Duration(seconds: 10));
        m.getData('k').ignore();
        async.flushMicrotasks();
      }
      expect(fetched, ['k'], reason: 'every hit restarted the timer');
      expect(m.getCurrentValue('k'), 1);
    });
  });

  test('an idle unwatched key is evicted after 30 s', () {
    fakeAsync((async) {
      final fetched = <String>[];
      final m = make(fetched);
      m.getData('k').ignore();
      async.flushMicrotasks();
      async.elapse(timeout);
      expect(m.getCurrentValue('k'), isNull);
      m.getData('k').ignore();
      async.flushMicrotasks();
      expect(fetched, ['k', 'k']);
    });
  });

  test('prefetch and refresh count as use too', () {
    fakeAsync((async) {
      final fetched = <String>[];
      final m = make(fetched);
      m.prefetch('k');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      m.prefetch('k'); // a fresh hit: restarts the timer, no fetch
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      expect(m.getCurrentValue('k'), isNotNull);
      m.refresh('k'); // a forced fetch: restarts the timer as well
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 20));
      expect(m.getCurrentValue('k'), isNotNull);
      expect(fetched, ['k', 'k']);
    });
  });

  test('a watched key is unaffected: touching never starts a timer', () {
    fakeAsync((async) {
      final fetched = <String>[];
      final m = make(fetched);
      final sub = m.getStream('k').listen((_) {});
      m.getData('k').ignore();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      m.getData('k').ignore();
      async.flushMicrotasks();
      expect(fetched, ['k']);
      expect(m.getCurrentValue('k'), 1);
      // Leaving starts the countdown from that moment.
      sub.cancel();
      async.elapse(timeout);
      expect(m.getCurrentValue('k'), isNull);
    });
  });

  test('with maxEntries a getData hit makes the key the newest', () {
    fakeAsync((async) {
      final fetched = <String>[];
      final m = make(fetched, max: 2);
      m.getData('a').ignore();
      m.getData('b').ignore();
      async.flushMicrotasks();
      m.getData('a').ignore(); // 'a' is now more recent than 'b'
      async.flushMicrotasks();
      m.getData('c').ignore(); // over the limit: the oldest ('b') goes
      async.flushMicrotasks();
      expect(m.getCurrentValue('a'), isNotNull);
      expect(m.getCurrentValue('b'), isNull);
      expect(m.getCurrentValue('c'), isNotNull);
    });
  });
}
