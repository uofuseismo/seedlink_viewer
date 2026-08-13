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


    final boost = Platform.environment['BOOST_INCLUDEDIR'];

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
