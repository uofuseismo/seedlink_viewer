import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waveform_viewer/views/stream_painter.dart';
import 'package:waveform_viewer/services/seedlink_packet_reader.dart';
import 'package:waveform_viewer/views/stream_registry.dart';
import 'package:waveform_viewer/models/packet.dart';
import 'package:waveform_viewer/models/stream.dart' as models;
import 'package:waveform_viewer/models/stream_identifier.dart';

const int _oneSecond = 1000000;

/// A packet of [count] samples at 100 Hz starting at [startMuS].
Packet packetOf(int startMuS, List<double> samples) {
  return Packet(startMuS, 100.0, Float64List.fromList(samples));
}

/// Real seismometers sit on a DC offset - counts are nowhere near zero.
List<double> offsetSamples(int count, {double about = 30000, double swing = 50}) {
  return List<double>.generate(
    count,
    (i) => about + (i.isEven ? swing : -swing),
  );
}

void main() {
  group('scaling a trace that sits on a DC offset', () {
    test('the range covers the data, not the gap down to zero', () {
      final start = DateTime.now().microsecondsSinceEpoch - 10 * _oneSecond;
      final stream = models.Stream(
        StreamIdentifier('UU', 'BGU', 'HHZ', '01'),
        [packetOf(start, offsetSamples(100))],
      );

      final minMax = stream.getMinimumAndMaximumInTimeRange(
        start - _oneSecond,
        start + 10 * _oneSecond,
      );

      // Seeded at zero the minimum comes back as 0 and the trace is squashed
      // into the top of the plot - which is what "the station shows nothing"
      // actually looks like.
      expect(minMax.x, 29950);
      expect(minMax.y, 30050);
    });

    test('a trace entirely below zero is not clipped at zero either', () {
      final start = DateTime.now().microsecondsSinceEpoch - 10 * _oneSecond;
      final stream = models.Stream(
        StreamIdentifier('UU', 'FOR6', 'HHZ', '01'),
        [packetOf(start, offsetSamples(100, about: -12000))],
      );

      final minMax = stream.getMinimumAndMaximumInTimeRange(
        start - _oneSecond,
        start + 10 * _oneSecond,
      );

      expect(minMax.x, -12050);
      expect(minMax.y, -11950);
    });

    test('an empty stream does not pretend to have a range', () {
      final stream = models.Stream(
        StreamIdentifier('UU', 'NEW', 'HHZ', '01'),
        <Packet>[],
      );
      final now = DateTime.now().microsecondsSinceEpoch;
      final minMax = stream.getMinimumAndMaximumInTimeRange(
        now - _oneSecond,
        now,
      );
      // Nothing to draw, so a flat zero range is the honest answer
      expect(minMax.x, 0);
      expect(minMax.y, 0);
    });
  });

  group('painting a plot that has no data yet', () {
    testWidgets('renders instead of blanking', (tester) async {
      final registry = StreamRegistry();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamPainter(
              identifier: StreamIdentifier('UU', 'BGU', 'HHZ', '01'),
              registry: registry,
            ),
          ),
        ),
      );
      await tester.pump();

      // A plot registers before any packet arrives, and a silent station may
      // never send one. The transform used to be left unset in that case,
      // which threw inside paint and blanked the whole plot.
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('a dead flat channel still renders', (tester) async {
      final registry = StreamRegistry();
      final identifier = StreamIdentifier('UU', 'FLAT', 'HHZ', '01');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamPainter(identifier: identifier, registry: registry),
          ),
        ),
      );
      await tester.pump();

      // Every sample identical, so the range is zero
      final now = DateTime.now().microsecondsSinceEpoch;
      registry.deliver(
        StreamPacket(
          identifier: identifier,
          packet: packetOf(
            now - 5 * _oneSecond,
            List<double>.filled(100, 30000),
          ),
          sequenceNumber: 1,
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('a packet straddling the edge of the plot window', () {
    test('reports the range of the part inside the window', () {
      // Ten seconds of samples ramping from 0 to 999
      const start = 1000 * _oneSecond;
      final samples = List<double>.generate(1000, (i) => i.toDouble());
      final packet = packetOf(start, samples);

      // A window covering only the first half
      final minMax = packet.getMinimumAndMaximumInTimeRange(
        start,
        start + 5 * _oneSecond,
      );

      expect(minMax, isNotNull);
      // The first 500 samples are 0..499. Generous edges are fine, but the
      // answer must not collapse to a single sample.
      expect(minMax!.x, lessThanOrEqualTo(1));
      expect(minMax.y, greaterThanOrEqualTo(498));
      expect(minMax.y, lessThan(600));
    });

    test('reports the range of the part inside a late window', () {
      const start = 1000 * _oneSecond;
      final samples = List<double>.generate(1000, (i) => i.toDouble());
      final packet = packetOf(start, samples);

      // A window covering only the last half - the case that matters most,
      // because the newest packet always straddles the right hand edge.
      final minMax = packet.getMinimumAndMaximumInTimeRange(
        start + 5 * _oneSecond,
        start + 20 * _oneSecond,
      );

      expect(minMax, isNotNull);
      expect(minMax!.y, greaterThanOrEqualTo(998));
      expect(minMax.x, greaterThan(400));
    });

    test('does not throw when the window starts past the last sample', () {
      const start = 1000 * _oneSecond;
      final packet = packetOf(start, List<double>.filled(100, 5.0));
      // Just inside the packet, close to its end
      expect(
        () => packet.getMinimumAndMaximumInTimeRange(
          start + 990000,
          start + 30 * _oneSecond,
        ),
        returnsNormally,
      );
    });
  });
}
