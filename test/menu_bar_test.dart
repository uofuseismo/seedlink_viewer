import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waveform_viewer/main.dart';
import 'package:waveform_viewer/models/connection_profile.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';
import 'package:waveform_viewer/services/profile_store.dart';
import 'package:waveform_viewer/services/stream_source.dart';
import 'package:waveform_viewer/views/stream_painter.dart';
import 'package:waveform_viewer/views/welcome_view.dart';

/// A source that answers with whatever the test says the server has.
class FakeSource implements StreamSource {
  final List<String> names;
  FakeSource(this.names);
  @override
  String get description => 'fake';
  @override
  Future<List<StreamIdentifier>> fetchStreams() async =>
      names.map(StreamIdentifier.fromString).toList();
}

ConnectionProfile profile(
  String name, {
  String host = 'localhost',
  List<String> streams = const [],
}) {
  return ConnectionProfile(
    name: name,
    host: host,
    streams: streams.map(StreamIdentifier.fromString).toList(),
  );
}

/// Pumps the app. Deliberately never pumpAndSettle: the plots underneath
/// redraw on a periodic timer and would never let it settle.
Future<MemoryProfileStore> pumpApp(
  WidgetTester tester, {
  List<ConnectionProfile> profiles = const [],
  List<String> serverHas = const [],
}) async {
  final store = MemoryProfileStore(profiles);
  await tester.pumpWidget(
    MyApp(
      profileStore: store,
      streamSourceBuilder: (_) => FakeSource(serverHas),
      serverTester:
          ({
            required host,
            required port,
            useTLS = false,
            certificatePath = '',
          }) async => 'TESTSERVER',
    ),
  );
  await tester.pump();
  await tester.pump();
  return store;
}

Future<void> openMenu(WidgetTester tester, String label) async {
  await tester.tap(find.text(label, findRichText: true));
  await tester.pump();
}

/// Whether a menu entry is greyed out.
bool isDisabled(WidgetTester tester, String label) {
  final button = tester.widget<MenuItemButton>(
    find
        .ancestor(
          of: find.text(label, findRichText: true),
          matching: find.byType(MenuItemButton),
        )
        .first,
  );
  return button.onPressed == null;
}

void main() {
  group('menu bar', () {
    testWidgets('offers File, Connection and Selection', (tester) async {
      await pumpApp(tester);
      expect(find.text('File', findRichText: true), findsOneWidget);
      expect(find.text('Connection', findRichText: true), findsOneWidget);
      expect(find.text('Selection', findRichText: true), findsOneWidget);
    });

    testWidgets('File offers Exit', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'File');
      expect(find.text('Exit', findRichText: true), findsOneWidget);
    });
  });

  group('on startup', () {
    testWidgets('invites a connection rather than inventing data', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.byType(WelcomeView), findsOneWidget);
      expect(find.text('Waveform Viewer'), findsOneWidget);
      expect(find.textContaining('Connect to a SEEDLink server'), findsOneWidget);
      // A trace moving across the screen with no connection reads as live data
      expect(find.byType(StreamPainter), findsNothing);
    });

    testWidgets('offers a shortcut to making one', (tester) async {
      await pumpApp(tester);
      expect(
        find.widgetWithText(FilledButton, 'New connection...'),
        findsOneWidget,
      );
    });

    testWidgets('once connected, asks which streams to plot', (tester) async {
      await pumpApp(
        tester,
        profiles: [profile('Utah')],
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      // Connected, but nothing chosen yet - so say so rather than sit blank
      expect(find.byType(WelcomeView), findsOneWidget);
      expect(find.textContaining('Choose which streams'), findsOneWidget);
      expect(find.textContaining('Utah'), findsWidgets);
      expect(find.byType(StreamPainter), findsNothing);
    });

    testWidgets('plots appear once streams are selected', (tester) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01']),
        ],
        serverHas: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(WelcomeView), findsNothing);
      expect(find.byType(StreamPainter), findsNWidgets(2));
    });
  });

  group('with nothing set up yet', () {
    testWidgets('connecting and profile upkeep are greyed out', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'Connection');

      // Nothing to connect to, so the menu points at Create instead
      expect(isDisabled(tester, 'Connect'), isTrue);
      expect(isDisabled(tester, 'Edit'), isTrue);
      expect(isDisabled(tester, 'Delete'), isTrue);
      expect(isDisabled(tester, 'Disconnect'), isTrue);
      expect(isDisabled(tester, 'Create...'), isFalse);
    });

    testWidgets('the stream selector is shut until there is a connection', (
      tester,
    ) async {
      await pumpApp(tester);
      await openMenu(tester, 'Selection');
      expect(isDisabled(tester, 'Stream selector...'), isTrue);
    });
  });

  group('with saved profiles', () {
    testWidgets('lists them under Connect', (tester) async {
      await pumpApp(
        tester,
        profiles: [profile('Utah'), profile('Remote', host: 'example.org')],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();

      expect(find.text('Utah'), findsOneWidget);
      expect(find.text('Remote'), findsOneWidget);
      // The address is shown alongside so two similar profiles can be told apart
      expect(find.text('localhost:18000'), findsOneWidget);
      expect(find.text('example.org:18000'), findsOneWidget);
    });

    testWidgets('connecting opens up the stream selector', (tester) async {
      await pumpApp(
        tester,
        profiles: [profile('Utah')],
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      await openMenu(tester, 'Selection');
      expect(isDisabled(tester, 'Stream selector...'), isFalse);
    });
  });

  group('reconciliation on connect', () {
    testWidgets('keeps the streams the server still offers', (tester) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01']),
        ],
        serverHas: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01', 'UU.OTHER.HHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Connected to Utah'), findsOneWidget);
      expect(find.textContaining('no longer offered'), findsNothing);
    });

    testWidgets('drops what is gone, says so, and rewrites the profile', (
      tester,
    ) async {
      final store = await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01']),
        ],
        // BGU has gone away since the profile was saved
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('1 saved stream is no longer offered'),
        findsOneWidget,
      );
      expect(find.textContaining('UU.BGU.HHZ.01'), findsOneWidget);

      // Dropped rather than remembered, and written straight back
      final saved = await store.load();
      expect(saved.single.streams.map((s) => '$s'), ['UU.ARUT.EHZ.01']);
    });

    testWidgets('a server that has lost everything drops everything', (
      tester,
    ) async {
      final store = await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01']),
        ],
        serverHas: const [],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('2 saved streams are no longer offered'),
        findsOneWidget,
      );
      expect((await store.load()).single.streams, isEmpty);
    });
  });

  group('delete', () {
    testWidgets('asks first and then forgets the profile', (tester) async {
      final store = await pumpApp(
        tester,
        profiles: [profile('Utah'), profile('Remote')],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Delete', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Delete Utah?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      await tester.pump();

      expect((await store.load()).map((p) => p.name), ['Remote']);
    });

    testWidgets('cancelling keeps it', (tester) async {
      final store = await pumpApp(tester, profiles: [profile('Utah')]);
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Delete', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      await tester.pump();

      expect((await store.load()).map((p) => p.name), ['Utah']);
    });
  });
}
