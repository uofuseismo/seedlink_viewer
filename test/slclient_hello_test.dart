import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/native/slclient_bindings_generated.dart';

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
      print('Made streams');
      final rc3 = getStreams(conn, streams);
      freeStreams(streams);

      freeConnection(conn);
    });
  });
}
