import 'dart:io' show exit;
import 'package:material_ui/material_ui.dart';
import './models/connection_profile.dart';
import './models/plot_timing.dart';
import './models/stream_identifier.dart';
import './services/logging.dart';
import './services/profile_store.dart';
import './services/seedlink_packet_reader.dart';
import './services/seedlink_session.dart';
import './services/stream_source.dart';
import './views/app_menu_bar.dart';
import './views/connection_dialog.dart';
import './views/multi_stream_painter.dart';
import './views/stream_selector_dialog.dart';
import './views/welcome_view.dart';
//import './native/native_bridge.dart';


void main() {
  setUpLogging();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  /// Where connection profiles are kept.  Injectable so tests can run against
  /// memory rather than the user's real profiles file.
  final ProfileStore? profileStore;

  /// Checks a server is reachable.  Injectable so tests need no server.
  final ServerTester? serverTester;

  /// Builds the source used to query a server for its streams.  Injectable
  /// for the same reason.
  final StreamSource Function(ConnectionProfile)? streamSourceBuilder;

  const MyApp({
    super.key,
    this.profileStore,
    this.serverTester,
    this.streamSourceBuilder,
  });

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SeedLink Viewer',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: .fromSeed(seedColor: Colors.red),
      ),
      home: SeedLinkViewerHome(
        profileStore: profileStore,
        serverTester: serverTester,
        streamSourceBuilder: streamSourceBuilder,
      ),
    );
  }
}

/// The main window: a menu bar over a stack of plots, one per selected stream.
class SeedLinkViewerHome extends StatefulWidget {
  final ProfileStore? profileStore;
  final ServerTester? serverTester;
  final StreamSource Function(ConnectionProfile)? streamSourceBuilder;

  const SeedLinkViewerHome({
    super.key,
    this.profileStore,
    this.serverTester,
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

  /// Every duration the plots run on.  Owned here, at the top, so that when
  /// the window becomes configurable there is one thing to change and the
  /// whole stack below stays consistent with it.
  final PlotTiming _timing = const PlotTiming();

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

  StreamSource _sourceFor(ConnectionProfile profile) {
    final builder = widget.streamSourceBuilder;
    if (builder != null) {
      return builder(profile);
    }
    return SeedLinkStreamSource(
      host: profile.host,
      port: profile.port,
      useTLS: profile.useTLS,
      certificatePath: profile.certificatePath,
    );
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
    final source = _sourceFor(profile);
    List<StreamIdentifier> available;
    try {
      available = await source.fetchStreams();
    } catch (e) {
      _report('Could not connect to ${profile.address}: $e', isError: true);
      return;
    }
    if (!mounted) {
      return;
    }
    final reconciled = profile.reconcile(available);
    setState(() {
      _active = profile;
      _selected = reconciled.kept;
    });
    await _startReader(profile);
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
  Future<void> _startReader(ConnectionProfile profile) async {
    await _reader?.stop();
    _reader = null;
    if (widget.streamSourceBuilder != null) {
      return;
    }
    try {
      final reader = await SeedLinkPacketReader.start(
        host: profile.host,
        port: profile.port,
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
      source: _sourceFor(active),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: _buildMenuBar()),
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
