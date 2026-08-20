/// The port sshd listens on, unless told otherwise.
const int defaultSshPort = 22;

/// Where to reach a SEEDLink server that is only visible from somewhere else.
///
/// This is one half of SSH local port forwarding - `ssh -L` - and deliberately
/// the smaller half. The other end, the SEEDLink server as the SSH host sees
/// it, is the [ConnectionProfile]'s own host and port, so that the address of
/// the server is written down once whether or not it is reached through a
/// tunnel.
///
/// The local port the tunnel binds is not here because it is nobody's
/// business: the machinery takes whatever the operating system hands it. A
/// fixed one would collide the moment two profiles were open at once, and no
/// user ever needed to know which it was.
///
/// Nor is there a passphrase. An encrypted key is discovered when the key is
/// read and asked about then; nothing secret is written to disk.
class SshTunnelConfig {
  /// The host to log in to. Not the SEEDLink server - the machine that can
  /// see it.
  final String sshHost;
  final int sshPort;
  final String user;

  /// Path to the private key to log in with, e.g. ~/.ssh/id_ed25519.
  final String privateKeyPath;

  const SshTunnelConfig({
    required this.sshHost,
    this.sshPort = defaultSshPort,
    required this.user,
    required this.privateKeyPath,
  });

  /// Whether this describes a usable tunnel.
  ///
  /// A half filled section is not an error while it is being typed, so the
  /// dialog asks this rather than being handed something that throws.
  bool get isComplete =>
      sshHost.trim().isNotEmpty &&
      user.trim().isNotEmpty &&
      privateKeyPath.trim().isNotEmpty &&
      sshPort >= 1 &&
      sshPort <= 65535;

  /// How the login reads in a message, e.g. bbaker@jump.example.org.
  String get address => sshPort == defaultSshPort
      ? '$user@$sshHost'
      : '$user@$sshHost:$sshPort';

  SshTunnelConfig copyWith({
    String? sshHost,
    int? sshPort,
    String? user,
    String? privateKeyPath,
  }) {
    return SshTunnelConfig(
      sshHost: sshHost ?? this.sshHost,
      sshPort: sshPort ?? this.sshPort,
      user: user ?? this.user,
      privateKeyPath: privateKeyPath ?? this.privateKeyPath,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sshHost': sshHost,
      'sshPort': sshPort,
      'user': user,
      // The path only. The key itself stays where it is, and its passphrase is
      // never written anywhere.
      'privateKeyPath': privateKeyPath,
    };
  }

  factory SshTunnelConfig.fromJson(Map<String, Object?> json) {
    final sshHost = json['sshHost'];
    final user = json['user'];
    final privateKeyPath = json['privateKeyPath'];
    if (sshHost is! String || user is! String || privateKeyPath is! String) {
      throw const FormatException(
        'A tunnel needs a string sshHost, user and privateKeyPath',
      );
    }
    final sshPort = json['sshPort'] ?? defaultSshPort;
    if (sshPort is! int || sshPort < 1 || sshPort > 65535) {
      throw const FormatException('sshPort must be an integer in 1-65535');
    }
    return SshTunnelConfig(
      sshHost: sshHost,
      sshPort: sshPort,
      user: user,
      privateKeyPath: privateKeyPath,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SshTunnelConfig &&
        other.sshHost == sshHost &&
        other.sshPort == sshPort &&
        other.user == user &&
        other.privateKeyPath == privateKeyPath;
  }

  @override
  int get hashCode => Object.hash(sshHost, sshPort, user, privateKeyPath);

  @override
  String toString() => 'SshTunnelConfig($address, key: $privateKeyPath)';
}
