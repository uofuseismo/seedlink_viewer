@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';
import 'package:waveform_viewer/services/seedlink_packet_reader.dart';
import 'package:waveform_viewer/services/seedlink_session.dart';

/// Talks to a real SEEDLink server on localhost:18000.
void main() {
  test('reads real packets into the dart model', () async {
    const source = SeedLinkStreamSource(host: 'localhost', port: 18000);
    final offered = await source.fetchStreams();
    final wanted = offered
        .where((s) => s.channel == 'HHZ')
        .take(2)
        .toList();
    expect(wanted, isNotEmpty, reason: 'no HHZ channels on this server');

    final reader = await SeedLinkPacketReader.start(
      host: 'localhost',
      port: 18000,
      streams: wanted,
    );

    final received = <StreamPacket>[];
    final subscription = reader.packets.listen(received.add);
    final giveUp = DateTime.now().add(const Duration(seconds: 40));
    while (received.isEmpty && DateTime.now().isBefore(giveUp)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await subscription.cancel();
    await reader.stop();

    expect(received, isNotEmpty, reason: 'no packets arrived within 40s');
    final first = received.first;
    // ignore: avoid_print
    print(
      'Read ${received.length} packets, first ${first.identifier} '
      'with ${first.packet.data.length} samples at '
      '${first.packet.samplingRateHz} Hz, seq ${first.sequenceNumber}',
    );

    for (final entry in received) {
      // The identifier survived the trip through the native struct
      expect(wanted.contains(entry.identifier), isTrue);

      final packet = entry.packet;
      expect(packet.data, isNotEmpty);
      expect(packet.samplingRateHz, greaterThan(0));
      expect(entry.sequenceNumber, isNot(-1));

      // Microseconds, not the nanoseconds the native side keeps. Anything
      // still in nanoseconds would land tens of thousands of years hence.
      final when = DateTime.fromMicrosecondsSinceEpoch(packet.startTimeMuS);
      expect(when.year, DateTime.now().year);

      // The model derives the end time from the sample count and rate, so a
      // wrong time unit would show up as a nonsensical duration.
      final spanMuS = packet.endTimeMuS - packet.startTimeMuS;
      final expectedMuS =
          ((packet.data.length - 1) * 1e6 / packet.samplingRateHz).round();
      expect(spanMuS, closeTo(expectedMuS, 2));
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('retargeting mid-flight switches which streams arrive', () async {
    const source = SeedLinkStreamSource(host: 'localhost', port: 18000);
    final offered = await source.fetchStreams();
    final vertical = offered.where((s) => s.channel == 'HHZ').toList();
    expect(vertical.length, greaterThanOrEqualTo(2));

    final reader = await SeedLinkPacketReader.start(
      host: 'localhost',
      port: 18000,
      streams: [vertical.first],
    );

    final seen = <StreamIdentifier>{};
    final subscription = reader.packets.listen((p) => seen.add(p.identifier));

    Future<void> waitFor(StreamIdentifier wanted) async {
      final giveUp = DateTime.now().add(const Duration(seconds: 30));
      while (!seen.contains(wanted) && DateTime.now().isBefore(giveUp)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    await waitFor(vertical.first);
    expect(seen, contains(vertical.first));

    // Now ask for a different station and check it turns up
    seen.clear();
    reader.setStreams([vertical[1]]);
    await waitFor(vertical[1]);

    await subscription.cancel();
    await reader.stop();

    expect(
      seen,
      contains(vertical[1]),
      reason: 'the new selection never arrived',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
