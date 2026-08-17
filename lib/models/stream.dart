import 'dart:math';
import 'dart:typed_data';
import '../services/logging.dart';
import './packet.dart';
import './stream_identifier.dart';

final _log = Logger('seedlink.stream');

/// Defines a stream (a list of packets with a stream identifier)
class Stream {
  final StreamIdentifier streamIdentifier;
  late List<Packet> packets;
  late int startTimeMuS;
  late int endTimeMuS;

  Stream(this.streamIdentifier, this.packets) {
    _sanitize();
    _findStartAndEndTime();
  }

  void _sanitize() {
    packets = packets.where( (packet) => packet.data.isNotEmpty ).toList();
    packets.sort( (a, b) => a.startTimeMuS.compareTo(b.startTimeMuS) );
  }

  void addPacket(Packet packet, {int maxHistoryMuS = 5 * 60 * 1000000}) {
    if (packet.data.isEmpty) return;
    packets.add(packet);
    if (packets.length > 1) {
      if (packet.startTimeMuS < packets[packets.length - 2].endTimeMuS) {
        packets.sort((a, b) => a.startTimeMuS.compareTo(b.startTimeMuS));
      }
    }
    endTimeMuS = max(endTimeMuS, packet.endTimeMuS);
    final int cutoffMuS = endTimeMuS - maxHistoryMuS;
    packets.removeWhere((p) => p.endTimeMuS < cutoffMuS);
    startTimeMuS = packets.isNotEmpty ? packets.first.startTimeMuS : endTimeMuS;
  }

  void _findStartAndEndTime() {
    if (packets.isNotEmpty) {
      startTimeMuS = packets[0].startTimeMuS;
      startTimeMuS
        = packets.fold<int> ( 
            startTimeMuS, 
            (minTime, packet) => min(minTime, packet.startTimeMuS) 
          );
      endTimeMuS = packets[0].endTimeMuS;
      endTimeMuS = packets.fold<int> (
            endTimeMuS, 
            (maxTime, packet) => max(maxTime, packet.endTimeMuS) 
          );  
    }
    else {
      startTimeMuS = 0;
      endTimeMuS = 0;
    }
  }

  /// The smallest and largest sample in a time window.
  ///
  /// Seeded from the data rather than from zero.  Seismic counts sit on a DC
  /// offset - a channel resting around 30000 never goes near zero - so
  /// starting at zero stretched the range from zero up to the trace and
  /// squashed the signal into a sliver at the edge of the plot.
  ///
  /// A window with no samples in it reports a flat zero range; callers have to
  /// cope with that anyway for a stream that has not received anything yet.
  Float64x2 getMinimumAndMaximumInTimeRange(int t0MuS, int t1MuS) {
    double? minValue;
    double? maxValue;
    for (var packet in packets) {
      try {
         var pMinMax = packet.getMinimumAndMaximumInTimeRange(t0MuS, t1MuS);
         if (pMinMax != null) {
           minValue = (minValue == null) ? pMinMax.x : min(minValue, pMinMax.x);
           maxValue = (maxValue == null) ? pMinMax.y : max(maxValue, pMinMax.y);
         }
      }
      catch (e, stackTrace) {
        // One bad packet must not blank the whole plot, so the range is taken
        // from the rest.  Logged rather than swallowed: a packet that cannot
        // report its own extrema is a decoding bug worth seeing.
        _log.warning(
          'skipping packet ${streamIdentifier.toString()} '
          'starting ${packet.startTimeMuS} when scaling',
          e,
          stackTrace,
        );
      }
    }
    if (minValue == null || maxValue == null) {
      return Float64x2(0, 0);
    }
    return Float64x2(minValue, maxValue);
  }
}

Packet createNextPacket(int startTimeMuS, double samplingRateHz, int durationMuS) {
  final double dtMuS = 1000000.0 / samplingRateHz;
  final int nSamples = (durationMuS / dtMuS).floor();
  final samples = Float64List(nSamples);
  final rng = Random();
  final double amplitude = 50.0 + rng.nextDouble() * 100.0;
  for (var i = 0; i < nSamples; i++) {
    samples[i] = amplitude * (2 * rng.nextDouble() - 1);
  }
  return Packet(startTimeMuS, samplingRateHz, samples);
}

Stream createRandomStream() {
  final int timeWindowMicroSeconds = 120*1000000;
  final double samplingRateHz = 100;
  final double dtMicroSeconds = 1000000/samplingRateHz;
  final int nSamples = (timeWindowMicroSeconds/dtMicroSeconds).floor() + 1;

  final currentTime = DateTime.now();
  final endTimeMicroSeconds = currentTime.microsecondsSinceEpoch - 10000000;
  //final endTime = DateTime.fromMicrosecondsSinceEpoch(endTimeMicroSeconds);
  final startTimeMicroSeconds = endTimeMicroSeconds - timeWindowMicroSeconds;
  //final startTime = DateTime.fromMicrosecondsSinceEpoch(startTimeMicroSeconds);

  var packets = <Packet> [];
  var rng = Random();
  var i = 0;
  while (i < nSamples) {
    int nSamples = rng.nextInt(500);
    var samples = Float64List(nSamples);
    var packetStartTime = startTimeMicroSeconds + i*dtMicroSeconds;
    for (var s = 0; s < nSamples; s++) {
      // Value >= 0 and < 1 
      samples[s] = 100*(2*rng.nextDouble() - 1);
      i = i + 1;
    }
    var packet = Packet(packetStartTime.round(), samplingRateHz, samples);
    packets.add(packet);
  }

  final streamIdentifier = StreamIdentifier("UU", "CWU", "HHZ", "01");
  return Stream(streamIdentifier, packets);
}
