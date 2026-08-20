import 'dart:io' show exit;
import 'package:material_ui/material_ui.dart';
import './models/connection_profile.dart';
import './models/plot_timing.dart';
import './models/stream_identifier.dart';
import './services/logging.dart';
import './services/profile_store.dart';
import './services/ssh_tunnel.dart';
import './services/seedlink_packet_reader.dart';
import './services/seedlink_session.dart';
import './services/stream_source.dart';
import './views/app_menu_bar.dart';
import './views/connection_dialog.dart';
import './views/multi_stream_painter.dart';
import './views/passphrase_dialog.dart';
import './views/plot_duration_selector.dart';
import './views/plot_options_dialog.dart';
import './views/stream_selector_dialog.dart';
import './views/welcome_view.dart';


void main() {
  setUpLogging();
  runApp(const MyApp());
}

/// How long the mouse has to sit still before a tooltip appears.
///
/// Tooltips default to arriving the instant the mouse lands, which nags on
/// buttons whose job is already obvious.
const tooltipDelay = Duration(milliseconds: 300);

/// The application's look.
///
/// Exposed because a test that pumps a single dialog has to build the
/// MaterialApp around it, and a dialog under a bare default theme is not the
/// dialog the user sees.  Tooltip timing especially: it is invisible in a
/// screenshot and only shows up in a test that waits for it.
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(seedColor: Colors.red);
  return ThemeData(
    colorScheme: colorScheme,
    tooltipTheme: const TooltipThemeData(waitDuration: tooltipDelay),
    inputDecorationTheme: InputDecorationThemeData(
      // Material's default placeholder is onSurfaceVariant, which against
      // entered text is only about 1.8:1 - near enough identical that a
      // prefilled port reads as a suggestion and gets typed over, and a
      // suggested host reads as already filled in.  outline roughly doubles
      // the separation while staying legible in its own right.
      //
      // The other half of the problem is not fixable this way: entered text
      // is already 16:1 against the field, so there is no darker to go.
      hintStyle: TextStyle(color: colorScheme.outline),
    ),
  );
}

class MyApp extends StatelessWidget {
  /// Where connection profiles are kept.  Injectable so tests can run against
  /// memory rather than the user's real profiles file.
  final ProfileStore? profileStore;

  /// Checks a server is reachable.  Injectable so tests need no server.
  final ServerTester? serverTester;

  /// Opens an SSH tunnel.  Injectable so tests need no SSH server - which is
  /// the whole reason the tunnel is reached through a function rather than
  /// built where it is used.
  final TunnelOpener? tunnelOpener;

  /// Builds the source used to query a server for its streams.  Injectable
  /// for the same reason.
  final StreamSource Function(ConnectionProfile)? streamSourceBuilder;

  const MyApp({
    super.key,
    this.profileStore,
    this.serverTester,
    this.tunnelOpener,
    this.streamSourceBuilder,
  });

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SeedLink Viewer',
      theme: buildAppTheme(),
      home: SeedLinkViewerHome(
        profileStore: profileStore,
        serverTester: serverTester,
        tunnelOpener: tunnelOpener,
        streamSourceBuilder: streamSourceBuilder,
      ),
    );
  }
}

/// The main window: a menu bar over a stack of plots, one per selected stream.
class SeedLinkViewerHome extends StatefulWidget {
  final ProfileStore? profileStore;
  final ServerTester? serverTester;
  final TunnelOpener? tunnelOpener;
  final StreamSource Function(ConnectionProfile)? streamSourceBuilder;

  const SeedLinkViewerHome({
    super.key,
    this.profileStore,
    this.serverTester,
    this.tunnelOpener,
    this.streamSourceBuilder,
  });

  @override
  State<SeedLinkViewerHome> createState() => _SeedLinkViewerHomeState();
}

class _SeedLinkViewerHomeState extends State<SeedLinkViewerHome> {
  late final ProfileStore _store = widget.profileStore ?? JsonFileProfileStore();

  /// The saved connections, as listed in the Connection menu.
  var _profiles = <ConnectionProfile>[];

