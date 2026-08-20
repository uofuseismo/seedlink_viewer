import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/main.dart';
import 'package:seedlink_viewer/models/connection_profile.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/profile_store.dart';
import 'package:seedlink_viewer/services/stream_source.dart';
import 'package:seedlink_viewer/views/connection_dialog.dart';
import 'package:seedlink_viewer/views/plot_duration_selector.dart';
import 'package:seedlink_viewer/views/stream_painter.dart';
import 'package:seedlink_viewer/views/stream_selector_dialog.dart';
import 'package:seedlink_viewer/views/welcome_view.dart';

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

/// Every label in a platform menu, flattened, in the order it is declared.
List<String> platformMenuLabels(WidgetTester tester) {
  final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
  final labels = <String>[];
  void visit(PlatformMenuItem item) {
    if (item is PlatformMenuItemGroup) {
      item.members.forEach(visit);
      return;
    }
    labels.add(item.label);
    if (item is PlatformMenu) {
      item.menus.forEach(visit);
    }
  }

  bar.menus.forEach(visit);
  return labels;
}

/// The platform menu item carrying a label, wherever it sits in the tree.
PlatformMenuItem platformItem(WidgetTester tester, String label) {
  final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
  PlatformMenuItem? found;
  void visit(PlatformMenuItem item) {
    if (item.label == label) {
      found ??= item;
    }
    if (item is PlatformMenuItemGroup) {
      item.members.forEach(visit);
    } else if (item is PlatformMenu) {
      item.menus.forEach(visit);
    }
  }

  bar.menus.forEach(visit);
  return found ?? (throw StateError('no platform menu item labelled $label'));
}

/// SingleActivator compares by identity, so two activators for the same
/// keystroke are never equal. Compare what the keystroke actually is.
void expectShortcut(
  MenuSerializableShortcut? shortcut,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
}) {
  expect(shortcut, isA<SingleActivator>());
  final activator = shortcut! as SingleActivator;
  expect(activator.trigger, key);
  expect(activator.control, control, reason: 'control modifier');
  expect(activator.meta, meta, reason: 'meta modifier');
}

