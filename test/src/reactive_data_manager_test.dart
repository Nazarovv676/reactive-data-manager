import 'package:flutter_test/flutter_test.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

void main() {
  group('ReactiveDataManager', () {
    late ReactiveDataManager<String, String> manager;
    late Future<String> Function(String key) fetcher;
    late Future<dynamic> Function(String key, String data) updater;

    setUp(() {
      fetcher = (key) async => 'fetched_$key';
      updater = (key, data) async => data;
      manager = ReactiveDataManager<String, String>(
        fetcher: fetcher,
        updater: updater,
      );
    });

    test('getStream returns a stream for a specific key', () {
      final stream = manager.getStream('key1');
      expect(stream, isA<Stream<String?>>());
    });

    test('getCurrentValue returns the current value for a specific key', () {
      manager.getStream('key1').listen((value) {
        expect(value, 'fetched_key1');
      });
      manager.getData('key1');
    });

    test('getData fetches data and updates the cache', () async {
      final data = await manager.getData('key1');
      expect(data, 'fetched_key1');
      expect(manager.getCurrentValue('key1'), 'fetched_key1');
    });

    test('getData returns cached data if not forced to refresh', () async {
      await manager.getData('key1');
      final data = await manager.getData('key1');
      expect(data, 'fetched_key1');
    });

    test('getData forces refresh if specified', () async {
      final data = await manager.getData('key1', forceRefresh: true);
      expect(data, 'fetched_key1');
    });

    test('updateData updates data and notifies listeners', () async {
      await manager.getData('key1');
      final result = await manager.updateData('key1', 'new_data');
      expect(result, 'new_data');
      expect(manager.getCurrentValue('key1'), 'new_data');
    });

    test('clearCache clears the cache', () async {
      await manager.getData('key1');
      manager.clearCache();
      expect(manager.getCurrentValue('key1'), isNull);
    });

    test('dispose cancels all active operations and closes all subjects', () {
      manager.dispose();
      expect(manager.getStream('key1'), isA<Stream<String?>>());
    });
  });
}
