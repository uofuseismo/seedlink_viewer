import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/models/connection_profile.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';

List<StreamIdentifier> streams(List<String> names) =>
    names.map(StreamIdentifier.fromString).toList();

void main() {
  group('ConnectionProfile', () {
    test('defaults to the plain SEEDLink port and no streams', () {
      final profile = ConnectionProfile(name: 'local', host: 'localhost');
      expect(profile.port, 18000);
      expect(profile.useTLS, isFalse);
      expect(profile.streams, isEmpty);
      expect(profile.address, 'localhost:18000');
    });

    test('rejects nonsense', () {
      expect(
        () => ConnectionProfile(name: '  ', host: 'localhost'),
        throwsFormatException,
      );
      expect(
        () => ConnectionProfile(name: 'x', host: ''),
        throwsFormatException,
      );
      for (final port in [0, -1, 65536]) {
        expect(
          () => ConnectionProfile(name: 'x', host: 'h', port: port),
          throwsFormatException,
          reason: 'port $port should be rejected',
        );
      }
      // The edges are legal
      expect(ConnectionProfile(name: 'x', host: 'h', port: 1).port, 1);
      expect(ConnectionProfile(name: 'x', host: 'h', port: 65535).port, 65535);
    });

    test('the stream list cannot be mutated behind the profile back', () {
      final mine = streams(['UU.ARUT.EHZ.01']);
      final profile = ConnectionProfile(
        name: 'x',
        host: 'h',
        streams: mine,
      );
      expect(
        () => profile.streams.add(StreamIdentifier.fromString('UU.X.HHZ.01')),
        throwsUnsupportedError,
      );
    });

    test('round trips through json, streams and order intact', () {
      final profile = ConnectionProfile(
        name: 'Utah',
        host: 'seedlink.example.org',
        port: 18500,
        useTLS: true,
        certificatePath: '/etc/ssl/certs/ca.pem',
        streams: streams([
          'WY.YPK.HHZ.01',
          'UU.ARUT.EHZ.01',
          'UU.BGU.HHZ.01',
        ]),
      );

      final restored = ConnectionProfile.fromJson(profile.toJson());

      expect(restored, profile);
      // Plot order is the point of storing a list rather than a set
      expect(restored.streams.map((s) => s.toString()), [
        'WY.YPK.HHZ.01',
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
      ]);
    });

    test('fills in the optional fields when reading an older entry', () {
      final restored = ConnectionProfile.fromJson(<String, Object?>{
        'name': 'bare',
        'host': 'localhost',
        'port': 18000,
      });
      expect(restored.useTLS, isFalse);
      expect(restored.certificatePath, '');
      expect(restored.streams, isEmpty);
    });

    test('refuses a malformed entry', () {
      final bad = <Map<String, Object?>>[
        {'host': 'localhost', 'port': 18000},
        {'name': 'x', 'port': 18000},
        {'name': 'x', 'host': 'localhost', 'port': '18000'},
        {'name': 'x', 'host': 'localhost', 'port': 18000, 'useTLS': 'yes'},
        {'name': 'x', 'host': 'localhost', 'port': 18000, 'streams': 'nope'},
        {
          'name': 'x',
          'host': 'localhost',
          'port': 18000,
          'streams': [42],
        },
      ];
      for (final entry in bad) {
        expect(
          () => ConnectionProfile.fromJson(entry),
          throwsFormatException,
          reason: '$entry should be rejected',
        );
      }
    });
  });

  group('reconciliation', () {
    final profile = ConnectionProfile(
      name: 'Utah',
      host: 'localhost',
      streams: streams([
        'WY.YPK.HHZ.01',
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
      ]),
    );

    test('keeps what is still offered, in the saved plot order', () {
      // Offered in a different order, and with an extra the profile never had
      final result = profile.reconcile(
        streams([
          'UU.BGU.HHZ.01',
          'UU.NEW.HHZ.01',
          'WY.YPK.HHZ.01',
          'UU.ARUT.EHZ.01',
        ]),
      );

      expect(result.kept.map((s) => s.toString()), [
        'WY.YPK.HHZ.01',
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
      ]);
      expect(result.dropped, isEmpty);
      expect(result.droppedAnything, isFalse);
    });

    test('drops what the server no longer offers and closes the gap', () {
      final result = profile.reconcile(
        streams(['WY.YPK.HHZ.01', 'UU.BGU.HHZ.01']),
      );

      // The middle stream is gone, the survivors keep their relative order
      expect(result.kept.map((s) => s.toString()), [
        'WY.YPK.HHZ.01',
        'UU.BGU.HHZ.01',
      ]);
      expect(result.dropped.map((s) => s.toString()), ['UU.ARUT.EHZ.01']);
      expect(result.droppedAnything, isTrue);
    });

    test('a server offering nothing drops everything', () {
      final result = profile.reconcile(const <StreamIdentifier>[]);
      expect(result.kept, isEmpty);
      expect(result.dropped, hasLength(3));
    });

    test('a profile with no streams reconciles to nothing', () {
      final empty = ConnectionProfile(name: 'x', host: 'h');
      final result = empty.reconcile(streams(['UU.ARUT.EHZ.01']));
      expect(result.kept, isEmpty);
      expect(result.dropped, isEmpty);
      expect(result.droppedAnything, isFalse);
    });
  });
}
