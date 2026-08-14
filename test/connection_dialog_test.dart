import 'dart:io' show Directory;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waveform_viewer/models/connection_profile.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';
import 'package:waveform_viewer/views/connection_dialog.dart';

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

void main() {
  group('creating a connection', () {
    testWidgets('defaults to the plain SEEDLink port', (tester) async {
      await pumpDialog(tester);
      expect(find.text('New Connection'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('18000'), findsOneWidget);
    });

    testWidgets('ticking TLS moves to the secure port', (tester) async {
      await pumpDialog(tester);

      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      expect(find.text('18500'), findsOneWidget);

      // ... and back again when unticked
      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      expect(find.text('18000'), findsOneWidget);
    });

    testWidgets('a port the user chose is left alone by the TLS box', (
      tester,
    ) async {
      await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Port'), '9999');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use TLS'));
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

      expect(find.text('Answered: RM106'), findsOneWidget);
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
      expect(find.text('Answered: RM106'), findsOneWidget);

      // The result described the old address, so it must not linger
      await tester.enterText(fieldLabelled('Host'), 'elsewhere');
      await tester.pumpAndSettle();
      expect(find.text('Answered: RM106'), findsNothing);
    });
  });

  group('certificates', () {
    testWidgets('are only asked about when TLS is on', (tester) async {
      await pumpDialog(tester);
      expect(find.text('System certificates'), findsNothing);

      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      expect(find.text('System certificates'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Browse...'), findsOneWidget);
    });

    testWidgets('default to the system store', (tester) async {
      final holder = await pumpDialog(tester);
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use TLS'));
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
      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();

      expect(openedAt, defaultCertificateDirectory());
      expect(find.text('/srv/my-ca'), findsOneWidget);
      expect(find.text('System certificates'), findsNothing);
    });

    testWidgets('a chosen directory is saved with the profile', (tester) async {
      final holder = await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use TLS'));
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
      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();

      expect(find.text('System certificates'), findsOneWidget);
    });

    testWidgets('clearing goes back to the system store', (tester) async {
      await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      expect(find.text('/srv/my-ca'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.text('System certificates'), findsOneWidget);
    });

    testWidgets('turning TLS off forgets the certificate', (tester) async {
      final holder = await pumpDialog(
        tester,
        directoryPicker: ({String? initialDirectory}) async => '/srv/my-ca',
      );
      await tester.enterText(fieldLabelled('Host'), 'localhost');
      await tester.tap(find.text('Use TLS'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Browse...'));
      await tester.pumpAndSettle();
      // Changed their mind about TLS entirely
      await tester.tap(find.text('Use TLS'));
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
      await tester.tap(find.text('Use TLS'));
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
