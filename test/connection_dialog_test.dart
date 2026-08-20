import 'dart:io' show Directory;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:seedlink_viewer/models/connection_profile.dart';
import 'package:seedlink_viewer/models/ssh_tunnel_config.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';
import 'package:seedlink_viewer/views/connection_dialog.dart';

/// A tester that answers however the test wants it to.
ServerTester answering(String identifier) {
  return ({required host, required port, useTLS = false, certificatePath = ''})
      async => identifier;
}

ServerTester failing(String message) {
  return ({required host, required port, useTLS = false, certificatePath = ''})
      async => throw Exception(message);
}

/// The dialog's result is only available after it closes, so tests read it
/// back through this holder.
class ResultHolder {
  ConnectionRequest? value;
}

/// Opens the dialog and hands back somewhere to look for its result.
Future<ResultHolder> pumpDialog(
  WidgetTester tester, {
  ConnectionProfile? existing,
  Set<String> takenNames = const <String>{},
  ServerTester? serverTester,
  DirectoryPicker? directoryPicker,
  FilePicker? filePicker,
}) async {
  final holder = ResultHolder();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              holder.value = await showConnectionDialog(
                context,
                existing: existing,
                takenNames: takenNames,
                tester: serverTester ?? answering('RM106'),
                directoryPicker: directoryPicker,
                filePicker: filePicker,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return holder;
}

Finder fieldLabelled(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

/// What a field actually contains.
///
/// find.text would also match the hint, which InputDecorator keeps in the tree
/// behind the value rather than removing.
String fieldText(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(
        of: fieldLabelled(label),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// Moves to the SSH tunnel tab.
Future<void> chooseTunnel(WidgetTester tester) async {
  await tester.tap(find.text('SSH tunnel'));
  await tester.pumpAndSettle();
}

Future<void> chooseDirect(WidgetTester tester) async {
  await tester.tap(find.text('Direct'));
  await tester.pumpAndSettle();
}

/// Fills in a complete, valid tunnel.
Future<void> fillTunnel(
  WidgetTester tester, {
  String sshHost = 'jump.example.org',
  String user = 'bbaker',
  String key = '/home/bbaker/.ssh/id_ed25519',
}) async {
  await tester.enterText(fieldLabelled('SSH host'), sshHost);
  await tester.enterText(fieldLabelled('User'), user);
  await tester.enterText(fieldLabelled('Private key'), key);
  await tester.pumpAndSettle();
}

void main() {
  group('the route', () {
    testWidgets('starts Direct, and says nothing about ssh', (tester) async {
      await pumpDialog(tester);

      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('SSH tunnel'), findsOneWidget);
      // Closed by default: most connections do not go through a jump host.
      expect(fieldLabelled('SSH host'), findsNothing);
      expect(fieldLabelled('User'), findsNothing);
    });

    testWidgets('the tunnel tab asks for four things and no more', (
      tester,
    ) async {
      await pumpDialog(tester);
      await chooseTunnel(tester);

      expect(fieldLabelled('SSH host'), findsOneWidget);
      expect(fieldLabelled('User'), findsOneWidget);
      expect(fieldLabelled('Private key'), findsOneWidget);

      // Neither of these is the user's business: the passphrase is asked for
      // only if the key turns out to need one, and the local port is whatever
      // the operating system hands out.
      expect(find.textContaining('Passphrase'), findsNothing);
      expect(find.textContaining('Local port'), findsNothing);
    });

    testWidgets('it says whose view of the server it is asking for', (
      tester,
    ) async {
      await pumpDialog(tester);
      await chooseTunnel(tester);

      // The one thing that is easy to get wrong on this tab.
      expect(
        find.text('SEEDLink server, as seen from the SSH host'),
        findsOneWidget,
      );
    });

    testWidgets('and fills the usual answer in', (tester) async {
      await pumpDialog(tester);
      await chooseTunnel(tester);

      // The server is normally on the box being logged in to.
      expect(fieldText(tester, 'Host'), 'localhost');
    });

    testWidgets('an existing tunnelled profile opens on the right tab', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        existing: ConnectionProfile(
          name: 'Behind the jump host',
          host: 'localhost',
          tunnel: const SshTunnelConfig(
            sshHost: 'jump.example.org',
            user: 'bbaker',
            privateKeyPath: '/home/bbaker/.ssh/id_ed25519',
          ),
        ),
      );

      expect(fieldLabelled('SSH host'), findsOneWidget);
      expect(fieldText(tester, 'SSH host'), 'jump.example.org');
      expect(fieldText(tester, 'User'), 'bbaker');
    });
  });

  group('saving a tunnelled connection', () {
    testWidgets('carries the tunnel', (tester) async {
      final holder = await pumpDialog(tester);
      await chooseTunnel(tester);
      await fillTunnel(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      final tunnel = holder.value!.profile.tunnel!;
      expect(tunnel.sshHost, 'jump.example.org');
      expect(tunnel.user, 'bbaker');
      expect(tunnel.privateKeyPath, '/home/bbaker/.ssh/id_ed25519');
      expect(tunnel.sshPort, 22, reason: 'left alone means the usual one');
      // The profile's own address is still the far end, for the tunnel to be
      // pointed at.
      expect(holder.value!.profile.host, 'localhost');
      expect(holder.value!.profile.port, 18000);
    });

    testWidgets('a half filled tunnel is refused rather than saved', (
      tester,
    ) async {
      final holder = await pumpDialog(tester);
      await chooseTunnel(tester);
      await tester.enterText(fieldLabelled('SSH host'), 'jump.example.org');
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(holder.value, isNull, reason: 'should not have closed');
      expect(find.text('Enter the user to log in as'), findsOneWidget);
      expect(
        find.text('Choose the private key to log in with'),
        findsOneWidget,
      );
    });

    testWidgets('going back to Direct drops it', (tester) async {
      final holder = await pumpDialog(tester);
      await chooseTunnel(tester);
      await fillTunnel(tester);
      await chooseDirect(tester);
      await tester.enterText(fieldLabelled('Host'), 'rtserve.example.org');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      // Saving a tunnel nothing will open would be worse than losing what was
      // typed - the profile would claim a route it does not take.
      expect(holder.value!.profile.tunnel, isNull);
    });

    testWidgets('Browse fills the key in', (tester) async {
      await pumpDialog(
        tester,
        filePicker: ({String? initialDirectory}) async =>
            '/home/bbaker/.ssh/id_rsa',
      );
      await chooseTunnel(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();

      expect(fieldText(tester, 'Private key'), '/home/bbaker/.ssh/id_rsa');
    });
  });

  group('creating a connection', () {
    testWidgets('defaults to the plain SEEDLink port', (tester) async {
      await pumpDialog(tester);
      expect(find.text('New Connection'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('18000'), findsOneWidget);
    });

    testWidgets('ticking TLS moves to the secure port', (tester) async {
      await pumpDialog(tester);

      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      expect(find.text('18500'), findsOneWidget);

      // ... and back again when unticked
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      expect(find.text('18000'), findsOneWidget);
    });

    testWidgets('a port the user chose is left alone by the TLS box', (
      tester,
    ) async {
      await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Port'), '9999');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();

      expect(find.text('9999'), findsOneWidget);
    });

    testWidgets('will not connect without a host', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a host'), findsOneWidget);
      // Still open
      expect(find.text('New Connection'), findsOneWidget);
      expect(holder.value, isNull);
    });

    testWidgets('rejects a port outside the legal range', (tester) async {
      await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.enterText(fieldLabelled('Port'), '99999');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
    });

    testWidgets('an unsaved connection still connects', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(holder.value, isNotNull);
      expect(holder.value!.connect, isTrue);
      expect(holder.value!.save, isFalse);
      expect(holder.value!.profile.host, 'localhost');
      expect(holder.value!.profile.port, 18000);
    });

    testWidgets('saving names the profile after the address by default', (
      tester,
    ) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Save as profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(holder.value!.save, isTrue);
      expect(holder.value!.profile.name, 'localhost:18000');
    });

    testWidgets('a typed name wins over the default', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Save as profile'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldLabelled('Profile name'), 'Utah');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(holder.value!.profile.name, 'Utah');
    });

    testWidgets('refuses a name another profile already has', (tester) async {
      await pumpDialog(tester, takenNames: {'Utah'});
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Save as profile'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldLabelled('Profile name'), 'Utah');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(
        find.text('A profile called "Utah" already exists'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel returns nothing', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(holder.value, isNull);
    });
  });

  group('the Test button', () {
    testWidgets('reports what the server says', (tester) async {
      await pumpDialog(tester, serverTester: answering('RM106'));
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();

      expect(find.text('Received response from RM106'), findsOneWidget);
    });

    testWidgets('reports a server that will not answer', (tester) async {
      await pumpDialog(tester, serverTester: failing('Connection refused'));
      await tester.enterText(fieldLabelled('Host'), 'nowhere');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection refused'), findsOneWidget);
    });

    testWidgets('asks for a host before bothering the network', (tester) async {
      var called = false;
      await pumpDialog(
        tester,
        serverTester:
            ({
              required host,
              required port,
              useTLS = false,
              certificatePath = '',
            }) async {
              called = true;
              return 'nope';
            },
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a host and a port first'), findsOneWidget);
      expect(called, isFalse);
    });

    testWidgets('a stale result is cleared when the address changes', (
      tester,
    ) async {
      await pumpDialog(tester, serverTester: answering('RM106'));
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();
      expect(find.text('Received response from RM106'), findsOneWidget);

      // The result described the old address, so it must not linger
      await tester.enterText(fieldLabelled('Host'), 'elsewhere');
      await tester.pumpAndSettle();
      expect(find.text('Received response from RM106'), findsNothing);
    });
  });

  group('certificates', () {
    testWidgets('are only asked about when TLS is on', (tester) async {
      await pumpDialog(tester);
      expect(find.text('System store'), findsNothing);

      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      expect(find.text('System store'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Browse...'), findsOneWidget);
      // Labelled for what it decides, not for what it holds: a bare path
      // reads as the user's own credential rather than as who to believe.
      expect(find.text('Trust certificates from:'), findsOneWidget);
    });

    testWidgets('default to the system store', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      // Empty means "whatever this machine already trusts"
      expect(holder.value!.profile.certificatePath, '');
      expect(holder.value!.profile.useTLS, isTrue);
    });

    testWidgets('browsing opens where certificates live', (tester) async {
      String? openedAt;
      await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async {
          openedAt = initialDirectory;
          return '/srv/my-ca';
        },
      );
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();

      expect(openedAt, defaultCertificateDirectory());
      expect(find.text('/srv/my-ca'), findsOneWidget);
      expect(find.text('System store'), findsNothing);
    });

    testWidgets('a chosen directory is saved with the profile', (tester) async {
      final holder = await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(holder.value!.profile.certificatePath, '/srv/my-ca');
    });

    testWidgets('cancelling the chooser changes nothing', (tester) async {
      await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => null,
      );
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();

      expect(find.text('System store'), findsOneWidget);
    });

    testWidgets('clearing goes back to the system store', (tester) async {
      await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      expect(find.text('/srv/my-ca'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.text('System store'), findsOneWidget);
    });

    testWidgets('turning TLS off forgets the certificate', (tester) async {
      final holder = await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      // Changed their mind about TLS entirely
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();

      // No point saving a certificate nothing will consult
      expect(holder.value!.profile.useTLS, isFalse);
      expect(holder.value!.profile.certificatePath, '');
    });

    testWidgets('the Test button uses the chosen certificate', (tester) async {
      String? testedWith;
      await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
        serverTester:
            ({
              required host,
              required port,
              useTLS = false,
              certificatePath = '',
            }) async {
              testedWith = certificatePath;
              return 'RM106';
            },
      );
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use Certificates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();

      expect(testedWith, '/srv/my-ca');
    });

    testWidgets('an edited profile opens with its certificate', (tester) async {
      await pumpDialog(
        tester,
        existing: ConnectionProfile(
          name: 'Secure',
          host: 'example.org',
          port: 18500,
          useTLS: true,
          certificatePath: '/srv/my-ca',
        ),
      );
      expect(find.text('/srv/my-ca'), findsOneWidget);
    });
  });

  group('known certificate locations', () {
    test('point at a real directory or admit there is none', () {
      final found = defaultCertificateDirectory();
      if (found != null) {
        expect(knownCertificateDirectories, contains(found));
        expect(Directory(found).existsSync(), isTrue);
      }
    });
  });

  group('editing a profile', () {
    final utah = ConnectionProfile(
      name: 'Utah',
      host: 'localhost',
      port: 18000,
      streams: ['UU.ARUT.EHZ.01'].map(StreamIdentifier.fromString).toList(),
    );

    testWidgets('opens filled in, and saves rather than connecting', (
      tester,
    ) async {
      final holder = await pumpDialog(tester, existing: utah);

      expect(find.text('Edit Utah'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      // No opt in checkbox - editing always writes back
      expect(find.text('Save as profile'), findsNothing);

      await tester.enterText(fieldLabelled('Host'), 'elsewhere.org');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(holder.value!.save, isTrue);
      // Fixing a typo should not disturb the connection you are on
      expect(holder.value!.connect, isFalse);
      expect(holder.value!.profile.host, 'elsewhere.org');
    });

    testWidgets('keeps the streams the profile already remembers', (
      tester,
    ) async {
      final holder = await pumpDialog(tester, existing: utah);
      await tester.enterText(fieldLabelled('Host'), 'elsewhere.org');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(holder.value!.profile.streams.map((s) => '$s'), [
        'UU.ARUT.EHZ.01',
      ]);
    });

    testWidgets('keeping its own name is not a clash', (tester) async {
      final holder = await pumpDialog(
        tester,
        existing: utah,
        takenNames: {'Utah', 'Remote'},
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(holder.value, isNotNull);
      expect(holder.value!.profile.name, 'Utah');
    });
  });
}
