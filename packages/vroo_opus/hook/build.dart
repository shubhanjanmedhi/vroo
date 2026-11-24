// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compiles libopus from the vendored source, plus the shim in src/, into one library for the target platform.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _opus = 'third_party/opus';

/// The files that [variable] lists in libopus's own [mk] file, so the build follows libopus's source lists.
List<String> _sources(Uri packageRoot, String mk, String variable) {
  final text = File.fromUri(packageRoot.resolve('$_opus/$mk')).readAsStringSync().replaceAll('\\\n', ' ');
  final line = text.split('\n').firstWhere((l) => l.startsWith('$variable ='));
  return [for (final f in line.substring(line.indexOf('=') + 1).trim().split(RegExp(r'\s+'))) '$_opus/$f'];
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final root = input.packageRoot;
    final os = input.config.code.targetOS;
    await CBuilder.library(
      name: 'vroo_opus',
      assetName: 'src/bindings.dart',
      sources: [
        'src/vroo_opus.c',
        ..._sources(root, 'celt_sources.mk', 'CELT_SOURCES'),
        ..._sources(root, 'silk_sources.mk', 'SILK_SOURCES'),
        ..._sources(root, 'silk_sources.mk', 'SILK_SOURCES_FLOAT'),
        ..._sources(root, 'opus_sources.mk', 'OPUS_SOURCES'),
        ..._sources(root, 'opus_sources.mk', 'OPUS_SOURCES_FLOAT'),
      ],
      includes: ['$_opus/include', '$_opus/celt', '$_opus/silk', '$_opus/silk/float'],
      defines: const {'OPUS_BUILD': null, 'USE_ALLOCA': null, 'HAVE_LRINTF': null, 'HAVE_LRINT': null},
      // libopus calls exp, log, cos…: on Android and Linux they're in libm, which isn't linked unless asked for
      // (Apple's libSystem has them built in). Without it Android can't load the library at all.
      libraries: [if (os == OS.android || os == OS.linux) 'm'],
      optimizationLevel: OptimizationLevel.o2,
    ).run(input: input, output: output);
  });
}
