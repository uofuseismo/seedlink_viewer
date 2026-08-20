import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/models/connection_profile.dart';
import 'package:seedlink_viewer/models/ssh_tunnel_config.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/ssh_tunnel.dart';

/// An OpenSSH key with no passphrase on it.
const _plainKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBb0nD8pxDPmJ7hhrkBjLLLbBQSVFCbCq0DDdRHmR9ORQAAAJgxSJHfMUiR
3wAAAAtzc2gtZWQyNTUxOQAAACBb0nD8pxDPmJ7hhrkBjLLLbBQSVFCbCq0DDdRHmR9ORQ
AAAEDMB7DFV6IhwbESPjF0vBoNlDgOZAj9WJyLTGmVFwbLPFvScPynEM+YnuGGuQGMssts
FBJUUJsKrQMN1EeZH05FAAAAEXRlc3RAZXhhbXBsZS5jb20BAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
''';

/// The same, with the passphrase "correct horse" on it.  A throwaway key
/// generated for this test - it opens nothing.
const _encryptedKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCtRAbIQL
ofY+agNAvspYwyAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIKtZPuaFyc07DrAl
PMAuaH9nALl5gUS4v/+P33/jt8FTAAAAoLoMWfLwAOO7b15rhkY+yfLju8JfSouljuUSMv
uFKNXuTHGV+3JuMCoNg/lKW/mj3Kf/PwZw207e+l1KSLidIN/vvpYWUhi8AgORqqY7IG+n
bFJkh8UP+TLvN26sURWeCbFMOxeaV4dgF9wTD1t1L59w6ttmfyvVFStUuByiFWJRJ3EbsJ
pYrHnJHsGcEDAsRGDAmsuCuNFap2b052qaDPk=
-----END OPENSSH PRIVATE KEY-----
''';

