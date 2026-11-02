import 'dart:io';

import 'package:test/test.dart';

import '../../tool/generate_build_version.dart';

void main() {
  test('build identity generation follows the package version', () {
    final temp = Directory.systemTemp.createTempSync('sdsc_build_version_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final manifest = File('${temp.path}/pubspec.yaml')
      ..writeAsStringSync('name: test\nversion: 5.2.1\n');
    final output = File('${temp.path}/build_version.dart');

    writeBuildVersion(manifest: manifest, output: output);

    expect(
      output.readAsStringSync(),
      contains("const String buildVersion = '5.2.1';"),
    );
  });
}
