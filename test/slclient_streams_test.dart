import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/native/slclient_bindings_generated.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';

/// Pulls the stream names out of a StreamsList so the tests can look at them.
List<String> _toDartStrings(Pointer<StreamsList> streams) {
  return List<String>.generate(
    streams.ref.nStreams,
    (i) => streams.ref.streams[i].cast<Utf8>().toDartString(),
  );
}

void main() {
  group('parseStreamsResponse', () {
    test('parses a canned INFO STREAMS response', () {
      final response = File('test/data/streams.json').readAsStringSync();
      using((arena) {
        final streams = arena<StreamsList>();
        final rc = parseStreamsResponse(
          response.toNativeUtf8(allocator: arena).cast<Char>(),
          streams,
        );
        expect(rc, 0, reason: 'parseStreamsResponse failed with $rc');

        final names = _toDartStrings(streams);
        expect(names, hasLength(114));
        // NET.STA.CHAN.LOC, with the channel reassembled from the band,
        // source and position codes of the 01_E_H_Z style stream identifier.
        expect(names, contains('UU.ARUT.EHZ.01'));
        expect(names, contains('UU.BGU.HHZ.01'));
        expect(names.toSet(), hasLength(names.length), reason: 'duplicates');
        expect(names, orderedEquals(names.toList()..sort()));

        freeStreams(streams);
        expect(streams.ref.nStreams, 0);
        expect(streams.ref.streams, nullptr);
      });
    });

    test('a server offering nothing yields an empty list', () {
      using((arena) {
        final streams = arena<StreamsList>();
        final rc = parseStreamsResponse(
          '{"software":"x"}'.toNativeUtf8(allocator: arena).cast<Char>(),
          streams,
        );
        expect(rc, 0);
        expect(streams.ref.nStreams, 0);
      });
    });

    test('feeds the StreamIdentifier model', () {
      final response = File('test/data/streams.json').readAsStringSync();
      using((arena) {
        final streams = arena<StreamsList>();
        final rc = parseStreamsResponse(
          response.toNativeUtf8(allocator: arena).cast<Char>(),
          streams,
        );
        expect(rc, 0);

        final identifiers = _toDartStrings(
          streams,
        ).map(StreamIdentifier.fromString).toList();
        freeStreams(streams);

        expect(identifiers, hasLength(114));
        final arut = identifiers.firstWhere((s) => s.station == 'ARUT');
        expect(arut.network, 'UU');
        expect(arut.channel, 'EHZ');
        expect(arut.locationCode, '01');
        // Every station in the fixture is a UU station on location 01
        expect(identifiers.every((s) => s.network == 'UU'), isTrue);
        expect(identifiers.map((s) => s.station).toSet(), hasLength(23));
      });
    });

    test('rejects a malformed response', () {
      using((arena) {
        final streams = arena<StreamsList>();
        final rc = parseStreamsResponse(
          'not json'.toNativeUtf8(allocator: arena).cast<Char>(),
          streams,
        );
        expect(rc, isNot(0));
        expect(streams.ref.nStreams, 0);
      });
    });
  });
}
