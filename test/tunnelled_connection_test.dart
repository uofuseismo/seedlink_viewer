import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/main.dart';
import 'package:seedlink_viewer/models/connection_profile.dart';
import 'package:seedlink_viewer/models/ssh_tunnel_config.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/services/profile_store.dart';
import 'package:seedlink_viewer/services/ssh_tunnel.dart';
import 'package:seedlink_viewer/services/stream_source.dart';
import 'package:seedlink_viewer/views/passphrase_dialog.dart';

const tunnelConfig = SshTunnelConfig(
  sshHost: 'jump.example.org',
  user: 'bbaker',
  privateKeyPath: '/home/bbaker/.ssh/id_ed25519',
);

/// A tunnel that forwards nothing but remembers what it was asked to do.
class FakeTunnel implements Tunnel {
  @override
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final SshTunnelConfig config;
  var closed = false;

  FakeTunnel({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.config,
  });

  @override
  Future<void> close() async => closed = true;
}

/// Records every tunnel opened, so a test can look at what was asked for.
class TunnelLog {
  final opened = <FakeTunnel>[];
  Object? failWith;

  /// Answered when the opener decides a passphrase is needed.
  String? Function()? passphraseAnswer;

  TunnelOpener get opener =>
      ({
        required config,
        required remoteHost,
        required remotePort,
        required onPassphrase,
      }) async {
        if (passphraseAnswer != null) {
          final answer = await onPassphrase(
            keyPath: config.privateKeyPath,
            retry: false,
          );
          if (answer == null) {
            throw const SshTunnelCancelled();
          }
        }
        final failure = failWith;
        if (failure != null) {
          throw failure;
        }
        final tunnel = FakeTunnel(
          // A port the operating system picked, deliberately not 18000.
          localPort: 49152 + opened.length,
          remoteHost: remoteHost,
          remotePort: remotePort,
          config: config,
        );
        opened.add(tunnel);
        return tunnel;
      };
}

/// Records the address each stream query was aimed at.
class RecordingSource implements StreamSource {
  final List<String> names;
  RecordingSource(this.names);
  @override
  String get description => 'fake';
  @override
  Future<List<StreamIdentifier>> fetchStreams() async =>
      names.map(StreamIdentifier.fromString).toList();
}

Future<MemoryProfileStore> pumpApp(
  WidgetTester tester, {
  required List<ConnectionProfile> profiles,
  required TunnelLog tunnels,
  List<String> serverHas = const ['UU.ARUT.EHZ.01'],
}) async {
  final store = MemoryProfileStore(profiles);
  await tester.pumpWidget(
    MyApp(
      profileStore: store,
      tunnelOpener: tunnels.opener,
      streamSourceBuilder: (_) => RecordingSource(serverHas),
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

ConnectionProfile tunnelled({String name = 'Behind the jump host'}) {
  return ConnectionProfile(
    name: name,
    host: 'localhost',
    port: 18000,
    tunnel: tunnelConfig,
    streams: [StreamIdentifier.fromString('UU.ARUT.EHZ.01')],
  );
}

Future<void> connectTo(WidgetTester tester, String name) async {
  await tester.tap(find.text('Connection', findRichText: true));
  await tester.pump();
  await tester.tap(find.text('Connect', findRichText: true));
  await tester.pump();
  await tester.tap(find.text(name));
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {});

  group('connecting through a tunnel', () {
    testWidgets('opens one, pointed at the far end of the profile', (
      tester,
    ) async {
      final tunnels = TunnelLog();
      await pumpApp(
        tester,
        profiles: [tunnelled()],
        tunnels: tunnels,
      );
      await connectTo(tester, 'Behind the jump host');

      expect(tunnels.opened, hasLength(1));
      final tunnel = tunnels.opened.single;
      // The profile's own host and port describe the server as the SSH host
      // sees it, which is exactly what the tunnel forwards to.
      expect(tunnel.remoteHost, 'localhost');
      expect(tunnel.remotePort, 18000);
      expect(tunnel.config, tunnelConfig);
    });

    testWidgets('a direct profile opens none', (tester) async {
      final tunnels = TunnelLog();
      await pumpApp(
        tester,
        profiles: [
          ConnectionProfile(name: 'Utah', host: 'rtserve.example.org'),
        ],
        tunnels: tunnels,
      );
      await connectTo(tester, 'Utah');

      expect(tunnels.opened, isEmpty);
    });

    testWidgets('says how it got there when it worked', (tester) async {
      final tunnels = TunnelLog();
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');

      // localhost:18000 on its own would name a server on the user's own
      // machine, and there is usually not one.
      expect(
        find.textContaining('via bbaker@jump.example.org'),
        findsWidgets,
      );
    });

    testWidgets('disconnecting closes it', (tester) async {
      final tunnels = TunnelLog();
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');
      expect(tunnels.opened.single.closed, isFalse);

      await tester.tap(find.text('Connection', findRichText: true));
      await tester.pump();
      await tester.tap(find.text('Disconnect', findRichText: true));
      await tester.pump();
      await tester.pump();

      expect(tunnels.opened.single.closed, isTrue);
    });

    testWidgets('connecting again does not leave the old one open', (
      tester,
    ) async {
      final tunnels = TunnelLog();
      await pumpApp(
        tester,
        profiles: [tunnelled(), tunnelled(name: 'Another one')],
        tunnels: tunnels,
      );
      await connectTo(tester, 'Behind the jump host');
      await connectTo(tester, 'Another one');

      expect(tunnels.opened, hasLength(2));
      expect(tunnels.opened.first.closed, isTrue, reason: 'leaked a tunnel');
      expect(tunnels.opened.last.closed, isFalse);
    });
  });

  group('when the tunnel will not open', () {
    testWidgets('says so and stays disconnected', (tester) async {
      final tunnels = TunnelLog()
        ..failWith = const SshTunnelException('Permission denied (publickey)');
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');
      await tester.pump();

      expect(
        find.textContaining('Permission denied (publickey)'),
        findsOneWidget,
      );
      // Nothing was plotted, and the welcome view is still asking for a
      // connection rather than the app looking half connected.
      expect(find.textContaining('Connect to a SEEDLink server'), findsWidgets);
    });

    testWidgets('giving up on the passphrase is quiet', (tester) async {
      final tunnels = TunnelLog()..passphraseAnswer = () => null;
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');
      await tester.pumpAndSettle();

      // Closing the prompt is a decision, not a failure, so there is nothing
      // to report.
      expect(tunnels.opened, isEmpty);
      expect(find.textContaining('Could not open the tunnel'), findsNothing);
    });
  });

  group('the passphrase prompt', () {
    testWidgets('appears only when the opener asks for one', (tester) async {
      final tunnels = TunnelLog()..passphraseAnswer = () => 'correct horse';
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');
      await tester.pump();

      expect(find.byType(PassphraseDialog), findsOneWidget);
      // It names the key, since a user with several is otherwise guessing.
      expect(
        find.text('/home/bbaker/.ssh/id_ed25519'),
        findsOneWidget,
      );
      expect(find.textContaining('never saved'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'correct horse');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();

      expect(tunnels.opened, hasLength(1));
    });

    testWidgets('is never shown for a key that does not need one', (
      tester,
    ) async {
      final tunnels = TunnelLog();
      await pumpApp(tester, profiles: [tunnelled()], tunnels: tunnels);
      await connectTo(tester, 'Behind the jump host');
      await tester.pump();

      // The ssh-copy-id case: a user set up the usual way is never asked.
      expect(find.byType(PassphraseDialog), findsNothing);
    });
  });
}
