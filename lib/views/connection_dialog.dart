import 'dart:io' show Directory, Platform;
import 'package:file_selector/file_selector.dart'
    show XTypeGroup, getDirectoryPath, openFile;
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import '../models/connection_profile.dart';
import '../models/ssh_tunnel_config.dart';
import '../services/seedlink_session.dart';

/// Checks a server is reachable.  Injectable so tests need no server.
typedef ServerTester =
    Future<String> Function({
      required String host,
      required int port,
      bool useTLS,
      String certificatePath,
    });

/// Chooses a directory.  Injectable so tests need no file chooser.
typedef DirectoryPicker =
    Future<String?> Function({String? initialDirectory});

/// Chooses a file.  Injectable for the same reason.
typedef FilePicker = Future<String?> Function({String? initialDirectory});

/// Where ssh keeps its keys, if that directory is there.
///
/// Opening the chooser here puts the user on top of the key they already use
/// rather than in their home directory looking for a hidden folder.
String? defaultSshDirectory() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return null;
  }
  final ssh = '$home${Platform.pathSeparator}.ssh';
  return Directory(ssh).existsSync() ? ssh : null;
}

/// The real file chooser, filtered to the things a private key looks like.
Future<String?> openPrivateKeyFile({String? initialDirectory}) async {
  final file = await openFile(
    initialDirectory: initialDirectory,
    acceptedTypeGroups: const [
      // Keys usually have no extension at all, so this cannot be narrowed
      // without hiding the very file being looked for.
      XTypeGroup(label: 'Private keys'),
    ],
  );
  return file?.path;
}

/// Where certificate authority certificates usually live.
///
/// These are the directories libslink searches by itself, so opening the
/// chooser here puts the user somewhere useful rather than in their home
/// directory.
const List<String> knownCertificateDirectories = <String>[
  '/etc/ssl/certs',
  '/etc/pki/tls/certs',
];

/// The first of [knownCertificateDirectories] that exists here, if any.
String? defaultCertificateDirectory() {
  for (final path in knownCertificateDirectories) {
    if (Directory(path).existsSync()) {
      return path;
    }
  }
  return null;
}

/// What the user asked for when they dismissed the connection dialog.
class ConnectionRequest {
  /// The connection as configured.  When [save] is false this is still a
  /// well formed profile, named after the address, but it is not written to
  /// the profile list.
  final ConnectionProfile profile;

  /// Write the profile to the saved list.
  final bool save;

  /// Connect once the dialog closes.  False when editing - fixing a typo
  /// should not disturb the connection you are on.
  final bool connect;

  const ConnectionRequest({
    required this.profile,
    required this.save,
    required this.connect,
  });
}

/// Collects the details of a connection.
///
/// Creating asks for a server and connects to it, optionally remembering it.
/// Editing changes a profile already saved, and does not connect.
Future<ConnectionRequest?> showConnectionDialog(
  BuildContext context, {
  ConnectionProfile? existing,
  Set<String> takenNames = const <String>{},
  ServerTester? tester,
  DirectoryPicker? directoryPicker,
  FilePicker? filePicker,
}) {
  return showDialog<ConnectionRequest>(
    context: context,
    builder: (context) => ConnectionDialog(
      existing: existing,
      takenNames: takenNames,
      tester: tester,
      directoryPicker: directoryPicker,
      filePicker: filePicker,
    ),
  );
}

class ConnectionDialog extends StatefulWidget {
  /// The profile being changed, or null when creating a new connection.
  final ConnectionProfile? existing;

  /// Names already in use, so two profiles cannot collide.
  final Set<String> takenNames;

  final ServerTester? tester;

  final DirectoryPicker? directoryPicker;

  /// Chooses the private key.  Injectable so tests need no file chooser.
  final FilePicker? filePicker;

  const ConnectionDialog({
    super.key,
    this.existing,
    this.takenNames = const <String>{},
    this.tester,
    this.directoryPicker,
    this.filePicker,
  });

  bool get isEditing => existing != null;

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _name;

  late bool _useTLS;
  late bool _save;

  /// True while the SSH tunnel tab is the one showing.
  ///
  /// Which tab is open is what decides whether the saved profile carries a
  /// tunnel, so this is the setting rather than a view of one.  A checkbox
  /// would have been smaller, but Host means "reachable from here" on one tab
  /// and "reachable from the SSH host" on the other, and a control that
  /// silently changes what a field means is how the port confusion started.
  late bool _tunnelled;

  late final TextEditingController _sshHost;
  late final TextEditingController _sshPort;
  late final TextEditingController _sshUser;
  late final TextEditingController _privateKeyPath;

  /// A CA certificate directory or bundle, or empty for the system store.
  late String _certificatePath;

