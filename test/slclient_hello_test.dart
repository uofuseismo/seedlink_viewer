@Tags(['live'])
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/native/slclient_bindings_generated.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';

void main() {
  test('hello world: connect → identify → disconnect', () {
    using((arena) {
      final opts = arena<SEEDLinkConnectionOptions>();
      opts.ref.host = 'localhost'.toNativeUtf8(allocator: arena).cast<Char>();
      opts.ref.port = 18000;

      final conn = arena<SEEDLinkConnection>();
      final rc = createConnection(opts, conn);
      expect(rc, 0, reason: 'createConnection failed with $rc');

      final buf = arena<Char>(1026);
      final rc2 = getServerIdentifier(conn, buf);
      expect(rc2, 0, reason: 'getServerIdentifier failed with $rc2');

      // ignore: avoid_print
      print('Server identifier: ${buf.cast<Utf8>().toDartString()}');

      final streams = arena<StreamsList>();
      final rc3 = getStreams(conn, 30000, streams);
      expect(rc3, 0, reason: 'getStreams failed with $rc3');
      expect(
        streams.ref.nStreams,
        greaterThan(0),
        reason: 'the server offered no streams',
      );

      final names = List<String>.generate(
        streams.ref.nStreams,
        (i) => streams.ref.streams[i].cast<Utf8>().toDartString(),
      );
      // Every name should be NET.STA.CHAN.LOC and round trip through the model
      for (final name in names) {
        expect(StreamIdentifier.fromString(name).toString(), name);
      }
      // ignore: avoid_print
      print('Server is offering ${names.length} streams, e.g. ${names.first}');

      freeStreams(streams);
      expect(streams.ref.nStreams, 0);
      expect(streams.ref.streams, nullptr);

      freeConnection(conn);
    });
  });

  test('live bullets: select streams then read real samples', () async {
    // Pick two channels the server is actually carrying, ask for them, and
    // pull samples until some arrive.
    final samples = await using((arena) async {
      final opts = arena<SEEDLinkConnectionOptions>();
      opts.ref.host = 'localhost'.toNativeUtf8(allocator: arena).cast<Char>();
      opts.ref.port = 18000;

      final conn = arena<SEEDLinkConnection>();
      expect(createConnection(opts, conn), 0);

      final offered = arena<StreamsList>();
      expect(getStreams(conn, 30000, offered), 0);
      final names = List<String>.generate(
        offered.ref.nStreams,
        (i) => offered.ref.streams[i].cast<Utf8>().toDartString(),
      );
      freeStreams(offered);
      expect(names, isNotEmpty);

      // Vertical components tend to be the liveliest, so prefer those
      final wanted = names.where((n) => n.contains('HHZ')).take(2).toList();
      expect(wanted, isNotEmpty, reason: 'no HHZ channels on this server');

      final selection = arena<StreamsList>();
      selection.ref.nStreams = wanted.length;
      selection.ref.streams = arena<Pointer<Char>>(wanted.length);
      for (var i = 0; i < wanted.length; i++) {
        selection.ref.streams[i] =
            wanted[i].toNativeUtf8(allocator: arena).cast<Char>();
      }
      expect(modifySelections(conn, selection), 0);

      final collected = <Map<String, Object>>[];
      final giveUp = DateTime.now().add(const Duration(seconds: 40));
      while (collected.isEmpty && DateTime.now().isBefore(giveUp)) {
        final packets = arena<Packets>();
        final rc = getPackets(conn, 16, packets);
        expect(rc, 0, reason: 'getPackets failed with $rc');
        for (var i = 0; i < packets.ref.nPackets; i++) {
          final packet = packets.ref.packets[i];
          collected.add(<String, Object>{
            'name':
                '${packet.network.toDart()}.${packet.station.toDart()}'
                '.${packet.channel.toDart()}.${packet.location.toDart()}',
            'nSamples': packet.nSamples,
            'samplingRate': packet.samplingRate,
            'startTime': packet.startTime,
            'sequenceNumber': packet.sequenceNumber,
            'first': packet.nSamples > 0 ? packet.data[0] : 0.0,
          });
        }
        freePackets(packets);
        expect(packets.ref.nPackets, 0);
        expect(packets.ref.packets, nullptr);
        if (collected.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      freeConnection(conn);
      return collected;
    });

    expect(samples, isNotEmpty, reason: 'no data arrived within 40s');
    // ignore: avoid_print
    print('Read ${samples.length} packets, first: ${samples.first}');

    for (final packet in samples) {
      expect(packet['nSamples'] as int, greaterThan(0));
      expect(packet['samplingRate'] as double, greaterThan(0));
      // Plainly a real epoch time rather than an uninitialised field
      expect(packet['startTime'] as int, greaterThan(0));
      // Stamped from the SEEDLink header, so never left unset
      expect(packet['sequenceNumber'] as int, isNot(-1));
      expect(wantedName(packet['name'] as String), isTrue);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// The names getPackets reports should look like the NET.STA.CHAN.LOC the
/// rest of the app speaks.
bool wantedName(String name) =>
    StreamIdentifier.fromString(name).toString() == name;

extension on Array<Char> {
  /// Reads a fixed width, null padded C string out of a struct field.
  String toDart() {
    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      final byte = this[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }
}
