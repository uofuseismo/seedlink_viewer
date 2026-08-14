@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/services/seedlink_session.dart';
import 'package:waveform_viewer/services/stream_source.dart';

/// These talk to a real SEEDLink server on localhost:18000 and are skipped
/// by CI for that reason - see the test list in .github/workflows/build.yml.
void main() {
  test('ping + live stream query against the local ringserver', () async {
    final id = await pingSeedLinkServer(host: 'localhost', port: 18000);
    // ignore: avoid_print
    print('ping -> $id');
    expect(id, isNotEmpty);

    const source = SeedLinkStreamSource(host: 'localhost', port: 18000);
    final streams = await source.fetchStreams();
    // ignore: avoid_print
    print('getStreams -> ${streams.length} streams, first ${streams.first}');
    expect(streams.length, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a dead host fails rather than hanging', () async {
    await expectLater(
      pingSeedLinkServer(host: 'localhost', port: 19999),
      throwsA(isA<StreamSourceException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
