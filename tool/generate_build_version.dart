import 'dart:io';

import 'package:yaml/yaml.dart';

void main() {
  writeBuildVersion(
    manifest: File('pubspec.yaml'),
    output: File('lib/core/build_version.dart'),
  );
}

void writeBuildVersion({required File manifest, required File output}) {
  final document = loadYaml(manifest.readAsStringSync());
  if (document is! YamlMap || document['version'] is! String) {
    throw StateError('pubspec.yaml must define a string version.');
  }
  final version = document['version'] as String;
  if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(version)) {
    throw StateError('Invalid package version: $version');
  }
  output.writeAsStringSync(
    '// Generated from pubspec.yaml by tool/generate_build_version.dart.\n'
    "const String buildVersion = '$version';\n",
  );
}
