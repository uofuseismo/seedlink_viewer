import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/native/slclient_bindings_generated.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';

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
      final rc3 = getStreams(conn, streams);
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
}
