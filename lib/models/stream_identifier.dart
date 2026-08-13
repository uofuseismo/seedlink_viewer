/// Capitalizes and removes all spaces from a string.
String capitalizeAndRemoveBlanks(String input) {
  return input.toUpperCase().replaceAll(' ', '');
}

/// Defines a stream's name.
class StreamIdentifier {
  late String network;      /// The network code - e.g., UU
  late String station;      /// The station code - e.g., CTU
  late String channel;      /// The channel code - e.g., HHZ
  late String locationCode; /// The location code - e.g., 01
  StreamIdentifier(String network, String station, String channel, String locationCode) {
    this.network = capitalizeAndRemoveBlanks(network);
    this.station = capitalizeAndRemoveBlanks(station);
    this.channel = capitalizeAndRemoveBlanks(channel);
    this.locationCode = capitalizeAndRemoveBlanks(locationCode);
  }

  /// Creates an identifier from a NET.STA.CHAN.LOC name of the sort the native
  /// getStreams call hands back - e.g., UU.ARUT.EHZ.01.  A station with no
  /// location code is written -- by getStreams but may also simply be omitted.
  /// This is the inverse of [toString].
  factory StreamIdentifier.fromString(String name) {
    final fields = name.split('.');
    if (fields.length < 3 || fields.length > 4) {
      throw FormatException(
        'Cannot parse a stream identifier from "$name"; '
        'expected NET.STA.CHAN.LOC',
      );
    }
    final locationCode = fields.length == 4 ? fields[3] : '';
    return StreamIdentifier(
      fields[0],
      fields[1],
      fields[2],
      locationCode == '--' ? '' : locationCode,
    );
  }

  @override
  String toString() {
    //final suffix = locationCode.isNotEmpty ? '.$locationCode' : '';
    return '$network.$station.$channel${locationCode.isNotEmpty ? ".$locationCode" : ".--"}';
  }

  /// Two identifiers naming the same stream are the same identifier.  A stream
  /// list needs this to sort, deduplicate and track selection.
  @override
  bool operator ==(Object other) {
    return other is StreamIdentifier &&
        other.network == network &&
        other.station == station &&
        other.channel == channel &&
        other.locationCode == locationCode;
  }

  @override
  int get hashCode => Object.hash(network, station, channel, locationCode);
}