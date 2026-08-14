import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../models/packet.dart';
import '../models/stream_identifier.dart';
import '../native/slclient_bindings_generated.dart' as native;
import './seedlink_session.dart' show writeCertificatePath;
import './stream_source.dart';

/// The SEED codes in the native Packet are all this wide - NETWORK_SIZE and
/// friends in slclient.hpp.  Spelled out because the generated bindings carry
/// no macros; unlike the certificate path these do not vary by platform.
const int _seedCodeSize = 8;

/// A packet together with the stream it belongs to.
///
/// Packets arrive interleaved from every selected stream, so the identifier
/// has to travel with the samples for the plots to sort them out.
class StreamPacket {
  final StreamIdentifier identifier;
  final Packet packet;

  /// The SEEDLink sequence number this arrived under.  Keeping the newest per
  /// station is what lets a rebuilt connection resume rather than leave a gap.
  final int sequenceNumber;

  const StreamPacket({
    required this.identifier,
    required this.packet,
    required this.sequenceNumber,
  });
}

/// Reads a fixed width, null padded code out of a native struct field.
String readSeedCode(Array<Char> field) {
  final bytes = <int>[];
  for (var i = 0; i < _seedCodeSize; i++) {
    final byte = field[i];
    if (byte == 0) {
      break;
    }
    bytes.add(byte);
  }
  return String.fromCharCodes(bytes);
}

/// Copies one native packet into the dart model.
///
/// The samples are copied rather than referenced: the native buffer belongs to
/// the Packets block and stops existing the moment freePackets is called, so
/// anything that outlives that call has to own its own memory.
///
/// N.B. the native side keeps nanoseconds and the dart model keeps
/// microseconds.
StreamPacket toStreamPacket(native.Packet source) {
  final samples = Float64List(source.nSamples);
  for (var i = 0; i < source.nSamples; i++) {
    samples[i] = source.data[i];
  }
  return StreamPacket(
    identifier: StreamIdentifier(
      readSeedCode(source.network),
      readSeedCode(source.station),
      readSeedCode(source.channel),
      readSeedCode(source.location),
    ),
    packet: Packet(source.startTime ~/ 1000, source.samplingRate, samples),
    sequenceNumber: source.sequenceNumber,
  );
}

/// Drains one batch from a connection, always releasing the native block.
///
/// Returns an empty list when the server had nothing waiting, which on a
/// non-blocking connection is most of the time.
List<StreamPacket> drainPackets(
  Pointer<native.SEEDLinkConnection> connection, {
  int maxPackets = 64,
}) {
  return using((arena) {
    final packets = arena<native.Packets>();
    final code = native.getPackets(connection, maxPackets, packets);
    if (code != 0) {
      throw StreamSourceException('Could not read packets (error $code)');
    }
    try {
      return List<StreamPacket>.generate(
        packets.ref.nPackets,
        (i) => toStreamPacket(packets.ref.packets[i]),
      );
    } finally {
      // Always, including if a conversion throws part way through - the
      // samples belong to the native side until this runs.
      native.freePackets(packets);
    }
  });
}

/// Commands the reader isolate understands.  Kept as plain values so they can
/// cross the isolate boundary.
enum _Command { setStreams, stop }

/// Reads packets from a SEEDLink server on a helper isolate.
///
/// Unlike the one-shot queries in seedlink_session.dart this holds its
/// connection open, because a stream selection only survives for as long as
/// the connection it was negotiated on.
class SeedLinkPacketReader {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _incoming;
  final StreamController<StreamPacket> _packets;
  bool _stopped = false;

  SeedLinkPacketReader._(
    this._isolate,
    this._commands,
    this._incoming,
    this._packets,
  );

  /// Packets as they arrive, from every selected stream interleaved.
  Stream<StreamPacket> get packets => _packets.stream;

