import 'dart:io' show exit;
import 'package:material_ui/material_ui.dart';
import './models/stream_identifier.dart';
import './services/stream_source.dart';
import './views/stream_painter.dart';
import './views/stream_selector_dialog.dart';
//import './native/native_bridge.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Waveform Viewer',
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
      home: const WaveformViewerHome(),
    );
  }
}

/// The main window: a menu bar over a stack of plots, one per selected stream.
class WaveformViewerHome extends StatefulWidget {
  const WaveformViewerHome({super.key});

  @override
  State<WaveformViewerHome> createState() => _WaveformViewerHomeState();
}

class _WaveformViewerHomeState extends State<WaveformViewerHome> {
  // TODO replace with a source backed by a live SEEDLink connection
  static const StreamSource _source = SampleStreamSource();

  /// The streams to plot, top to bottom.
  var _selected = <StreamIdentifier>[];

  Future<void> _showStreamSelector() async {
    final chosen = await showStreamSelector(
      context,
      source: _source,
      initialSelection: _selected,
    );
    if (chosen != null && mounted) {
      setState(() => _selected = chosen);
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
    return MenuBar(
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              onPressed: () => exit(0),
              child: const MenuAcceleratorLabel('E&xit'),
            ),
          ],
          child: const MenuAcceleratorLabel('&File'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              onPressed: _showStreamSelector,
              child: const MenuAcceleratorLabel('&Stream selector...'),
            ),
          ],
          child: const MenuAcceleratorLabel('&Selection'),
        ),
      ],
    );
  }

  Widget _buildPlots() {
    // Nothing picked yet, so keep showing the simulated traces
    if (_selected.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(
          3,
          (i) => Expanded(
            child: StreamPainter(
              backgroundColor: i % 2 == 0 ? Colors.white : Colors.grey,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _selected.length; i++)
          Expanded(child: _buildPlot(_selected[i], i)),
      ],
    );
  }

  Widget _buildPlot(StreamIdentifier stream, int index) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The traces are still simulated - only the layout is driven by the
        // selection until getPackets is wired up.
        StreamPainter(
          backgroundColor: index % 2 == 0 ? Colors.white : Colors.grey,
        ),
        Positioned(
          left: 8,
          top: 4,
          child: Text(
            stream.toString(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ),
      ],
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
