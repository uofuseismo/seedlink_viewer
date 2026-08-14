import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/services/stream_source.dart';

void main() {
  group('SampleStreamSource', () {
    test('loads the captured response through the native parser', () async {
      // Needed so rootBundle can reach the declared asset
      TestWidgetsFlutterBinding.ensureInitialized();

      const source = SampleStreamSource(delay: Duration.zero);
      final streams = await source.fetchStreams();

      expect(streams, hasLength(114));
      expect(
        streams.map((s) => s.toString()),
        contains('UU.ARUT.EHZ.01'),
      );
      expect(streams.every((s) => s.network == 'UU'), isTrue);
    });

    test('pauses so the progress frame is visible', () async {
      TestWidgetsFlutterBinding.ensureInitialized();

      const source = SampleStreamSource(delay: Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      await source.fetchStreams();
      watch.stop();

      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(90));
    });

    test('rejects a response it cannot parse', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(
        () => parseStreamsResponse('not json'),
        throwsA(isA<StreamSourceException>()),
      );
    });
  });
}
