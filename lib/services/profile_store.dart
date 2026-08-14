import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/connection_profile.dart';

/// Where connection profiles are kept between sessions.
abstract class ProfileStore {
  /// The saved profiles, in the order they should be listed.
  Future<List<ConnectionProfile>> load();

  /// Replaces everything that was saved.
  Future<void> save(List<ConnectionProfile> profiles);
}

/// The saved profiles could not be read.
class ProfileStoreException implements Exception {
  final String message;
  const ProfileStoreException(this.message);
  @override
  String toString() => message;
}

/// Keeps profiles in a JSON file under the application support directory -
/// ~/.local/share/waveform_viewer on linux, ~/Library/Application Support on
/// macOS.
class JsonFileProfileStore implements ProfileStore {
  /// Bumped when the on-disk shape changes so an old file can be migrated
  /// rather than guessed at.
  static const int formatVersion = 1;

  static const String fileName = 'profiles.json';

  /// Resolves the directory holding the profiles file.  Injectable because
  /// path_provider talks over a platform channel, which a test does not have.
  final Future<Directory> Function() _directory;

  JsonFileProfileStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  /// The file profiles are read from and written to.
  Future<File> get file async {
    final directory = await _directory();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<List<ConnectionProfile>> load() async {
    final source = await file;
    if (!source.existsSync()) {
      return <ConnectionProfile>[];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(await source.readAsString());
    } on FormatException catch (e) {
      // Leave the file alone so it can be recovered by hand. Overwriting
      // somebody's servers because of one stray character would be rude.
      throw ProfileStoreException(
        'Could not read ${source.path}: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ProfileStoreException('${source.path} is not a profiles file');
    }
    final version = decoded['version'];
    if (version != formatVersion) {
      throw ProfileStoreException(
        '${source.path} is version $version, expected $formatVersion',
      );
    }
    final profiles = decoded['profiles'];
    if (profiles is! List) {
      throw ProfileStoreException('${source.path} has no profiles list');
    }
    try {
      return profiles
          .map(
            (profile) => ConnectionProfile.fromJson(
              profile as Map<String, Object?>,
            ),
          )
          .toList();
    } on FormatException catch (e) {
      throw ProfileStoreException(
        'Could not read ${source.path}: ${e.message}',
      );
    } on TypeError {
      throw ProfileStoreException('${source.path} has a malformed profile');
    }
  }

  @override
  Future<void> save(List<ConnectionProfile> profiles) async {
    final destination = await file;
    await destination.parent.create(recursive: true);
    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'version': formatVersion,
        'profiles': profiles.map((profile) => profile.toJson()).toList(),
      },
    );
    // Write beside the target and rename over it, so an interrupted save
    // cannot leave a half written file where the profiles used to be.
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(destination.path);
  }
}

/// A store that forgets everything when the process exits.  For tests, and for
/// the case where the profiles file cannot be read and the user chooses to
/// carry on without it.
class MemoryProfileStore implements ProfileStore {
  List<ConnectionProfile> _profiles;

  MemoryProfileStore([List<ConnectionProfile> profiles = const []])
    : _profiles = List<ConnectionProfile>.of(profiles);

  @override
  Future<List<ConnectionProfile>> load() async =>
      List<ConnectionProfile>.of(_profiles);

  @override
  Future<void> save(List<ConnectionProfile> profiles) async {
    _profiles = List<ConnectionProfile>.of(profiles);
  }
}
