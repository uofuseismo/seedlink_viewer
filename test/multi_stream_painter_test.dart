import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/models/packet.dart';
import 'package:seedlink_viewer/models/plot_timing.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/seedlink_packet_reader.dart';
import 'package:seedlink_viewer/views/multi_stream_painter.dart';
import 'package:seedlink_viewer/views/stream_painter.dart';
import 'package:seedlink_viewer/views/stream_registry.dart';

StreamIdentifier id(String name) => StreamIdentifier.fromString(name);

StreamPacket packetFor(String name, {double value = 1.0}) {
  return StreamPacket(
    identifier: id(name),
    packet: Packet(
      DateTime.now().microsecondsSinceEpoch,
      100.0,
      Float64List.fromList([value, value, value]),
    ),
    sequenceNumber: 1,
  );
}

void main() {
  group('StreamRegistry', () {
    test('delivers to the plot that asked for that stream', () {
      final registry = StreamRegistry();
      final toBGU = <Packet>[];
      final toARUT = <Packet>[];

      registry.register(id('UU.BGU.HHZ.01'), toBGU.add);
      registry.register(id('UU.ARUT.EHZ.01'), toARUT.add);

      expect(registry.deliver(packetFor('UU.BGU.HHZ.01')), isTrue);

      // One connection carries every stream, so the identifier is what keeps
      // one plot's data out of another's
      expect(toBGU, hasLength(1));
      expect(toARUT, isEmpty);
    });

    test('reports packets nobody is plotting rather than throwing', () {
      final registry = StreamRegistry();
      // This happens routinely: a dropped stream keeps draining for a moment
      // after the selection changes.
      expect(registry.deliver(packetFor('UU.GONE.HHZ.01')), isFalse);
    });

    test('unregistering stops delivery', () {
      final registry = StreamRegistry();
      final received = <Packet>[];
      void sink(Packet p) => received.add(p);

      registry.register(id('UU.BGU.HHZ.01'), sink);
      registry.deliver(packetFor('UU.BGU.HHZ.01'));
      registry.unregister(id('UU.BGU.HHZ.01'), sink);
      registry.deliver(packetFor('UU.BGU.HHZ.01'));

      expect(received, hasLength(1));
    });

    test('a replacement registration survives the old one being disposed', () {
      final registry = StreamRegistry();
      final toOld = <Packet>[];
      final toNew = <Packet>[];
      void oldSink(Packet p) => toOld.add(p);
      void newSink(Packet p) => toNew.add(p);

      // Flutter can build the replacement before disposing of what it
      // replaces, so the late unregister must not remove the newcomer.
      registry.register(id('UU.BGU.HHZ.01'), oldSink);
      registry.register(id('UU.BGU.HHZ.01'), newSink);
      registry.unregister(id('UU.BGU.HHZ.01'), oldSink);

      expect(registry.deliver(packetFor('UU.BGU.HHZ.01')), isTrue);
      expect(toNew, hasLength(1));
      expect(toOld, isEmpty);
    });
  });

  group('the plot window', () {
    const oneSecond = 1000000;
    const timing = PlotTiming(window: Duration(minutes: 2));
    final now = DateTime.now();

    Packet at(int offsetSeconds) => Packet(
      now.microsecondsSinceEpoch + offsetSeconds * oneSecond,
      100.0,
      Float64List.fromList(const [1.0, 2.0, 3.0]),
    );

    bool visible(Packet packet) =>
        isWithinPlotWindow(packet, timing: timing, now: now);

    test('keeps what is on screen', () {
      expect(visible(at(-30)), isTrue);
      expect(visible(at(-1)), isTrue);
      expect(visible(at(-119)), isTrue);
    });

    test('drops what has scrolled off the left hand edge', () {
      // A backlog replayed after a reconnect looks like this
      expect(visible(at(-600)), isFalse);
    });

    test('drops something timestamped absurdly far ahead', () {
      expect(visible(at(3600)), isFalse);
    });

    test('tolerates a little clock skew', () {
      // Clocks never quite agree, and this is good data
      expect(visible(at(5)), isTrue);
    });
  });

  group('MultiStreamPainter', () {
    testWidgets('gives every selected stream a plot', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultiStreamPainter(
              streams: [id('UU.BGU.HHZ.01'), id('UU.ARUT.EHZ.01')],
              packets: const Stream<StreamPacket>.empty(),
            ),
          ),
        ),
      );
      await tester.pump();

      final painters = tester.widgetList<StreamPainter>(
        find.byType(StreamPainter),
      );
      expect(painters, hasLength(2));
      // Every one is live, and none of them holds a connection
      expect(painters.every((p) => p.isLive), isTrue);
    });

    testWidgets('plots are keyed by stream so reordering keeps their data', (
      tester,
    ) async {
      final packets = StreamController<StreamPacket>.broadcast();
      addTearDown(packets.close);
      var streams = [id('UU.BGU.HHZ.01'), id('UU.ARUT.EHZ.01')];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  ElevatedButton(
                    onPressed: () =>
                        setState(() => streams = streams.reversed.toList()),
                    child: const Text('reorder'),
                  ),
                  Expanded(
                    child: MultiStreamPainter(
                      streams: streams,
                      packets: packets.stream,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final before = tester
          .stateList(find.byType(StreamPainter))
          .toList();
      expect(before, hasLength(2));

      await tester.tap(find.text('reorder'));
      await tester.pump();

      final after = tester.stateList(find.byType(StreamPainter)).toList();
      // The same State objects, in the opposite order: Flutter followed the
      // keys rather than the slots, so no plot inherited another's history.
      expect(after.first, same(before.last));
      expect(after.last, same(before.first));
    });

    testWidgets('draws nothing at all with nothing selected', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MultiStreamPainter(streams: <StreamIdentifier>[]),
          ),
        ),
      );
      await tester.pump();

      // Emphatically not invented traces: a moving trace reads as live data,
      // and whoever owns this decides what to show in its place.
      expect(find.byType(StreamPainter), findsNothing);
    });

    testWidgets('routes arriving packets to the right plot', (tester) async {
      final packets = StreamController<StreamPacket>.broadcast();
      addTearDown(packets.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultiStreamPainter(
              streams: [id('UU.BGU.HHZ.01'), id('UU.ARUT.EHZ.01')],
              packets: packets.stream,
            ),
          ),
        ),
      );
      await tester.pump();

      packets.add(packetFor('UU.BGU.HHZ.01', value: 7.0));
      // A packet for a stream that is not plotted must not upset anything
      packets.add(packetFor('UU.NOTPLOTTED.HHZ.01'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
    });
  });
}
