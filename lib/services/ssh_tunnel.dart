import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';

import '../models/ssh_tunnel_config.dart';
import './logging.dart';

final _log = Logger('seedlink.tunnel');

/// A private key needs a passphrase before it can be used.
///
/// Asked only when a key turns out to be encrypted, never up front - most keys
/// on a machine set up with ssh-copy-id are not, and those users should never
/// see this. Return null to give up.
///
/// [retry] is true when the last passphrase was wrong, so the prompt can say
/// so rather than looking like it simply ignored the first attempt.
typedef PassphrasePrompt =
    Future<String?> Function({required String keyPath, required bool retry});

/// Opens an SSH tunnel. Injected so the dialog and the connect path can be
/// tested without an SSH server anywhere.
typedef TunnelOpener =
    Future<Tunnel> Function({
      required SshTunnelConfig config,
      required String remoteHost,
      required int remotePort,
      required PassphrasePrompt onPassphrase,
    });

/// A tunnel that has been opened and is forwarding.
abstract class Tunnel {
  /// The port on this machine that now reaches the remote server.
  ///
  /// Chosen by the operating system, so two profiles can be open at once
  /// without agreeing on anything.
  int get localPort;

  /// Stops forwarding and logs out.
  Future<void> close();
}

/// Something went wrong opening the tunnel, with a sentence worth showing.
class SshTunnelException implements Exception {
  final String message;
  const SshTunnelException(this.message);
  @override
  String toString() => message;
}

/// The user declined to supply a passphrase.
///
/// Separate from a failure because it is not one: nothing has gone wrong and
/// there is nothing to report beyond closing the dialog.
class SshTunnelCancelled implements Exception {
  const SshTunnelCancelled();
  @override
  String toString() => 'Cancelled';
}

/// A path with a leading ~ turned into a real one.
///
/// The shell expands ~ before a program ever sees it, so a path typed into a
/// text field still has one - and dart's File takes it literally and looks for
/// a directory actually called "~".  A user copying ~/.ssh/id_ed25519 out of
/// the hint, or off any set of instructions ever written about ssh, would be
/// told the key does not exist.
///
/// Only a bare leading ~ is expanded.  ~someone-else is left alone: resolving
/// another user's home means asking the system who they are, and guessing
/// wrong would point at a key that is not theirs.
String expandUserPath(String path) {
  if (path != '~' && !path.startsWith('~/') && !path.startsWith(r'~\')) {
    return path;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return path;
  }
  final rest = path.length > 2 ? path.substring(2) : '';
  return rest.isEmpty ? home : '$home${Platform.pathSeparator}$rest';
}

/// Reads a private key, asking for a passphrase only if it turns out to need
/// one.
///
/// Decoding an encrypted key is deliberately expensive - that is the point of
/// a passphrase - so it runs on another isolate rather than stuttering the
/// plots. An unencrypted key is cheap and is decoded here.
Future<List<SSHKeyPair>> loadPrivateKey(
  String path,
  PassphrasePrompt onPassphrase,
) async {
  final String pem;
  final resolved = expandUserPath(path);
  try {
    pem = await File(resolved).readAsString();
  } on FileSystemException catch (e) {
    // Reported as the user wrote it rather than as expanded, so the message
    // matches what is on screen for them to correct.
    throw SshTunnelException('Could not read the private key $path: '
        '${e.osError?.message ?? e.message}');
  }
  if (!SSHKeyPair.isEncryptedPem(pem)) {
    return SSHKeyPair.fromPem(pem);
  }
  var retry = false;
  while (true) {
    final passphrase = await onPassphrase(keyPath: path, retry: retry);
    if (passphrase == null) {
      throw const SshTunnelCancelled();
    }
    try {
      return await Isolate.run(() => SSHKeyPair.fromPem(pem, passphrase));
    } catch (e) {
      // dartssh2 does not distinguish a wrong passphrase from a broken key, so
      // assume the passphrase and let the user try again.  Giving up is one
      // Cancel away.
      _log.info('private key $path did not decode', e);
      retry = true;
    }
  }
}

/// Opens an SSH tunnel with dartssh2.
///
/// This is the one part of tunnelling that cannot be exercised without a real
/// sshd, which is why everything above it is behind [TunnelOpener].
Future<Tunnel> openSshTunnel({
  required SshTunnelConfig config,
  required String remoteHost,
  required int remotePort,
  required PassphrasePrompt onPassphrase,
}) async {
  final identities = await loadPrivateKey(config.privateKeyPath, onPassphrase);
  final SSHClient client;
  try {
    final socket = await SSHSocket.connect(config.sshHost, config.sshPort);
    client = SSHClient(
      socket,
      username: config.user,
      identities: identities,
      onUserauthBanner: _log.info,
    );
    await client.authenticated;
  } on SshTunnelException {
    rethrow;
  } catch (e) {
    throw SshTunnelException('Could not log in to ${config.address}: $e');
  }
  try {
    return await _DartSshTunnel.bind(client, remoteHost, remotePort);
  } catch (e) {
    client.close();
    throw SshTunnelException(
      'Logged in to ${config.address} but could not reach '
      '$remoteHost:$remotePort from there: $e',
    );
  }
}

/// Local port forwarding, the `ssh -L` half of dartssh2.
///
/// Binds an operating system chosen port here, and hands everything that
/// arrives on it to a channel that comes out at the far end.
class _DartSshTunnel implements Tunnel {
  final SSHClient _client;
  final ServerSocket _server;
  final StreamSubscription<Socket> _connections;

  @override
  final int localPort;

  _DartSshTunnel._(
    this._client,
    this._server,
    this._connections,
    this.localPort,
  );

  static Future<_DartSshTunnel> bind(
    SSHClient client,
    String remoteHost,
    int remotePort,
  ) async {
    // Loopback and port zero: reachable only from this machine, on whatever
    // port happens to be free.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final connections = server.listen((socket) async {
      try {
        final forward = await client.forwardLocal(remoteHost, remotePort);
        unawaited(socket.cast<List<int>>().pipe(forward.sink));
        unawaited(forward.stream.cast<List<int>>().pipe(socket));
      } catch (e) {
        _log.warning('could not forward to $remoteHost:$remotePort', e);
        await socket.close();
      }
    });
    _log.info(
      'forwarding 127.0.0.1:${server.port} to $remoteHost:$remotePort',
    );
    return _DartSshTunnel._(client, server, connections, server.port);
  }

  @override
  Future<void> close() async {
    await _connections.cancel();
    await _server.close();
    _client.close();
    await _client.done;
    _log.info('tunnel on 127.0.0.1:$localPort closed');
  }
}
