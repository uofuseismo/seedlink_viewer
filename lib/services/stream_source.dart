import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/stream_identifier.dart';
import '../native/slclient_bindings_generated.dart' as native;

/// Where the stream selector gets its list of streams.
///
/// Querying a real server takes long enough to be worth showing progress for,
/// so this is always asynchronous even when the answer is already to hand.
abstract class StreamSource {
  /// Names the server being queried.  Shown while the query is running.
  String get description;

  /// The streams the server is currently offering.
  Future<List<StreamIdentifier>> fetchStreams();
}

/// Turns a SEEDLink INFO STREAMS response into stream identifiers.
///
/// The parsing itself is done by the native parseStreamsResponse so that the
/// canned data and a real server travel exactly the same code path.
List<StreamIdentifier> parseStreamsResponse(String response) {
  return using((arena) {
    final streams = arena<native.StreamsList>();
    final code = native.parseStreamsResponse(
      response.toNativeUtf8(allocator: arena).cast<Char>(),
      streams,
    );
    if (code != 0) {
      throw StreamSourceException(
        'Could not read the stream list (error $code)',
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
}

/// A stand-in for a real SEEDLink server that replays a captured INFO STREAMS
/// response.  Lets the selector be built and exercised before getStreams is
/// wired up to a live connection.
class SampleStreamSource implements StreamSource {
  /// A pause so the progress frame is actually visible during development.
  final Duration delay;

  const SampleStreamSource({this.delay = const Duration(milliseconds: 100)});

  @override
  String get description => 'localhost:18000 (sample data)';

  @override
  Future<List<StreamIdentifier>> fetchStreams() async {
    await Future<void>.delayed(delay);
    final response = await rootBundle.loadString('test/data/streams.json');
    return parseStreamsResponse(response);
  }
}

/// Something went wrong getting the stream list.
class StreamSourceException implements Exception {
  final String message;
  const StreamSourceException(this.message);
  @override
  String toString() => message;
}