  /// Result of the last Test, or null if it has not been run since something
  /// changed.
  String? _testResult;
  String? _testError;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(
      text: '${existing?.port ?? defaultSeedLinkPort}',
    );
    _name = TextEditingController(text: existing?.name ?? '');
    final tunnel = existing?.tunnel;
    _tunnelled = tunnel != null;
    _sshHost = TextEditingController(text: tunnel?.sshHost ?? '');
    _sshPort = TextEditingController(
      text: '${tunnel?.sshPort ?? defaultSshPort}',
    );
    _sshUser = TextEditingController(text: tunnel?.user ?? '');
    _privateKeyPath = TextEditingController(
      text: tunnel?.privateKeyPath ?? '',
    );
    _useTLS = existing?.useTLS ?? false;
    _certificatePath = existing?.certificatePath ?? '';
    // Editing an existing profile always writes back; creating is opt in.
    _save = widget.isEditing;
    _host.addListener(_onAddressChanged);
    _port.addListener(_onAddressChanged);
  }

  @override
  void dispose() {
    _host.removeListener(_onAddressChanged);
    _port.removeListener(_onAddressChanged);
    _host.dispose();
    _port.dispose();
    _name.dispose();
    _sshHost.dispose();
    _sshPort.dispose();
    _sshUser.dispose();
    _privateKeyPath.dispose();
    super.dispose();
  }

  /// A Test result only describes the address it was run against.
  void _onAddressChanged() {
    if (_testResult != null || _testError != null) {
      setState(() {
        _testResult = null;
        _testError = null;
      });
    }
  }

  int get _portValue => int.tryParse(_port.text.trim()) ?? -1;

  /// The name a saved profile takes when the user does not type one.
  String get _defaultName => '${_host.text.trim()}:${_port.text.trim()}';

  String get _effectiveName =>
      _name.text.trim().isEmpty ? _defaultName : _name.text.trim();

  /// TLS runs on its own port, so follow the checkbox unless the user has
  /// deliberately typed something else.
  void _onTLSChanged(bool? value) {
    setState(() {
      final wasDefault =
          _portValue ==
          (_useTLS ? defaultSecureSeedLinkPort : defaultSeedLinkPort);
      _useTLS = value ?? false;
      if (wasDefault) {
        _port.text =
            '${_useTLS ? defaultSecureSeedLinkPort : defaultSeedLinkPort}';
      }
    });
  }

  /// The tunnel as typed.  Only asked for while the tunnel tab is showing.
  SshTunnelConfig get _tunnelConfig => SshTunnelConfig(
    sshHost: _sshHost.text.trim(),
    sshPort: int.tryParse(_sshPort.text.trim()) ?? defaultSshPort,
    user: _sshUser.text.trim(),
    privateKeyPath: _privateKeyPath.text.trim(),
  );

  /// Moving between Direct and SSH tunnel changes where Host points, so a Test
  /// run against the old meaning no longer describes anything.
  void _onTabChanged(int index) {
    setState(() {
      _tunnelled = index == 1;
      _testResult = null;
      _testError = null;
      // The server is normally on the box being logged in to, and a blank
      // Host on this tab is the commonest thing to get wrong.
      if (_tunnelled && _host.text.trim().isEmpty) {
        _host.text = 'localhost';
      }
    });
  }

  Future<void> _test() async {
    if (_host.text.trim().isEmpty || _portValue < 1 || _portValue > 65535) {
      setState(() {
        _testResult = null;
        _testError = 'Enter a host and a port first';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _testError = null;
    });
    final tester = widget.tester ?? pingSeedLinkServer;
    try {
      final identifier = await tester(
        host: _host.text.trim(),
        port: _portValue,
        useTLS: _useTLS,
        certificatePath: _certificatePath,
      );
      if (mounted) {
        setState(() => _testResult = identifier);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _testError = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final existing = widget.existing;
    final profile = ConnectionProfile(
      name: _effectiveName,
      host: _host.text.trim(),
      port: _portValue,
      useTLS: _useTLS,
      // Certificates are only meaningful over TLS, so an unticked box clears
      // whatever was chosen rather than saving a setting nothing consults.
      certificatePath: _useTLS ? _certificatePath : '',
      // Editing keeps the streams the profile already remembers
      streams: existing?.streams ?? const [],
      // Which tab is showing decides this.  Switching back to Direct drops the
      // tunnel rather than saving one nothing will open.
      tunnel: _tunnelled ? _tunnelConfig : null,
    );
    Navigator.of(context).pop(
      ConnectionRequest(
        profile: profile,
        save: _save,
        connect: !widget.isEditing,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isEditing ? 'Edit ${widget.existing!.name}' : 'New Connection',
      ),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRouteTabs(context),
                const SizedBox(height: 16),
                if (_tunnelled) ...[
                  _buildTunnelFields(context),
                  const Divider(height: 24),
                  // Said out loud because it is the one thing on this tab that
                  // is easy to get wrong: this is the server as the SSH host
                  // sees it, not as this machine does.
                  Text(
                    'SEEDLink server, as seen from the SSH host',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
                _buildHostField(),
                const SizedBox(height: 12),
                _buildPortField(),
                const SizedBox(height: 4),
                _buildTLSCheckbox(),
                if (_useTLS) _buildCertificateRow(context),
                const Divider(height: 24),
                _buildTestRow(context),
                const Divider(height: 24),
                _buildSaveControls(),
              ],
            ),
          ),
        ),
      ),
      actions: _buildActions(context),
    );
  }

  /// Direct or through an SSH tunnel.
  ///
  /// Tabs rather than a checkbox because the two routes do not share a
  /// vocabulary: on Direct, Host is reachable from this machine; on SSH
  /// tunnel, it is reachable from the SSH host and is usually localhost.
  Widget _buildRouteTabs(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(
          value: false,
          label: Text('Direct'),
          icon: Icon(Icons.arrow_forward, size: 16),
        ),
        ButtonSegment<bool>(
          value: true,
          label: Text('SSH tunnel'),
          icon: Icon(Icons.vpn_key, size: 16),
        ),
      ],
      selected: {_tunnelled},
      onSelectionChanged: (selection) =>
          _onTabChanged(selection.first ? 1 : 0),
    );
  }

  /// Everything needed to log in to the machine that can see the server.
  ///
  /// Four fields, three of which usually answer themselves. There is no
  /// passphrase here on purpose: an encrypted key says so when it is read, and
  /// is asked about then. There is no local port either - the tunnel takes
  /// whatever the operating system gives it.
  Widget _buildTunnelFields(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Tooltip(
                message: 'The machine to log in to - the one that can reach '
                    'the SEEDLink server. Not the server itself.',
                child: TextFormField(
                  controller: _sshHost,
                  decoration: const InputDecoration(
                    labelText: 'SSH host',
                    hintText: 'jump.example.org',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (value) => (!_tunnelled ||
                          (value ?? '').trim().isNotEmpty)
                      ? null
                      : 'Enter the host to tunnel through',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: 'The port sshd listens on. $defaultSshPort unless '
                    'someone has moved it.',
                child: TextFormField(
                  controller: _sshPort,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (value) {
                    if (!_tunnelled) {
                      return null;
                    }
                    final port = int.tryParse((value ?? '').trim());
                    return (port == null || port < 1 || port > 65535)
                        ? '1-65535'
                        : null;
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Tooltip(
          message: 'The account to log in as on the SSH host.',
          child: TextFormField(
            controller: _sshUser,
            decoration: const InputDecoration(
              labelText: 'User',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            validator: (value) =>
                (!_tunnelled || (value ?? '').trim().isNotEmpty)
                ? null
                : 'Enter the user to log in as',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Tooltip(
                message: 'The key you already use for this host. If it is '
                    'protected by a passphrase you will be asked for it when '
                    'connecting - it is never saved.',
                child: TextFormField(
                  controller: _privateKeyPath,
                  decoration: const InputDecoration(
                    labelText: 'Private key',
                    hintText: '~/.ssh/id_ed25519',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (value) =>
                      (!_tunnelled || (value ?? '').trim().isNotEmpty)
                      ? null
                      : 'Choose the private key to log in with',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Tooltip(
                message: 'Find the private key.',
                child: OutlinedButton(
                  onPressed: _choosePrivateKey,
                  child: const Text('Browse...'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _choosePrivateKey() async {
    final picker = widget.filePicker ?? openPrivateKeyFile;
    final chosen = await picker(initialDirectory: defaultSshDirectory());
    if (chosen != null && mounted) {
      setState(() => _privateKeyPath.text = chosen);
    }
  }

  Widget _buildHostField() {
    return Tooltip(
      message: 'The SEEDLink server to read from, e.g. localhost or '
          'rtserve.iris.washington.edu',
      child: TextFormField(
        controller: _host,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Host',
          hintText: 'localhost',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        validator: (value) =>
            (value == null || value.trim().isEmpty) ? 'Enter a host' : null,
      ),
    );
  }

  Widget _buildPortField() {
    return Tooltip(
      message: 'The port the server listens on. $defaultSeedLinkPort is the '
          'SEEDLink default, $defaultSecureSeedLinkPort for TLS.',
      child: TextFormField(
        controller: _port,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Port',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        validator: (value) {
          final port = int.tryParse((value ?? '').trim());
          if (port == null || port < 1 || port > 65535) {
            return 'Enter a port between 1 and 65535';
          }
          return null;
        },
      ),
    );
  }

  Widget _buildTLSCheckbox() {
    return Tooltip(
      message: 'Encrypt the connection. Certificates come from the system '
          'store; a per-connection certificate is not supported yet.',
      child: CheckboxListTile(
        value: _useTLS,
        onChanged: _onTLSChanged,
        title: const Text('Use Certificates'),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }

  /// Chooses which certificates to trust.  Empty means the system store,
  /// which libslink finds by itself and is what most servers need.
  /// Which authority vouches for the server.
  ///
  /// Labelled for what it decides rather than for what it holds. A path to a
  /// certificate invites the reading that it is the user's own credential -
  /// the thing that gets them in - when it is the opposite: it says who this
  /// machine will believe when the server proves who it is. Client
  /// certificates are a different thing again and are not supported.
  Widget _buildCertificateRow(BuildContext context) {
    final chosen = _certificatePath.isEmpty
        ? 'System store'
        : _certificatePath;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Above rather than beside: a path is long, and squeezing a caption
          // in next to one leaves no room for either.
          Text(
            'Trust certificates from:',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: _certificatePath.isEmpty
                      ? 'The certificates already trusted by this machine. These '
                            'cover public servers; point this at your own '
                            'authority for a private one.'
                      : 'Believing any server vouched for by the certificates in '
                            '$_certificatePath',
                  child: Text(
                    chosen,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Choose the authority that vouches for your server.',
                child: OutlinedButton(
                  onPressed: _chooseCertificateDirectory,
                  child: const Text('Browse...'),
                ),
              ),
              if (_certificatePath.isNotEmpty) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Go back to the system store.',
                  child: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _certificatePath = ''),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _chooseCertificateDirectory() async {
    final picker = widget.directoryPicker ?? getDirectoryPath;
    // Start where certificates normally live rather than the home directory.
    final start = _certificatePath.isNotEmpty
        ? _certificatePath
        : defaultCertificateDirectory();
    final chosen = await picker(initialDirectory: start);
    if (chosen != null && mounted) {
      setState(() => _certificatePath = chosen);
    }
  }

  /// Asks the server to identify itself, before anything is saved.
  ///
  /// Off on the SSH tunnel tab. The address on that tab is the server as the
  /// SSH host sees it - usually localhost:18000 - and dialling it from here
  /// would either fail confusingly or, worse, reach something else listening
  /// on this machine and report that. Testing it honestly means opening the
  /// tunnel first, which is a login and a passphrase prompt, so it waits for
  /// Connect rather than pretending to be the cheap check it is on Direct.
  Widget _buildTestRow(BuildContext context) {
    return Row(
      children: [
        Tooltip(
          message: _tunnelled
              ? 'Not available through a tunnel: this address is the server '
                    'as the SSH host sees it, so testing it from here would '
                    'not mean anything. Connect to try it.'
              : 'Ask the server to identify itself, without saving or '
                    'connecting. Catches a wrong host or port early.',
          child: OutlinedButton(
            onPressed: (_testing || _tunnelled) ? null : _test,
            child: const Text('Test'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _buildTestStatus(context)),
      ],
    );
  }

  Widget _buildTestStatus(BuildContext context) {
    if (_tunnelled) {
      return Text(
        'Tested when you connect, through the tunnel.',
        style: Theme.of(context).textTheme.bodySmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (_testing) {
      return const Row(
        children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Contacting...'),
        ],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    if (_testError != null) {
      return Text(
        _testError!,
        style: TextStyle(color: scheme.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (_testResult != null) {
      return Text(
        'Received response from ${_testResult!}',
        style: TextStyle(color: scheme.primary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildSaveControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.isEditing)
          Tooltip(
            message: 'Remember this server so it appears under '
                'Connection > Connect.',
            child: CheckboxListTile(
              value: _save,
              onChanged: (value) => setState(() => _save = value ?? false),
              title: const Text('Save as profile'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        if (_save)
          Tooltip(
            message: 'What this profile is called in the Connection menu.',
            child: TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Profile name',
                hintText: _defaultName,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              validator: (value) {
                if (!_save) {
                  return null;
                }
                final name = (value ?? '').trim().isEmpty
                    ? _defaultName
                    : value!.trim();
                if (name.isEmpty || name == ':') {
                  return 'Enter a name';
                }
                final clashes = widget.takenNames.contains(name) &&
                    name != widget.existing?.name;
                return clashes ? 'A profile called "$name" already exists' : null;
              },
            ),
          ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      Tooltip(
        message: widget.isEditing
            ? 'Save these changes. This does not change the connection you '
                'are on.'
            : 'Connect to this server now.',
        child: FilledButton(
          onPressed: _submit,
          child: Text(widget.isEditing ? 'Save' : 'Connect'),
        ),
      ),
    ];
  }
}
