import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../models/packet.dart';
import '../models/plot_timing.dart';
import '../models/stream_identifier.dart';
import '../services/seedlink_packet_reader.dart';
import './stream_painter.dart';
import './stream_registry.dart';

/// Whether a packet has anything to contribute to a plot window ending now.
///
/// Anything older than the window has already scrolled off the left hand edge
/// - a backlog replayed after a reconnect arrives like this - and anything
/// implausibly far ahead is a clock problem rather than data. Server and
/// client clocks never quite agree, so a little slack avoids throwing away
/// good packets.
bool isWithinPlotWindow(
  Packet packet, {
  required PlotTiming timing,
  DateTime? now,
}) {
  final nowMuS = (now ?? DateTime.now()).microsecondsSinceEpoch;
  final windowStartMuS = nowMuS - timing.window.inMicroseconds;
  final latestSensibleMuS = nowMuS + timing.clockSlack.inMicroseconds;
  return packet.endTimeMuS >= windowStartMuS &&
      packet.startTimeMuS <= latestSensibleMuS;
}

/// A stack of plots fed by a single connection.
class MultiStreamPainter extends StatefulWidget {
  /// Packets from every selected stream, interleaved.
  final Stream<StreamPacket>? packets;

  /// The streams to plot, top to bottom.
  final List<StreamIdentifier> streams;

  /// Every duration the plots run on, handed down from above rather than
  /// decided here, so one setting governs the whole stack.
  final PlotTiming timing;

  const MultiStreamPainter({
    super.key,
    required this.streams,
    this.packets,
    this.timing = const PlotTiming(),
  });

  @override
  State<MultiStreamPainter> createState() => _MultiStreamPainterState();
}

class _MultiStreamPainterState extends State<MultiStreamPainter> {
  final StreamRegistry _registry = StreamRegistry();
  StreamSubscription<StreamPacket>? _subscription;

  /// Packets that arrived for a stream nothing is plotting.  Worth counting -
  /// a number that climbs steadily means the selection and the plots have got
  /// out of step.
  int undeliveredPackets = 0;

  /// Packets that fell outside the plot window.  A backlog replayed after a
  /// reconnect lands here rather than being drawn off the edge.
  int expiredPackets = 0;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(MultiStreamPainter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packets != widget.packets) {
      _listen();
    }
  }

  void _listen() {
    _subscription?.cancel();
    _subscription = widget.packets?.listen((packet) {
      // Judged here, once, because the container owns the window. Passing a
      // packet on that cannot be drawn only costs the plot a rescale.
      if (!isWithinPlotWindow(packet.packet, timing: widget.timing)) {
        expiredPackets++;
        return;
      }
      if (!_registry.deliver(packet)) {
        undeliveredPackets++;
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.streams.isEmpty) {
      // Nothing to plot. Deliberately empty rather than filled with invented
      // traces - whoever owns this decides what to show instead.
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.streams.length; i++)
          // Keyed by stream, not by position: the plot order is rearrangeable,
          // and without this a drag would throw away each plot's buffered
          // history and hand the empty replacement to a different stream.
          //
          // The key belongs on the outermost widget in this list. On the
          // StreamPainter inside it the Column would still be matching
          // unkeyed Expandeds by position, and the keys below them would only
          // force a rebuild rather than a move.
          Expanded(
            key: ValueKey<String>(widget.streams[i].toString()),
            child: StreamPainter(
              identifier: widget.streams[i],
              registry: _registry,
              timing: widget.timing,
              backgroundColor: i.isEven ? Colors.white : Colors.grey,
            ),
          ),
      ],
    );
  }
}