  /// Opens a connection and starts reading the given streams.
  static Future<SeedLinkPacketReader> start({
    required String host,
    required int port,
    bool useTLS = false,
    String certificatePath = '',
    List<StreamIdentifier> streams = const <StreamIdentifier>[],
    Duration pollInterval = const Duration(milliseconds: 200),
    /// Heartbeat interval.  libslink drops a connection idle for ten minutes,
    /// which a quiet station would otherwise hit routinely.
    Duration keepAlive = const Duration(seconds: 30),
  }) async {
    final incoming = ReceivePort();
    final isolate = await Isolate.spawn(
      _run,
      _Startup(
        reply: incoming.sendPort,
        host: host,
        port: port,
        useTLS: useTLS,
        certificatePath: certificatePath,
        streams: streams.map((s) => s.toString()).toList(),
        pollIntervalMs: pollInterval.inMilliseconds,
        keepAliveSeconds: keepAlive.inSeconds,
      ),
      debugName: 'seedlink-$host:$port',
    );

    final controller = StreamController<StreamPacket>.broadcast();
    final ready = Completer<SendPort>();
    incoming.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List<StreamPacket>) {
        for (final packet in message) {
          if (!controller.isClosed) {
            controller.add(packet);
          }
        }
      } else if (message is String) {
        // The isolate could not carry on - surface it rather than going quiet.
        if (!controller.isClosed) {
          controller.addError(StreamSourceException(message));
        }
      }
    });

    final commands = await ready.future;
    return SeedLinkPacketReader._(isolate, commands, incoming, controller);
  }

  /// Points the connection at a different set of streams.
  ///
  /// SEEDLink can only negotiate a selection while connecting, so the reader
  /// rebuilds its connection - expect a short gap in the data.
  void setStreams(List<StreamIdentifier> streams) {
    if (_stopped) {
      return;
    }
    _commands.send([
      _Command.setStreams,
      streams.map((s) => s.toString()).toList(),
    ]);
  }

  /// Closes the connection and shuts the isolate down.
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _commands.send([_Command.stop]);
    // Give the isolate a moment to close its connection tidily before it is
    // killed, so libslink can say goodbye to the server.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _isolate.kill(priority: Isolate.immediate);
    _incoming.close();
    await _packets.close();
  }
}

/// Everything the reader isolate needs to get going.  All plain values.
class _Startup {
  final SendPort reply;
  final String host;
  final int port;
  final bool useTLS;
  final String certificatePath;
  final List<String> streams;
  final int pollIntervalMs;
  final int keepAliveSeconds;

  const _Startup({
    required this.reply,
    required this.host,
    required this.port,
    required this.useTLS,
    required this.certificatePath,
    required this.streams,
    required this.pollIntervalMs,
    required this.keepAliveSeconds,
  });
}

/// The reader isolate: owns one connection for its whole life.
Future<void> _run(_Startup startup) async {
  final commands = ReceivePort();
  startup.reply.send(commands.sendPort);

  var wanted = List<String>.of(startup.streams);
  var selectionChanged = true;
  var stopping = false;

  commands.listen((message) {
    if (message is! List || message.isEmpty) {
      return;
    }
    switch (message.first) {
      case _Command.setStreams:
        wanted = List<String>.of((message[1] as List).cast<String>());
        selectionChanged = true;
      case _Command.stop:
        stopping = true;
    }
  });

  final arena = Arena();
  Pointer<native.SEEDLinkConnection>? connection;

  void closeConnection() {
    if (connection != null) {
      native.freeConnection(connection!);
      connection = null;
    }
  }

  try {
    final options = arena<native.SEEDLinkConnectionOptions>();
    options.ref.host = startup.host.toNativeUtf8(allocator: arena).cast<Char>();
    options.ref.port = startup.port;
    options.ref.useTLS = startup.useTLS;
    // This connection is held open for as long as the user is watching, so it
    // needs a heartbeat to survive quiet spells.
    options.ref.keepAliveSeconds = startup.keepAliveSeconds;
    writeCertificatePath(options, startup.certificatePath);

    while (!stopping) {
      if (connection == null) {
        final fresh = arena<native.SEEDLinkConnection>();
        if (native.createConnection(options, fresh) != 0) {
          startup.reply.send(
            'Could not connect to ${startup.host}:${startup.port}',
          );
          return;
        }
        connection = fresh;
        selectionChanged = true;
      }
      if (selectionChanged) {
        selectionChanged = false;
        if (!_applySelection(connection!, wanted, arena)) {
          startup.reply.send('Could not select streams');
          return;
        }
      }
      List<StreamPacket> batch;
      try {
        batch = drainPackets(connection!);
      } on StreamSourceException catch (e) {
        // A terminate means the server wants us to reconnect, which the next
        // turn of the loop does by itself.
        startup.reply.send('$e');
        closeConnection();
        await Future<void>.delayed(
          Duration(milliseconds: startup.pollIntervalMs),
        );
        continue;
      }
      if (batch.isNotEmpty) {
        startup.reply.send(batch);
      }
      // Yielding here is what lets commands sent while we were inside the
      // native call actually be delivered.
      await Future<void>.delayed(
        Duration(milliseconds: startup.pollIntervalMs),
      );
    }
  } finally {
    closeConnection();
    arena.releaseAll();
    commands.close();
  }
}

/// Applies a stream selection, rebuilding the connection as SEEDLink requires.
bool _applySelection(
  Pointer<native.SEEDLinkConnection> connection,
  List<String> streams,
  Arena arena,
) {
  final selection = arena<native.StreamsList>();
  final names = arena<Pointer<Char>>(streams.isEmpty ? 1 : streams.length);
  for (var i = 0; i < streams.length; i++) {
    names[i] = streams[i].toNativeUtf8(allocator: arena).cast<Char>();
  }
  selection.ref.streams = names;
  selection.ref.nStreams = streams.length;
  return native.modifySelections(connection, selection) == 0;
}
