import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waveform_viewer/models/packet.dart';
import 'package:waveform_viewer/models/plot_timing.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';
import 'package:waveform_viewer/services/seedlink_packet_reader.dart';
import 'package:waveform_viewer/views/multi_stream_painter.dart';
import 'package:waveform_viewer/views/stream_painter.dart';

void main() {
  group('PlotTiming', () {
    test('keeps more history than it shows', () {
      const timing = PlotTiming(window: Duration(minutes: 2));
      expect(timing.history, greaterThan(timing.window));
    });

    test('the history follows the window', () {
      // The point of holding these together: widening the window must not
      // leave the buffer behind, or the trace would be trimmed by the buffer
      // and look like a station that stopped sending.
      const short = PlotTiming(window: Duration(minutes: 2));
      final long = short.withWindow(const Duration(minutes: 30));

      expect(long.window, const Duration(minutes: 30));
      expect(long.history, greaterThanOrEqualTo(long.window));
    });

    test('a deliberately short history is never shorter than the window', () {
      const timing = PlotTiming(
        window: Duration(minutes: 10),
        history: Duration(minutes: 1),
      );
      // Asking for less than the window is a mistake, not an instruction
      expect(timing.history, timing.window);
    });

    test('a deliberate history is respected and survives a window change', () {
      const timing = PlotTiming(
        window: Duration(minutes: 2),
        history: Duration(hours: 1),
      );
      expect(timing.history, const Duration(hours: 1));
      expect(timing.withWindow(const Duration(minutes: 5)).history,
          const Duration(hours: 1));
    });

    test('values with the same settings compare equal', () {
      expect(const PlotTiming(), const PlotTiming());
      expect(
        const PlotTiming(window: Duration(minutes: 5)),
        isNot(const PlotTiming(window: Duration(minutes: 2))),
      );
    });
  });

  group('the timing reaches the bottom of the stack', () {
    testWidgets('a window set at the top governs the plots', (tester) async {
      const timing = PlotTiming(window: Duration(minutes: 17));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultiStreamPainter(
              streams: [StreamIdentifier.fromString('UU.BGU.HHZ.01')],
              packets: const Stream<StreamPacket>.empty(),
              timing: timing,
            ),
          ),
        ),
      );
      await tester.pump();

      final painter = tester.widget<StreamPainter>(find.byType(StreamPainter));
      expect(painter.timing.window, const Duration(minutes: 17));
      // ... and the buffer came along with it
      expect(painter.timing.history, greaterThanOrEqualTo(painter.timing.window));
    });

    testWidgets('every plot in a stack gets the same timing', (tester) async {
      const timing = PlotTiming(window: Duration(minutes: 9));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MultiStreamPainter(
              streams: [
                StreamIdentifier.fromString('UU.BGU.HHZ.01'),
                StreamIdentifier.fromString('UU.ARUT.EHZ.01'),
              ],
              packets: const Stream<StreamPacket>.empty(),
              timing: timing,
            ),
          ),
        ),
      );
      await tester.pump();

      final painters = tester.widgetList<StreamPainter>(
        find.byType(StreamPainter),
      );
      expect(painters, hasLength(2));
      expect(
        painters.every((p) => p.timing.window == const Duration(minutes: 9)),
        isTrue,
      );
    });

    testWidgets('the window governs which packets get through', (tester) async {
      // A ten minute window should accept a packet five minutes old that the
      // default two minute window would have discarded.
      final fiveMinutesAgo = Packet(
        DateTime.now().microsecondsSinceEpoch - 300 * 1000000,
        100.0,
        Float64List.fromList(const [1.0, 2.0, 3.0]),
      );

      expect(
        isWithinPlotWindow(
          fiveMinutesAgo,
          timing: const PlotTiming(window: Duration(minutes: 2)),
        ),
        isFalse,
      );
      expect(
        isWithinPlotWindow(
          fiveMinutesAgo,
          timing: const PlotTiming(window: Duration(minutes: 10)),
        ),
        isTrue,
      );
    });
  });
}
