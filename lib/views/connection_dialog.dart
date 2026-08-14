import 'dart:io' show Directory;
import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_ui/material_ui.dart';
import '../models/connection_profile.dart';
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
}) {
  return showDialog<ConnectionRequest>(
    context: context,
    builder: (context) => ConnectionDialog(
      existing: existing,
      takenNames: takenNames,
      tester: tester,
      directoryPicker: directoryPicker,
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

  const ConnectionDialog({
    super.key,
    this.existing,
    this.takenNames = const <String>{},
    this.tester,
    this.directoryPicker,
  });

  bool get isEditing => existing != null;

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  static const Duration _tooltipDelay = Duration(milliseconds: 200);

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _name;

  late bool _useTLS;
  late bool _save;

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
    return TooltipTheme(
      data: const TooltipThemeData(waitDuration: _tooltipDelay),
      child: AlertDialog(
        title: Text(
          widget.isEditing ? 'Edit ${widget.existing!.name}' : 'New Connection',
        ),
        content: SizedBox(
          width: 420,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
      ),
    );
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
        title: const Text('Use TLS'),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }

  /// Chooses which certificates to trust.  Empty means the system store,
  /// which libslink finds by itself and is what most servers need.
  Widget _buildCertificateRow(BuildContext context) {
    final chosen = _certificatePath.isEmpty
        ? 'System certificates'
        : _certificatePath;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: _certificatePath.isEmpty
                  ? 'Using the certificates already trusted by this machine. '
                        'Choose a directory only if your server uses a private '
                        'certificate authority.'
                  : 'Trusting the certificates in $_certificatePath',
              child: Text(
                chosen,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Choose a directory of CA certificates to trust.',
            child: OutlinedButton(
              onPressed: _chooseCertificateDirectory,
              child: const Text('Browse...'),
            ),
          ),
          if (_certificatePath.isNotEmpty) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: 'Go back to the system certificates.',
              child: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() => _certificatePath = ''),
              ),
            ),
          ],
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

  Widget _buildTestRow(BuildContext context) {
    return Row(
      children: [
        Tooltip(
          message: 'Ask the server to identify itself, without saving or '
              'connecting. Catches a wrong host or port early.',
          child: OutlinedButton(
            onPressed: _testing ? null : _test,
            child: const Text('Test'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _buildTestStatus(context)),
      ],
    );
  }

  Widget _buildTestStatus(BuildContext context) {
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
        'Answered: ${_testResult!}',
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
