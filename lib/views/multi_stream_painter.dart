import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../models/stream_identifier.dart';
import '../services/seedlink_packet_reader.dart';
import './stream_painter.dart';
import './stream_registry.dart';

/// A stack of plots fed by a single connection.
class MultiStreamPainter extends StatefulWidget {
  /// Packets from every selected stream, interleaved.
  final Stream<StreamPacket>? packets;

  /// The streams to plot, top to bottom.
  final List<StreamIdentifier> streams;

  const MultiStreamPainter({
    super.key,
    required this.streams,
    this.packets,
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
      // Nothing chosen yet, so show the simulated traces rather than a void
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(
          3,
          (i) => Expanded(
            child: StreamPainter(
              backgroundColor: i.isEven ? Colors.white : Colors.grey,
            ),
          ),
        ),
      );
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
              backgroundColor: i.isEven ? Colors.white : Colors.grey,
            ),
          ),
      ],
    );
  }
}
