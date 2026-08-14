import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_viewer/models/connection_profile.dart';
import 'package:waveform_viewer/models/stream_identifier.dart';
import 'package:waveform_viewer/services/profile_store.dart';

void main() {
  late Directory directory;
  late JsonFileProfileStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('waveform_profiles');
    store = JsonFileProfileStore(directory: () async => directory);
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  File profilesFile() => File('${directory.path}/${JsonFileProfileStore.fileName}');

  final utah = ConnectionProfile(
    name: 'Utah',
    host: 'localhost',
    streams: ['UU.ARUT.EHZ.01', 'UU.BGU.HHZ.01']
        .map(StreamIdentifier.fromString)
        .toList(),
  );
  final remote = ConnectionProfile(
    name: 'Remote',
    host: 'seedlink.example.org',
    port: 18500,
    useTLS: true,
  );

  group('JsonFileProfileStore', () {
    test('a missing file just means no profiles yet', () async {
      expect(profilesFile().existsSync(), isFalse);
      expect(await store.load(), isEmpty);
    });

    test('round trips profiles, order and all', () async {
      await store.save([utah, remote]);

      final loaded = await store.load();

      expect(loaded, [utah, remote]);
      expect(loaded.first.streams.map((s) => s.toString()), [
        'UU.ARUT.EHZ.01',
        'UU.BGU.HHZ.01',
      ]);
    });

    test('creates the directory if it is not there yet', () async {
      final nested = Directory('${directory.path}/does/not/exist');
      final nestedStore = JsonFileProfileStore(directory: () async => nested);

      await nestedStore.save([utah]);

      expect(await nestedStore.load(), [utah]);
    });

    test('saving replaces what was there', () async {
      await store.save([utah, remote]);
      await store.save([remote]);
      expect(await store.load(), [remote]);
    });

    test('writes a versioned, human readable file', () async {
      await store.save([utah]);

      final raw = profilesFile().readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, Object?>;

      expect(decoded['version'], JsonFileProfileStore.formatVersion);
      expect(decoded['profiles'], hasLength(1));
      // Indented so it can be edited by hand in a pinch
      expect(raw, contains('\n  '));
    });

    test('leaves no temporary file behind', () async {
      await store.save([utah]);
      final leftovers = directory
          .listSync()
          .map((entry) => entry.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('refuses a corrupt file rather than discarding it', () async {
      profilesFile().writeAsStringSync('{not json at all');

      await expectLater(store.load(), throwsA(isA<ProfileStoreException>()));
      // The file is still there to be recovered by hand
      expect(profilesFile().readAsStringSync(), '{not json at all');
    });

    test('refuses a file from a future version', () async {
      profilesFile().writeAsStringSync(
        jsonEncode(<String, Object?>{'version': 99, 'profiles': <Object?>[]}),
      );
      await expectLater(store.load(), throwsA(isA<ProfileStoreException>()));
    });

    test('refuses a file whose profiles are malformed', () async {
      profilesFile().writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': JsonFileProfileStore.formatVersion,
          'profiles': [
            {'name': 'x', 'host': 'localhost', 'port': 'not a number'},
          ],
        }),
      );
      await expectLater(store.load(), throwsA(isA<ProfileStoreException>()));
    });

    test('refuses something that is not a profiles file at all', () async {
      profilesFile().writeAsStringSync(jsonEncode(<Object?>[1, 2, 3]));
      await expectLater(store.load(), throwsA(isA<ProfileStoreException>()));
    });
  });

  group('MemoryProfileStore', () {
    test('round trips and does not alias the caller list', () async {
      final mine = [utah];
      final memory = MemoryProfileStore(mine);

      mine.add(remote);

      expect(await memory.load(), [utah]);

      await memory.save([remote]);
      expect(await memory.load(), [remote]);
    });
  });
}
