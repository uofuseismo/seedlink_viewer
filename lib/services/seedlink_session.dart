import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import '../models/stream_identifier.dart';
import '../native/slclient_bindings_generated.dart' as native;
import './stream_source.dart';

/// Talking to a SEEDLink server means synchronous FFI calls that can sit for
/// seconds - getStreams alone waits up to ten for the server to answer. Doing
/// that on the UI isolate would freeze the app, and awaiting it would not help
/// because the native call never yields. Everything here therefore runs on a
/// short lived helper isolate, which owns its connection for its whole life
/// and hands back plain dart values.
///
/// A connection is deliberately not shared between these calls: libslink's
/// SLCD is not thread safe, and INFO requests pull packets off the wire, so a
/// query would eat data from a connection that was streaming.

/// Asks a server who it is.  Returns the server identifier - "RM106" from a
/// ringserver - or throws if it cannot be reached.
Future<String> pingSeedLinkServer({
  required String host,
  required int port,
  bool useTLS = false,
  String certificatePath = '',
}) {
  return Isolate.run(() => _ping(host, port, useTLS, certificatePath));
}

String _ping(String host, int port, bool useTLS, String certificatePath) {
  return _withConnection(host, port, useTLS, certificatePath, (connection) {
    return using((arena) {
      final buffer = arena<Char>(1026);
      if (native.getServerIdentifier(connection, buffer) != 0) {
        throw StreamSourceException('No answer from $host:$port');
      }
      final identifier = buffer.cast<Utf8>().toDartString().trim();
      return identifier.isEmpty ? 'Connected' : identifier;
    });
  });
}

/// The streams a live SEEDLink server is currently offering.
class SeedLinkStreamSource implements StreamSource {
  final String host;
  final int port;
  final bool useTLS;

  /// A CA certificate directory or bundle, or empty for the system store.
  final String certificatePath;

  const SeedLinkStreamSource({
    required this.host,
    required this.port,
    this.useTLS = false,
    this.certificatePath = '',
  });

  @override
  String get description => '$host:$port';

  @override
  Future<List<StreamIdentifier>> fetchStreams() {
    final host = this.host;
    final port = this.port;
    final useTLS = this.useTLS;
    final certificatePath = this.certificatePath;
    return Isolate.run(
      () => _fetchStreams(host, port, useTLS, certificatePath),
    );
  }
}

List<StreamIdentifier> _fetchStreams(
  String host,
  int port,
  bool useTLS,
  String certificatePath,
) {
  return _withConnection(host, port, useTLS, certificatePath, (connection) {
    return using((arena) {
      final streams = arena<native.StreamsList>();
      final code = native.getStreams(connection, streams);
      if (code != 0) {
        throw StreamSourceException(
          'Could not read the stream list from $host:$port (error $code)',
        );
      }
      try {
        return List<StreamIdentifier>.generate(
          streams.ref.nStreams,
          (i) => StreamIdentifier.fromString(
            streams.ref.streams[i].cast<Utf8>().toDartString(),
          ),
        );
      } finally {
        native.freeStreams(streams);
      }
    });
  });
}

/// Copies the certificate path into the fixed width field the native side
/// expects.  An empty path is left as the zeroes the arena already wrote,
/// which the native side reads as "use the system certificates".
void _writeCertificatePath(
  Pointer<native.SEEDLinkConnectionOptions> options,
  String certificatePath,
) {
  if (certificatePath.isEmpty) {
    return;
  }
  final bytes = utf8.encode(certificatePath);
  // One short of the field, so the terminating null always survives.  The
  // size is asked for rather than assumed: it differs per platform.
  final limit = native.getCertificatePathSize();
  if (bytes.length >= limit) {
    throw StreamSourceException(
      'The certificate path is longer than ${limit - 1} bytes',
    );
  }
  for (var i = 0; i < bytes.length; i++) {
    options.ref.certificatePath[i] = bytes[i];
  }
}

/// Opens a connection, hands it to [body], and always closes it again.
///
/// createConnection allocates the SLCD before it can fail, so the connection
/// is released even on the error paths.
T _withConnection<T>(
  String host,
  int port,
  bool useTLS,
  String certificatePath,
  T Function(Pointer<native.SEEDLinkConnection>) body,
) {
  return using((arena) {
    final options = arena<native.SEEDLinkConnectionOptions>();
    options.ref.host = host.toNativeUtf8(allocator: arena).cast<Char>();
    options.ref.port = port;
    options.ref.useTLS = useTLS;
    _writeCertificatePath(options, certificatePath);

    final connection = arena<native.SEEDLinkConnection>();
    final code = native.createConnection(options, connection);
    try {
      if (code != 0) {
        throw StreamSourceException(
          'Could not open a connection to $host:$port (error $code)',
        );
      }
      return body(connection);
    } finally {
      native.freeConnection(connection);
    }
  });
}
