// Keeps the README recipe "Detecting a newly failed load (toasts)" honest:
// the extension below is the README code, verbatim.
import 'dart:async';

import 'package:reactive_data_manager/reactive_data_manager.dart';
import 'package:reactive_data_manager/testing.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

extension NewFailures<T> on Stream<PagedState<T>> {
  /// The errors that newly appear in the states of this stream (refresh,
  /// next or previous), once per failed load. Errors already present in the
  /// first state (e.g. when a screen is reopened) are skipped.
  Stream<PagedError> newFailures() {
    PagedState<T>? before;
    return expand((after) {
      final prev = before;
      before = after;
      if (prev == null) return const <PagedError>[];
      return [
        if (_isNew(prev.refreshError, after.refreshError)) after.refreshError!,
        if (_isNew(prev.next.error, after.next.error)) after.next.error!,
        if (_isNew(prev.previous.error, after.previous.error))
          after.previous.error!,
      ];
    });
  }
}

// PagedError has value equality: `!=` (not `identical`) is the right test.
// It is still never fooled by two equal failures in a row, because a retry
// clears the error (a state with `null` is emitted) before it can fail again.
bool _isNew(PagedError? before, PagedError? after) =>
    after != null && after != before;

typedef Item = ({String id});

class _Boom implements Exception {
  const _Boom();
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late ScriptedPageFetcher<String, Item, int> pages;
  late ReactivePagedManager<String, Item, int> m;

  setUp(() {
    pages = ScriptedPageFetcher<String, Item, int>();
    m = ReactivePagedManager<String, Item, int>(
      fetchPage: pages.call,
      idOf: (i) => i.id,
    );
  });

  tearDown(() => m.dispose());

  test('reports each failed load once, even equal failures in a row', () async {
    final failures = <PagedError>[];
    final sub = m.watch('q').newFailures().listen(failures.add);
    await pump();
    pages.fail(0, const _Boom()); // first load fails
    await pump();
    expect(failures, hasLength(1));

    // Re-emissions that keep the error do not report it again.
    m.upsertItem('q', (id: 'x'));
    m.invalidate('q'); // watched: refetches, clears the error first
    await pump();
    pages.fail(1, const _Boom()); // an equal PagedError (same error, stack)
    await pump();
    expect(failures, hasLength(2));
    expect(failures[0], failures[1]); // equal values, two separate toasts

    final r = m.refresh('q');
    pages.completeLast([(id: 'a')], next: 2);
    await r;
    final n = m.loadNext('q');
    pages.fail(3, const _Boom());
    await n;
    await pump();
    expect(failures, hasLength(3));
    expect(m.peek('q')!.next.error, failures.last);

    m.patchItem('a', (i) => i); // state with the same next.error
    await pump();
    expect(failures, hasLength(3));
    await sub.cancel();
  });

  test('skips an error that is already in the first state', () async {
    final first = m.refresh('q');
    pages.fail(0, const _Boom());
    await first;
    final failures = <PagedError>[];
    final sub = m.watch('q', fetch: false).newFailures().listen(failures.add);
    await pump();
    expect(m.peek('q')!.refreshError, isNotNull);
    expect(failures, isEmpty);
    await sub.cancel();
  });

  test('the rxdart pairwise() variant', () async {
    final failures = <PagedError>[];
    final sub = m.watch('q').pairwise().listen((pair) {
      final [before, after] = pair;
      for (final (b, a) in [
        (before.refreshError, after.refreshError),
        (before.next.error, after.next.error),
        (before.previous.error, after.previous.error),
      ]) {
        if (a != null && a != b) failures.add(a);
      }
    });
    await pump();
    pages.fail(0, const _Boom());
    await pump();
    m.invalidate('q');
    await pump();
    pages.fail(1, const _Boom());
    await pump();
    expect(failures, hasLength(2));
    await sub.cancel();
  });
}
