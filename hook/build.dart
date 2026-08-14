import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageRoot = input.packageRoot;
    final slinkDir = packageRoot.resolve('third_party/libslink/');
    final mseedDir = packageRoot.resolve('third_party/libmseed/');
    final os = input.config.code.targetOS;

    // Bundle the pre-built libslink shared library so it lands alongside
    // libslclient.so/dylib in bundle/lib/ and the dynamic linker can find it.
    //
    // Linux: SONAME is "libslink.so.4" so the file must be present under that
    //        exact name — copy the versioned file, register under that name.
    // macOS: install name is typically "@rpath/libslink.dylib"; bundle the
    //        unversioned dylib. Adjust if CI produces a versioned name.
    if (os == OS.linux) {
      final slinkSrc = slinkDir.resolve('libslink.so.4.2.0');
      final slinkDst = input.outputDirectory.resolve('libslink.so.4');
      await File(slinkSrc.toFilePath()).copy(slinkDst.toFilePath());
      output.assets.code.add(CodeAsset(
        package: input.packageName,
        name: 'libslink',
        file: slinkDst,
        linkMode: DynamicLoadingBundled(),
      ));
      output.dependencies.add(slinkSrc);
    } else if (os == OS.macOS) {
      final slinkSrc = slinkDir.resolve('libslink.dylib');
      final slinkDst = input.outputDirectory.resolve('libslink.dylib');
      await File(slinkSrc.toFilePath()).copy(slinkDst.toFilePath());
      output.assets.code.add(CodeAsset(
        package: input.packageName,
        name: 'libslink',
        file: slinkDst,
        linkMode: DynamicLoadingBundled(),
      ));
      output.dependencies.add(slinkSrc);
    }

    if (os == OS.linux) {
      final mseedSrc = mseedDir.resolve('libmseed.so.3.4.1');
      final mseedDst = input.outputDirectory.resolve('libmseed.so.3');
      await File(mseedSrc.toFilePath()).copy(mseedDst.toFilePath());
      output.assets.code.add(CodeAsset(
        package: input.packageName,
        name: 'libmseed',
        file: mseedDst,
        linkMode: DynamicLoadingBundled(),
      ));
      output.dependencies.add(mseedSrc);
    } else if (os == OS.macOS) {
      final mseedSrc = mseedDir.resolve('libmseed.dylib');
      final mseedDst = input.outputDirectory.resolve('libmseed.dylib');
      await File(mseedSrc.toFilePath()).copy(mseedDst.toFilePath());
      output.assets.code.add(CodeAsset(
        package: input.packageName,
        name: 'libmseed',
        file: mseedDst,
        linkMode: DynamicLoadingBundled(),
      ));
      output.dependencies.add(mseedSrc);
    }


    // Boost is header only here (slclient.cpp pulls in boost/json/src.hpp) so
    // only its include directory matters.
    //
    // Note an environment variable cannot be used to pass this in: build hooks
    // run with a sanitised environment holding only HOME, PATH and GOPATH, so
    // anything CI exports is dropped before it reaches us. The hook therefore
    // finds Boost itself, with a user-define in pubspec.yaml as an override.
    final boost =
        userDefinedBoostInclude(input) ?? findBoostIncludeDirectory();

    // Build slclient.cpp as a shared library linked dynamically against
    // libslink. The $ORIGIN / @loader_path rpath is added automatically by
    // native_toolchain_c so libslclient can find libslink at runtime.
    final builders = [
      CBuilder.library(
        name: 'slclient',
        assetName: 'native/slclient_bindings_generated.dart',
        sources: ['plugins/slclient.cpp'],
        includes: ['third_party/libslink',
                   'third_party/libmseed',
                   if (boost != null) boost,
                  ],
        std: 'c++20',
        language: Language.cpp,
        libraries: ['slink', 'mseed'],
        libraryDirectories: [slinkDir.toFilePath(), mseedDir.toFilePath()],
      ),
    ];

    for (final builder in builders) {
      await builder.run(
        input: input,
        output: output,
        logger: Logger('')
          ..level = Level.ALL
          ..onRecord.listen((record) => print(record.message)),
      );
    }
  });
}

/// An explicit Boost include directory from pubspec.yaml, if one is given:
///
///     hooks:
///       user_defines:
///         waveform_viewer:
///           boost_include: /opt/homebrew/opt/boost/include
///
/// This is the supported way to hand configuration to a build hook. Use it
/// when Boost lives somewhere findBoostIncludeDirectory does not look.
String? userDefinedBoostInclude(BuildInput input) {
  final value = input.userDefines['boost_include'];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw const FormatException(
      'hooks.user_defines.waveform_viewer.boost_include must be a string',
    );
  }
  return value;
}

/// Locates the Boost headers.
///
/// Returns null when Boost is already on the compiler's default search path,
/// which is the usual case on Linux where apt installs into /usr/include.
/// Homebrew on macOS keeps its headers outside the default path, so those have
/// to be pointed at explicitly - Apple Silicon and Intel use different
/// prefixes, so ask brew rather than guessing. PATH is one of the few
/// variables a build hook inherits, so brew is reachable here.
String? findBoostIncludeDirectory() {
  if (!Platform.isMacOS) {
    return null;
  }
  final candidates = <String>[];
  try {
    final brew = Process.runSync('brew', ['--prefix', 'boost']);
    if (brew.exitCode == 0) {
      final prefix = (brew.stdout as String).trim();
      if (prefix.isNotEmpty) {
        candidates.add('$prefix/include');
      }
    }
  } on ProcessException {
    // No brew on this machine, so fall through to the usual locations.
  }
  candidates
    ..add('/opt/homebrew/include') // Apple Silicon
    ..add('/usr/local/include'); // Intel
  for (final candidate in candidates) {
    if (Directory('$candidate/boost').existsSync()) {
      return candidate;
    }
  }
  return null;
}
