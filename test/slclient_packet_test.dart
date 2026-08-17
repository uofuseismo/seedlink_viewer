import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/native/slclient_bindings_generated.dart';

void main() {
  group('native Packet', () {
    test('freePacket clears the sequence number', () {
      using((arena) {
        final packet = arena<Packet>();
        packet.ref.data = nullptr;
        packet.ref.nSamples = 0;
        packet.ref.sequenceNumber = 12345;

        freePacket(packet);

        // The native side resets this to UNSET_SEQUENCE_NUMBER (UINT64_MAX).
        // Dart integers are signed so that arrives as -1 rather than a huge
        // positive number - anything tracking sequence numbers to resume a
        // connection has to treat -1, not 0, as "no position yet".
        expect(packet.ref.sequenceNumber, -1);
        expect(packet.ref.nSamples, 0);
      });
    });
  });
}