void main() {
  group('SshTunnelConfig', () {
    test('round trips through json', () {
      const config = SshTunnelConfig(
        sshHost: 'jump.example.org',
        sshPort: 2222,
        user: 'bbaker',
        privateKeyPath: '/home/bbaker/.ssh/id_ed25519',
      );
      expect(SshTunnelConfig.fromJson(config.toJson()), config);
    });

    test('never writes a passphrase, because it never holds one', () {
      const config = SshTunnelConfig(
        sshHost: 'jump.example.org',
        user: 'bbaker',
        privateKeyPath: '/home/bbaker/.ssh/id_ed25519',
      );
      // The whole file, so a field added later without thinking shows up here.
      expect(config.toJson().keys, <String>{
        'sshHost',
        'sshPort',
        'user',
        'privateKeyPath',
      });
    });

    test('defaults to the usual ssh port', () {
      final config = SshTunnelConfig.fromJson(const {
        'sshHost': 'jump.example.org',
        'user': 'bbaker',
        'privateKeyPath': '/k',
      });
      expect(config.sshPort, 22);
      expect(config.address, 'bbaker@jump.example.org');
    });

    test('a port worth mentioning is mentioned', () {
      const config = SshTunnelConfig(
        sshHost: 'jump.example.org',
        sshPort: 2222,
        user: 'bbaker',
        privateKeyPath: '/k',
      );
      expect(config.address, 'bbaker@jump.example.org:2222');
    });

    test('knows when it is only half filled in', () {
      const half = SshTunnelConfig(
        sshHost: 'jump.example.org',
        user: '',
        privateKeyPath: '/k',
      );
      expect(half.isComplete, isFalse);
    });
  });

  group('a profile carrying a tunnel', () {
    const tunnel = SshTunnelConfig(
      sshHost: 'jump.example.org',
      user: 'bbaker',
      privateKeyPath: '/home/bbaker/.ssh/id_ed25519',
    );

    test('round trips', () {
      final profile = ConnectionProfile(
        name: 'Behind the jump host',
        host: 'localhost',
        port: 18000,
        tunnel: tunnel,
        streams: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
      );
      final rebuilt = ConnectionProfile.fromJson(profile.toJson());
      expect(rebuilt, profile);
      expect(rebuilt.tunnel, tunnel);
      expect(rebuilt.isTunnelled, isTrue);
    });

    test('says how it is reached, since localhost alone would mislead', () {
      final profile = ConnectionProfile(
        name: 'x',
        host: 'localhost',
        tunnel: tunnel,
      );
      expect(profile.address, 'localhost:18000 via bbaker@jump.example.org');
      // The far end on its own is still available for the tunnel to be told
      expect(profile.remoteAddress, 'localhost:18000');
    });

    test('dropping the tunnel has to be asked for', () {
      final profile = ConnectionProfile(
        name: 'x',
        host: 'localhost',
        tunnel: tunnel,
      );
      // A bare copyWith must not quietly lose it
      expect(profile.copyWith(port: 18500).tunnel, tunnel);
      expect(profile.copyWith(dropTunnel: true).tunnel, isNull);
    });
  });

  group('profiles written before tunnels existed', () {
    test('still load, and are direct', () {
      final profile = ConnectionProfile.fromJson(const {
        'name': 'Utah',
        'host': 'rtserve.example.org',
        'port': 18000,
        'useTLS': false,
        'certificatePath': '',
        'streams': <String>['UU.ARUT.EHZ.01'],
      });
      expect(profile.tunnel, isNull);
      expect(profile.isTunnelled, isFalse);
      expect(profile.address, 'rtserve.example.org:18000');
    });

    test('and a direct profile is still written the old way', () {
      final profile = ConnectionProfile(name: 'x', host: 'h');
      expect(profile.toJson().containsKey('tunnel'), isFalse);
    });

    test('a tunnel that is not an object is refused', () {
      expect(
        () => ConnectionProfile.fromJson(const {
          'name': 'x',
          'host': 'h',
          'port': 18000,
          'tunnel': 'jump.example.org',
        }),
        throwsFormatException,
      );
    });
  });

  group('reading a private key', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('keys'));
    tearDown(() => directory.deleteSync(recursive: true));

    File writeKey(String contents) {
      final file = File('${directory.path}/id_ed25519');
      file.writeAsStringSync(contents);
      return file;
    }

    test('an unencrypted key is never asked about', () async {
      final key = writeKey(_plainKey);
      var asked = 0;
      final pairs = await loadPrivateKey(key.path, ({
        required keyPath,
        required retry,
      }) async {
        asked++;
        return 'nope';
      });

      // The whole point: a user set up with ssh-copy-id sees no prompt at all.
      expect(asked, 0);
      expect(pairs, isNotEmpty);
    });

    test('an encrypted key is asked about, once', () async {
      final key = writeKey(_encryptedKey);
      final asked = <String>[];
      final pairs = await loadPrivateKey(key.path, ({
        required keyPath,
        required retry,
      }) async {
        asked.add(keyPath);
        return 'correct horse';
      });

      expect(asked, [key.path], reason: 'asked once, naming the key');
      expect(pairs, isNotEmpty);
    });

    test('a wrong passphrase asks again, and says it is asking again', () async {
      final key = writeKey(_encryptedKey);
      final retries = <bool>[];
      final pairs = await loadPrivateKey(key.path, ({
        required keyPath,
        required retry,
      }) async {
        retries.add(retry);
        // Wrong, wrong, then right
        return retries.length < 3 ? 'wrong' : 'correct horse';
      });

      // The first ask is not a retry; the ones after a failure are, so the
      // prompt can say so rather than looking like it ignored the answer.
      expect(retries, [false, true, true]);
      expect(pairs, isNotEmpty);
    });

    test('giving up is not an error, it is a cancellation', () async {
      final key = writeKey(_encryptedKey);
      await expectLater(
        loadPrivateKey(key.path, ({
          required keyPath,
          required retry,
        }) async => null),
        throwsA(isA<SshTunnelCancelled>()),
      );
    });

    test('a key that is not there says so, and says which', () async {
      await expectLater(
        loadPrivateKey('${directory.path}/absent', ({
          required keyPath,
          required retry,
        }) async => null),
        throwsA(
          isA<SshTunnelException>().having(
            (e) => e.message,
            'message',
            allOf(contains('private key'), contains('absent')),
          ),
        ),
      );
    });
  });
}
