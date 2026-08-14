import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/native/slclient_bindings_generated.dart'
    as native;
import 'package:waveform_viewer/services/seedlink_packet_reader.dart';

/// Fills a fixed width native code field.
void writeCode(Array<Char> field, String value) {
  for (var i = 0; i < value.length; i++) {
    field[i] = value.codeUnitAt(i);
  }
}

/// Builds a native packet by hand so the conversion can be exercised without
/// a server.
Pointer<native.Packet> makePacket(
  Arena arena, {
  String network = 'UU',
  String station = 'BGU',
  String channel = 'HHZ',
  String location = '01',
  int startTimeNanoSeconds = 1786735197038394112,
  double samplingRate = 100.0,
  List<double> samples = const [1.0, 2.0, 3.0],
  int sequenceNumber = 19357714,
}) {
  final packet = arena<native.Packet>();
  writeCode(packet.ref.network, network);
  writeCode(packet.ref.station, station);
  writeCode(packet.ref.channel, channel);
  writeCode(packet.ref.location, location);
  packet.ref.startTime = startTimeNanoSeconds;
  packet.ref.samplingRate = samplingRate;
  packet.ref.nSamples = samples.length;
  packet.ref.sequenceNumber = sequenceNumber;
  final data = arena<Double>(samples.isEmpty ? 1 : samples.length);
  for (var i = 0; i < samples.length; i++) {
    data[i] = samples[i];
  }
  packet.ref.data = data;
  return packet;
}

void main() {
  group('readSeedCode', () {
    test('stops at the null padding', () {
      using((arena) {
        final packet = makePacket(arena, station: 'BGU');
        expect(readSeedCode(packet.ref.station), 'BGU');
      });
    });

    test('reads a code that fills the field', () {
      using((arena) {
        // NETWORK_SIZE is 8, so seven characters plus the terminator
        final packet = makePacket(arena, station: 'ABCDEFG');
        expect(readSeedCode(packet.ref.station), 'ABCDEFG');
      });
    });
  });

  group('toStreamPacket', () {
    test('carries the identifier across', () {
      using((arena) {
        final converted = toStreamPacket(makePacket(arena).ref);
        expect(converted.identifier.toString(), 'UU.BGU.HHZ.01');
        expect(converted.sequenceNumber, 19357714);
      });
    });

    test('converts nanoseconds to the microseconds the model wants', () {
      using((arena) {
        // A time the native side would report, in nanoseconds
        const nanoSeconds = 1786735197038394112;
        final converted = toStreamPacket(
          makePacket(arena, startTimeNanoSeconds: nanoSeconds).ref,
        );

        expect(converted.packet.startTimeMuS, nanoSeconds ~/ 1000);
        // Left in nanoseconds this would land about 56,000 years hence
        final when = DateTime.fromMicrosecondsSinceEpoch(
          converted.packet.startTimeMuS,
        );
        expect(when.year, 2026);
      });
    });

    test('derives a sane end time from the sample count', () {
      using((arena) {
        final converted = toStreamPacket(
          makePacket(
            arena,
            samplingRate: 100.0,
            samples: List<double>.filled(113, 0),
          ).ref,
        );
        final packet = converted.packet;
        // 112 intervals at 100 Hz is 1.12 s
        expect(packet.endTimeMuS - packet.startTimeMuS, 1120000);
      });
    });

    test('copies the samples out of native memory', () {
      using((arena) {
        final packet = makePacket(arena, samples: [1.0, 2.0, 3.0]);
        final converted = toStreamPacket(packet.ref);

        expect(converted.packet.data, [1.0, 2.0, 3.0]);

        // The native block is freed right after conversion, so the model must
        // own its samples rather than pointing into that memory.
        packet.ref.data[0] = 99.0;
        expect(
          converted.packet.data[0],
          1.0,
          reason: 'the samples are still referencing native memory',
        );
      });
    });

    test('carries the minimum and maximum the model computes', () {
      using((arena) {
        final converted = toStreamPacket(
          makePacket(arena, samples: [-5.0, 3.0, 11.0]).ref,
        );
        expect(converted.packet.minimumValue, -5.0);
        expect(converted.packet.maximumValue, 11.0);
      });
    });

    test('handles an empty location code', () {
      using((arena) {
        final converted = toStreamPacket(makePacket(arena, location: '').ref);
        // The model writes an absent location as --
        expect(converted.identifier.toString(), 'UU.BGU.HHZ.--');
      });
    });
  });
}