  /// The profile currently connected to, or null when disconnected.
  ConnectionProfile? _active;

  /// The streams to plot, top to bottom.
  var _selected = <StreamIdentifier>[];

  /// Every duration the plots run on.  Owned here, at the top, so the plot
  /// options dialog changes one thing and the whole stack below stays
  /// consistent with it - the buffer behind each plot is derived from the
  /// window, so the two can never disagree.
  ///
  /// Not persisted: this is a tool for having a quick look, and a window that
  /// silently came back from last week is harder to explain than one that
  /// starts where it always does.
  PlotTiming _timing = const PlotTiming();

  /// Holds the one connection packets are read from.  One reader serves every
  /// plot: getPackets consumes packets, so a second reader on the same
  /// connection would take data the plots are waiting for.
  SeedLinkPacketReader? _reader;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _reader?.stop();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final profiles = await _store.load();
      if (mounted) {
        setState(() => _profiles = profiles);
      }
    } on ProfileStoreException catch (e) {
      // Carry on with no profiles rather than refusing to start. The file is
      // left untouched so it can be recovered by hand.
      _report('$e', isError: true);
    }
  }

  Future<void> _saveProfiles() async {
    try {
      await _store.save(_profiles);
    } catch (e) {
      _report('Could not save profiles: $e', isError: true);
    }
  }

  /// Where the stream selector should re-query, for a connection that is
  /// already up.
  ///
  /// The tunnel is already open, so this reuses it rather than dialling the
  /// far address directly - which from here would not resolve.
  _Endpoint _connectedEndpoint(ConnectionProfile profile) {
    final tunnel = _tunnel;
    return tunnel == null
        ? _Endpoint(profile.host, profile.port)
        : _Endpoint('127.0.0.1', tunnel.localPort);
  }

  /// The tunnel the active connection is running through, if any.
  ///
  /// Held so it can be closed on disconnect.  Only one is ever open: there is
  /// only ever one active connection.
  Tunnel? _tunnel;

  StreamSource _sourceFor(ConnectionProfile profile, _Endpoint endpoint) {
    final builder = widget.streamSourceBuilder;
    if (builder != null) {
      return builder(profile);
    }
    return SeedLinkStreamSource(
      host: endpoint.host,
      port: endpoint.port,
      useTLS: profile.useTLS,
      certificatePath: profile.certificatePath,
    );
  }

  /// Where to actually dial for a profile.
  ///
  /// A direct profile is its own address.  A tunnelled one is reached at the
  /// near end of the tunnel, which is on loopback at whatever port the
  /// operating system handed out - the profile's own host and port describe
  /// the far end and are what the tunnel was told to forward to.
  ///
  /// Returns null when a tunnel was needed and could not be opened, having
  /// already said why.
  Future<_Endpoint?> _reach(ConnectionProfile profile) async {
    final tunnel = profile.tunnel;
    if (tunnel == null) {
      return _Endpoint(profile.host, profile.port);
    }
    // A stream source has been injected, so there is no real server and no
    // real tunnel to reach it through.
    if (widget.streamSourceBuilder != null && widget.tunnelOpener == null) {
      return _Endpoint(profile.host, profile.port);
    }
    final opener = widget.tunnelOpener ?? openSshTunnel;
    try {
      final opened = await opener(
        config: tunnel,
        remoteHost: profile.host,
        remotePort: profile.port,
        onPassphrase: _askForPassphrase,
      );
      _tunnel = opened;
      return _Endpoint('127.0.0.1', opened.localPort);
    } on SshTunnelCancelled {
      // Not a failure - the user closed the passphrase prompt.
      return null;
    } catch (e) {
      _report('Could not open the tunnel to ${tunnel.address}: $e',
          isError: true);
      return null;
    }
  }

  /// Asked only when a key turns out to be encrypted.
  Future<String?> _askForPassphrase({
    required String keyPath,
    required bool retry,
  }) async {
    if (!mounted) {
      return null;
    }
    return showPassphrasePrompt(context, keyPath: keyPath, retry: retry);
  }

  Future<void> _closeTunnel() async {
    final tunnel = _tunnel;
    _tunnel = null;
    if (tunnel == null) {
      return;
    }
    try {
      await tunnel.close();
    } catch (e) {
      // Nothing useful to do about a tunnel that will not shut politely; the
      // process going away closes it regardless.
      _report('The tunnel did not close cleanly: $e', isError: true);
    }
  }

  void _report(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.errorContainer
            : null,
        duration: Duration(seconds: isError ? 8 : 5),
      ),
    );
  }

  /// Connects, then reconciles the profile's saved streams against what the
  /// server is actually offering.  Anything it no longer carries is dropped -
  /// the user can add it again if it comes back.
  Future<void> _connect(ConnectionProfile profile) async {
    // Whatever was open belongs to the connection being replaced.
    await _closeTunnel();
    final endpoint = await _reach(profile);
    if (endpoint == null || !mounted) {
      return;
    }
    final source = _sourceFor(profile, endpoint);
    List<StreamIdentifier> available;
    try {
      available = await source.fetchStreams();
    } catch (e) {
      _report('Could not connect to ${profile.address}: $e', isError: true);
      await _closeTunnel();
      return;
    }
    if (!mounted) {
      await _closeTunnel();
      return;
    }
    final reconciled = profile.reconcile(available);
    setState(() {
      _active = profile;
      _selected = reconciled.kept;
    });
    await _startReader(profile, endpoint);
    if (reconciled.droppedAnything) {
      final names = reconciled.dropped.map((s) => '$s').join(', ');
      _report(
        '${reconciled.dropped.length} saved '
        '${reconciled.dropped.length == 1 ? "stream is" : "streams are"} no '
        'longer offered and ${reconciled.dropped.length == 1 ? "was" : "were"} '
        'dropped: $names',
      );
      // The profile now differs from what was saved, so keep them in step.
      await _rememberSelection();
    } else {
      _report('Connected to ${profile.name} (${profile.address})');
    }
  }

  /// Opens the connection the plots are fed from.
  ///
  /// Skipped when a stream source has been injected, because then there is no
  /// real server to read from.
  Future<void> _startReader(ConnectionProfile profile, _Endpoint endpoint) async {
    await _reader?.stop();
    _reader = null;
    if (widget.streamSourceBuilder != null) {
      return;
    }
    try {
      final reader = await SeedLinkPacketReader.start(
        host: endpoint.host,
        port: endpoint.port,
        useTLS: profile.useTLS,
        certificatePath: profile.certificatePath,
        streams: _selected,
      );
      if (!mounted) {
        await reader.stop();
        return;
      }
      setState(() => _reader = reader);
    } catch (e) {
      _report('Could not start reading from ${profile.address}: $e',
          isError: true);
    }
  }

  Future<void> _disconnect() async {
    await _reader?.stop();
    // After the reader, which is the thing using it.
    await _closeTunnel();
    setState(() {
      _active = null;
      _selected = <StreamIdentifier>[];
      _reader = null;
    });
  }

  /// Writes the current plot list back to the active profile, if the active
  /// connection is a saved one.  Ad hoc connections have nowhere to write.
  Future<void> _rememberSelection() async {
    final active = _active;
    if (active == null) {
      return;
    }
    final index = _profiles.indexWhere((p) => p.name == active.name);
    if (index < 0) {
      return;
    }
    final updated = _profiles[index].copyWith(streams: _selected);
    setState(() {
      _profiles = List<ConnectionProfile>.of(_profiles)..[index] = updated;
      _active = updated;
    });
    await _saveProfiles();
  }

  Future<void> _createConnection() async {
    final request = await showConnectionDialog(
      context,
      takenNames: _profiles.map((p) => p.name).toSet(),
      tester: widget.serverTester,
    );
    if (request == null || !mounted) {
      return;
    }
    if (request.save) {
      setState(() => _profiles = [..._profiles, request.profile]);
      await _saveProfiles();
    }
    if (request.connect) {
      await _connect(request.profile);
    }
  }

  Future<void> _editProfile(ConnectionProfile profile) async {
    final request = await showConnectionDialog(
      context,
      existing: profile,
      takenNames: _profiles.map((p) => p.name).toSet(),
      tester: widget.serverTester,
    );
    if (request == null || !mounted) {
      return;
    }
    final index = _profiles.indexWhere((p) => p.name == profile.name);
    if (index < 0) {
      return;
    }
    setState(() {
      _profiles = List<ConnectionProfile>.of(_profiles)
        ..[index] = request.profile;
      // Editing does not reconnect, but the menu should stop showing the old
      // name against the live connection.
      if (_active?.name == profile.name) {
        _active = request.profile;
      }
    });
    await _saveProfiles();
  }

  Future<void> _deleteProfile(ConnectionProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${profile.name}?'),
        content: Text(
          'This removes ${profile.address} and the '
          '${profile.streams.length} streams saved with it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _profiles = _profiles.where((p) => p.name != profile.name).toList();
      if (_active?.name == profile.name) {
        _active = null;
        _selected = <StreamIdentifier>[];
      }
    });
    await _saveProfiles();
  }

  Future<void> _showStreamSelector() async {
    final active = _active;
    if (active == null) {
      return;
    }
    final chosen = await showStreamSelector(
      context,
      source: _sourceFor(active, _connectedEndpoint(active)),
      initialSelection: _selected,
    );
    if (chosen != null && mounted) {
      setState(() => _selected = chosen);
      // The connection carries a negotiated selection, so it has to be told
      // as well or the plots would wait on streams nobody asked the server for.
      _reader?.setStreams(chosen);
      // The selection is saved without ceremony - this is a tool for having a
      // quick look, not one that should ask permission to remember things.
      await _rememberSelection();
    }
  }

  Future<void> _showPlotOptions() async {
    final timing = await showPlotOptions(context, timing: _timing);
    if (timing != null && mounted) {
      // Every plot rebuilds from this, so nothing else has to be told.
      setState(() => _timing = timing);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _buildMenuBar(),
              const Spacer(),
              // The window is set here as well as under Options, the way a
              // reader puts zoom on the toolbar and in the View menu: the menu
              // is where the setting is found, this is where it is used.  On
              // macOS the menu bar to the left draws nothing, so this is the
              // only thing on the row.
              PlotDurationSelector(
                window: _timing.window,
                onWindowChanged: (window) =>
                    setState(() => _timing = _timing.withWindow(window)),
              ),
              const SizedBox(width: 8),
            ],
          ),
          Expanded(child: _buildPlots()),
        ],
      ),
    );
  }

  Widget _buildMenuBar() {
    return AppMenuBar(
      profiles: _profiles,
      active: _active,
      onConnect: _connect,
      onDisconnect: _disconnect,
      onCreate: _createConnection,
      onEdit: _editProfile,
      onDelete: _deleteProfile,
      onShowStreamSelector: _showStreamSelector,
      onShowPlotOptions: _showPlotOptions,
      onExit: () => exit(0),
    );
  }

  Widget _buildPlots() {
    // Nothing is plotted until there is something real to plot. Inventing a
    // trace to fill the window reads as live data and is disorienting before
    // any server has been connected to.
    if (_active == null) {
      return WelcomeView(
        message: 'Connect to a SEEDLink server to start plotting.',
        actionLabel: 'New connection...',
        onAction: _createConnection,
      );
    }
    if (_selected.isEmpty) {
      return WelcomeView(
        message: 'Connected to ${_active!.name} (${_active!.address}).\n'
            'Choose which streams to plot.',
        actionLabel: 'Stream selector...',
        onAction: _showStreamSelector,
      );
    }
    // One reader feeds every plot. Each plot registers for its own stream and
    // never touches the connection - see MultiStreamPainter.
    return MultiStreamPainter(
      streams: _selected,
      packets: _reader?.packets,
      timing: _timing,
    );
  }

}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: .center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Where to actually dial.
///
/// Not the same thing as a profile's own host and port once a tunnel is
/// involved: those describe the server as the SSH host sees it, and this is
/// the near end of the tunnel that reaches it.
class _Endpoint {
  final String host;
  final int port;
  const _Endpoint(this.host, this.port);
}
