@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/seedlink_packet_reader.dart';
import 'package:seedlink_viewer/services/seedlink_session.dart';

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
    // A stream being offered does not mean it is still producing - the list
    // includes stations that went quiet hours ago - so which ones are live has
    // to be discovered by listening rather than assumed from the list.
    final candidates = offered
        .where((s) => s.channel == 'HHZ')
        .take(8)
        .toList();
    expect(candidates.length, greaterThanOrEqualTo(2));

    final reader = await SeedLinkPacketReader.start(
      host: 'localhost',
      port: 18000,
      streams: candidates,
    );

    var seen = <StreamIdentifier>{};
    final subscription = reader.packets.listen((p) => seen.add(p.identifier));

    Future<void> waitUntil(bool Function() done, Duration limit) async {
      final giveUp = DateTime.now().add(limit);
      while (!done() && DateTime.now().isBefore(giveUp)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    // Find two stations that are actually sending right now
    await waitUntil(() => seen.length >= 2, const Duration(seconds: 40));
    final live = seen.toList();
    expect(
      live.length,
      greaterThanOrEqualTo(2),
      reason: 'fewer than two of $candidates are currently producing',
    );

    // Narrow to just one of them
    final keep = live[1];
    seen = <StreamIdentifier>{};
    reader.setStreams([keep]);
    await waitUntil(() => seen.contains(keep), const Duration(seconds: 40));
    expect(seen, contains(keep), reason: 'the new selection never arrived');

    // ... and once it has settled, nothing else should still be coming
    seen = <StreamIdentifier>{};
    await Future<void>.delayed(const Duration(seconds: 5));
    final strays = seen.difference({keep});

    await subscription.cancel();
    await reader.stop();

    expect(strays, isEmpty, reason: 'dropped streams are still arriving');
  }, timeout: const Timeout(Duration(seconds: 150)));
}
