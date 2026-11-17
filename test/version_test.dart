import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/def.dart';

void main() {
  // pubspec.yaml is the source of truth for the version: the build workflows
  // and the Android test package name are derived from it. The constant shown
  // in the app and used by the update check has to be changed along with it.
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'));
    final match =
        RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+\d+$').firstMatch(line);
    expect(match, isNotNull, reason: 'unexpected version line: $line');
    final name = '${match![1]}.${match[2]}.${match[3]}';
    expect(appVersion, name);
  });

  test('a build without a test number shows the plain version', () {
    expect(testBuildNumber, 0);
    expect(appVersionLabel, appVersion);
  });
}