/// The app draws a different menu bar on macOS, and flutter_test does not
/// override the target platform - it reports whichever machine the suite is
/// running on, so on a Mac every test below would otherwise be looking for a
/// menu bar that is not in the window. Every test says which bar it is about.
final inWindowMenuBar = TargetPlatformVariant.only(TargetPlatform.linux);
final systemMenuBar = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  group('menu bar', () {
    testWidgets('offers File, Connection and Selection', (tester) async {
      await pumpApp(tester);
      expect(find.text('File', findRichText: true), findsOneWidget);
      expect(find.text('Connection', findRichText: true), findsOneWidget);
      expect(find.text('Selection', findRichText: true), findsOneWidget);
    }, variant: inWindowMenuBar);

    testWidgets('File offers Exit', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'File');
      expect(find.text('Exit', findRichText: true), findsOneWidget);
    }, variant: inWindowMenuBar);
  });

  group('on macOS the menu goes to the system bar', () {
    testWidgets('nothing is drawn in the window', (tester) async {
      await pumpApp(tester);

      expect(find.byType(PlatformMenuBar), findsOneWidget);
      // A second menu bar inside the window is the whole thing being avoided:
      // the runner already installs a system one from MainMenu.xib.
      expect(find.byType(MenuBar), findsNothing);
    }, variant: systemMenuBar);

    testWidgets('the platform provides About and Quit, not File and Exit', (
      tester,
    ) async {
      await pumpApp(tester);
      final labels = platformMenuLabels(tester);

      // Setting a PlatformMenuBar replaces the whole main menu, so losing
      // these would lose Cmd-Q with them.
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final provided = <PlatformProvidedMenuItemType>[];
      void collect(PlatformMenuItem item) {
        if (item is PlatformProvidedMenuItem) provided.add(item.type);
        if (item is PlatformMenuItemGroup) item.members.forEach(collect);
        if (item is PlatformMenu) item.menus.forEach(collect);
      }

      bar.menus.forEach(collect);
      expect(provided, contains(PlatformProvidedMenuItemType.about));
      expect(provided, contains(PlatformProvidedMenuItemType.quit));

      // Quitting belongs to the application menu on macOS, so there is no File
      expect(labels, isNot(contains('File')));
      expect(labels, isNot(contains('Exit')));
      expect(labels, containsAll(<String>['Connection', 'Selection']));
    }, variant: systemMenuBar);

    testWidgets('accelerator markers are stripped', (tester) async {
      await pumpApp(tester);
      final labels = platformMenuLabels(tester);

      // macOS has no Alt accelerators, so '&Disconnect' must not reach the OS
      expect(labels, contains('Disconnect'));
      expect(labels.where((label) => label.contains('&')), isEmpty);
    }, variant: systemMenuBar);

    testWidgets('a profile carries its address and its tick in the label', (
      tester,
    ) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah'),
          profile('Remote', host: 'example.org'),
        ],
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      final labels = platformMenuLabels(tester);

      // A platform item is a label and nothing else, so the address that the
      // Material menu hangs in a trailing widget has to be in the text
      expect(
        labels.where((label) => label.contains('localhost:18000')),
        isNotEmpty,
      );
      expect(
        labels.where((label) => label.contains('example.org:18000')),
        isNotEmpty,
      );
      // Nothing connected yet, so nothing is ticked
      expect(labels.where((label) => label.startsWith('✓')), isEmpty);
    }, variant: systemMenuBar);

    testWidgets('what cannot be done yet is disabled, not missing', (
      tester,
    ) async {
      await pumpApp(tester);
      final labels = platformMenuLabels(tester);

      // No profiles, so Connect is a dead item rather than an empty submenu
      expect(labels, contains('Connect'));
      expect(platformItem(tester, 'Connect'), isNot(isA<PlatformMenu>()));
      expect(platformItem(tester, 'Connect').onSelected, isNull);
      expect(platformItem(tester, 'Disconnect').onSelected, isNull);
      expect(platformItem(tester, 'Stream selector...').onSelected, isNull);
      // Creating one is the way out of an empty first run
      expect(platformItem(tester, 'Create...').onSelected, isNotNull);
    }, variant: systemMenuBar);

    testWidgets('selecting a profile connects to it', (tester) async {
      await pumpApp(
        tester,
        profiles: [profile('Utah')],
        serverHas: ['UU.ARUT.EHZ.01'],
      );

      platformItem(tester, 'Utah  —  localhost:18000').onSelected!();
      await tester.pump();
      await tester.pump();

      // The confirmation and the prompt for streams both name it
      expect(find.textContaining('Connected to Utah'), findsWidgets);
      // Now connected, the tick marks which one
      expect(
        platformMenuLabels(tester),
        contains('✓ Utah  —  localhost:18000'),
      );
      expect(platformItem(tester, 'Disconnect').onSelected, isNotNull);
    }, variant: systemMenuBar);
  });

  group('plot options', () {
    testWidgets('Options offers Plot... and says what it does', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'Options');

      expect(find.text('Plot...', findRichText: true), findsOneWidget);
      // The label alone does not say what it will do, so this one is spelled
      // out on hover.
      expect(
        tester
            .widget<Tooltip>(
              find
                  .ancestor(
                    of: find.text('Plot...', findRichText: true),
                    matching: find.byType(Tooltip),
                  )
                  .first,
            )
            .message,
        'Specify the plotting options.',
      );
    }, variant: inWindowMenuBar);

    testWidgets('it is open before there is anything to plot', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'Options');

      // How much time a plot shows is worth setting before connecting, so
      // unlike the stream selector this is not gated on a connection.
      expect(isDisabled(tester, 'Plot...'), isFalse);
    }, variant: inWindowMenuBar);

    testWidgets('choosing a duration reaches the plots', (tester) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01']),
        ],
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<StreamPainter>(find.byType(StreamPainter)).timing.window,
        const Duration(minutes: 2),
      );

      await openMenu(tester, 'Options');
      await tester.tap(find.text('Plot...', findRichText: true));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '10 min'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pump();
      await tester.pump();

      // One value at the top drives every plot, so the trace redraws over the
      // new window without anything else being told.
      final painter = tester.widget<StreamPainter>(find.byType(StreamPainter));
      expect(painter.timing.window, const Duration(minutes: 10));
      expect(
        painter.timing.history,
        greaterThanOrEqualTo(const Duration(minutes: 10)),
      );
    }, variant: inWindowMenuBar);

    testWidgets('the dropdown in the window drives the plots too', (
      tester,
    ) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah', streams: ['UU.ARUT.EHZ.01']),
        ],
        serverHas: ['UU.ARUT.EHZ.01'],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Utah'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(PlotDurationSelector));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('5 min'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<StreamPainter>(find.byType(StreamPainter)).timing.window,
        const Duration(minutes: 5),
      );
    }, variant: inWindowMenuBar);

    testWidgets('the dialog and the dropdown never disagree', (tester) async {
      await pumpApp(tester);

      // Two ways into one setting, so each has to show what the other did.
      await openMenu(tester, 'Options');
      await tester.tap(find.text('Plot...', findRichText: true));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '7');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(PlotDurationSelector),
          matching: find.text('7 min'),
        ),
        findsOneWidget,
      );
    }, variant: inWindowMenuBar);

    testWidgets('the macOS item carries the same tooltip', (tester) async {
      await pumpApp(tester);
      // A PlatformMenuItem takes a tooltip directly rather than needing a
      // widget wrapped around its label.
      expect(
        platformItem(tester, 'Plot...').tooltip,
        'Specify the plotting options.',
      );
    }, variant: systemMenuBar);
  });

  group('keyboard shortcuts', () {
    testWidgets('Ctrl-N creates a connection without opening the menu', (
      tester,
    ) async {
      await pumpApp(tester);
      // Deliberately no openMenu first: a shortcut that only works while its
      // own menu is showing is no shortcut at all.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(ConnectionDialog), findsOneWidget);
    }, variant: inWindowMenuBar);

    testWidgets('Ctrl-L opens the stream selector once connected', (
      tester,
    ) async {
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

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(StreamSelectorDialog), findsOneWidget);
    }, variant: inWindowMenuBar);

    testWidgets('a shortcut for something greyed out does nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      // Nothing is connected, so Ctrl-L must be inert rather than opening a
      // selector onto a server that was never asked what it has.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(StreamSelectorDialog), findsNothing);
      expect(find.byType(WelcomeView), findsOneWidget);
    }, variant: inWindowMenuBar);

    testWidgets('a dialog closes the menu rather than stacking a second', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byType(ConnectionDialog), findsOneWidget);

      // A modal covers the menu bar so it cannot be clicked, but the keystroke
      // still reaches it - and a second dialog on top of the first is a mess
      // to unwind.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(ConnectionDialog), findsOneWidget);
    }, variant: inWindowMenuBar);

    testWidgets('the menu shows the keystroke beside the item', (tester) async {
      await pumpApp(tester);
      await openMenu(tester, 'Connection');

      final create = tester.widget<MenuItemButton>(
        find
            .ancestor(
              of: find.text('Create...', findRichText: true),
              matching: find.byType(MenuItemButton),
            )
            .first,
      );
      expectShortcut(create.shortcut, LogicalKeyboardKey.keyN, control: true);
    }, variant: inWindowMenuBar);
  });

  group('on macOS the shortcuts go to the system menu', () {
    testWidgets('they use Cmd and are carried on the platform item', (
      tester,
    ) async {
      await pumpApp(tester);

      // The OS matches the keystroke itself, so what matters is that the
      // right one is declared - and that it is Cmd rather than Ctrl.
      expectShortcut(
        platformItem(tester, 'Create...').shortcut,
        LogicalKeyboardKey.keyN,
        meta: true,
      );
      expectShortcut(
        platformItem(tester, 'Stream selector...').shortcut,
        LogicalKeyboardKey.keyL,
        meta: true,
      );
    }, variant: systemMenuBar);

    testWidgets('nothing is registered in dart, so nothing fires twice', (
      tester,
    ) async {
      await pumpApp(tester);
      // macOS acts on the platform menu's own shortcuts. A dart registration
      // as well would open two dialogs on one keystroke.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(find.byType(ConnectionDialog), findsNothing);
    }, variant: systemMenuBar);
  });

  group('on startup', () {
    testWidgets('invites a connection rather than inventing data', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.byType(WelcomeView), findsOneWidget);
      expect(find.text('SeedLink Viewer'), findsOneWidget);
      expect(
        find.textContaining('Connect to a SEEDLink server'),
        findsOneWidget,
      );
      // A trace moving across the screen with no connection reads as live data
      expect(find.byType(StreamPainter), findsNothing);
    }, variant: inWindowMenuBar);

    testWidgets('offers a shortcut to making one', (tester) async {
      await pumpApp(tester);
      expect(
        find.widgetWithText(FilledButton, 'New connection...'),
        findsOneWidget,
      );
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);
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
    }, variant: inWindowMenuBar);

    testWidgets('the stream selector is shut until there is a connection', (
      tester,
    ) async {
      await pumpApp(tester);
      await openMenu(tester, 'Selection');
      expect(isDisabled(tester, 'Stream selector...'), isTrue);
    }, variant: inWindowMenuBar);
  });

  group('with saved profiles', () {
    testWidgets('lists them under Connect', (tester) async {
      await pumpApp(
        tester,
        profiles: [
          profile('Utah'),
          profile('Remote', host: 'example.org'),
        ],
      );
      await openMenu(tester, 'Connection');
      await tester.tap(find.text('Connect', findRichText: true));
      await tester.pump();

      expect(find.text('Utah'), findsOneWidget);
      expect(find.text('Remote'), findsOneWidget);
      // The address is shown alongside so two similar profiles can be told apart
      expect(find.text('localhost:18000'), findsOneWidget);
      expect(find.text('example.org:18000'), findsOneWidget);
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);
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
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);
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
    }, variant: inWindowMenuBar);

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
    }, variant: inWindowMenuBar);
  });
}
