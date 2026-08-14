import '../models/packet.dart';
import '../models/stream_identifier.dart';
import '../services/seedlink_packet_reader.dart';

/// Receives the packets belonging to one stream.
typedef PacketSink = void Function(Packet packet);

/// Routes packets from one connection to the plot that wants them.
///
/// getPackets consumes packets from the connection, so exactly one caller may
/// read it - if every plot polled for itself they would take each other's
/// data, and a plot per connection would mean negotiating a selection each.
/// One reader pulls, and this hands each packet to whichever plot registered
/// for that stream.
class StreamRegistry {
  final Map<String, PacketSink> _sinks = <String, PacketSink>{};

  /// Streams currently expecting packets.  Exposed for tests and diagnostics.
  Iterable<String> get registered => _sinks.keys;

  void register(StreamIdentifier identifier, PacketSink sink) {
    _sinks[identifier.toString()] = sink;
  }

  /// Stops delivering to [sink].
  ///
  /// The sink is checked rather than just the name because a replacement plot
  /// can register before the one it replaces is disposed of, and a blind
  /// remove would then delete the new registration.
  void unregister(StreamIdentifier identifier, PacketSink sink) {
    final key = identifier.toString();
    if (identical(_sinks[key], sink)) {
      _sinks.remove(key);
    }
  }

  /// Delivers a packet.  False means nothing was listening for that stream.
  ///
  /// Packets for unregistered streams are expected rather than exceptional:
  /// after a selection changes the streams that were dropped keep draining
  /// for a moment.
  bool deliver(StreamPacket packet) {
    final sink = _sinks[packet.identifier.toString()];
    if (sink == null) {
      return false;
    }
    sink(packet.packet);
    return true;
  }
}
