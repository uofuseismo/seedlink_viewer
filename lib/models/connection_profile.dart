import 'package:collection/collection.dart' show ListEquality;
import './stream_identifier.dart';

/// The default SEEDLink port for an unencrypted connection.
const int defaultSeedLinkPort = 18000;

/// The default SEEDLink port for a TLS connection - libslink's SL_SECURE_PORT.
const int defaultSecureSeedLinkPort = 18500;

/// What a saved selection looks like once it has been checked against the
/// streams a server is actually offering.
class StreamReconciliation {
  /// The saved streams the server still offers, in the saved plot order.
  final List<StreamIdentifier> kept;

  /// The saved streams the server no longer offers.  These are dropped rather
  /// than remembered - the user can add them again if they come back.
  final List<StreamIdentifier> dropped;

  const StreamReconciliation({required this.kept, required this.dropped});

  bool get droppedAnything => dropped.isNotEmpty;
}

/// A saved SEEDLink server along with the streams last viewed on it.
///
/// Profiles carry their stream selection so that connecting restores what the
/// user was looking at, in the order they were plotting it.
class ConnectionProfile {
  /// Identifies the profile, and is what the Connection menu lists.
  final String name;
  final String host;
  final int port;
  final bool useTLS;

  /// Path to a CA certificate, or empty for the system defaults.  Carried but
  /// not yet applied - see the note on SEEDLinkConnectionOptions.
  final String certificatePath;

  /// The streams last viewed, in plot order.  Top of the list plots at the top
  /// of the window.
  final List<StreamIdentifier> streams;

  ConnectionProfile({
    required this.name,
    required this.host,
    this.port = defaultSeedLinkPort,
    this.useTLS = false,
    this.certificatePath = '',
    List<StreamIdentifier> streams = const <StreamIdentifier>[],
  }) : streams = List<StreamIdentifier>.unmodifiable(streams) {
    if (name.trim().isEmpty) {
      throw const FormatException('A profile needs a name');
    }
    if (host.trim().isEmpty) {
      throw const FormatException('A profile needs a host');
    }
    if (port < 1 || port > 65535) {
      throw FormatException('Port $port is outside 1-65535');
    }
  }

  /// The address as SEEDLink spells it, and the name a profile takes when the
  /// user does not supply one.
  String get address => '$host:$port';

  /// Drops the saved streams this server is no longer offering.
  ///
  /// The kept streams stay in their saved plot order with the gaps closed, so
  /// reconnecting to a server that has lost a station leaves the remaining
  /// plots in the arrangement the user set up.
  StreamReconciliation reconcile(Iterable<StreamIdentifier> available) {
    final offered = available.toSet();
    final kept = <StreamIdentifier>[];
    final dropped = <StreamIdentifier>[];
    for (final stream in streams) {
      (offered.contains(stream) ? kept : dropped).add(stream);
    }
    return StreamReconciliation(kept: kept, dropped: dropped);
  }

  ConnectionProfile copyWith({
    String? name,
    String? host,
    int? port,
    bool? useTLS,
    String? certificatePath,
    List<StreamIdentifier>? streams,
  }) {
    return ConnectionProfile(
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      useTLS: useTLS ?? this.useTLS,
      certificatePath: certificatePath ?? this.certificatePath,
      streams: streams ?? this.streams,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'host': host,
      'port': port,
      'useTLS': useTLS,
      'certificatePath': certificatePath,
      'streams': streams.map((stream) => stream.toString()).toList(),
    };
  }

  /// Rebuilds a profile written by [toJson].
  ///
  /// Throws a [FormatException] if the entry is not something we wrote - the
  /// caller is better placed to decide whether to warn or to start over than
  /// this is to guess at what was meant.
  factory ConnectionProfile.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final host = json['host'];
    final port = json['port'];
    if (name is! String || host is! String || port is! int) {
      throw const FormatException(
        'A profile needs a string name, a string host and an integer port',
      );
    }
    final useTLS = json['useTLS'] ?? false;
    if (useTLS is! bool) {
      throw const FormatException('useTLS must be a boolean');
    }
    final certificatePath = json['certificatePath'] ?? '';
    if (certificatePath is! String) {
      throw const FormatException('certificatePath must be a string');
    }
    final streams = json['streams'] ?? const <Object?>[];
    if (streams is! List) {
      throw const FormatException('streams must be a list');
    }
    return ConnectionProfile(
      name: name,
      host: host,
      port: port,
      useTLS: useTLS,
      certificatePath: certificatePath,
      streams: streams.map((stream) {
        if (stream is! String) {
          throw const FormatException('Each stream must be a string');
        }
        return StreamIdentifier.fromString(stream);
      }).toList(),
    );
  }

  @override
  String toString() => '$name ($address)';

  @override
  bool operator ==(Object other) {
    return other is ConnectionProfile &&
        other.name == name &&
        other.host == host &&
        other.port == port &&
        other.useTLS == useTLS &&
        other.certificatePath == certificatePath &&
        const ListEquality<StreamIdentifier>().equals(other.streams, streams);
  }

  @override
  int get hashCode => Object.hash(
    name,
    host,
    port,
    useTLS,
    certificatePath,
    Object.hashAll(streams),
  );
}
