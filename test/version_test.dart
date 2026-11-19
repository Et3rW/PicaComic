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

  // Versions count in decimal: each of the three numbers is one digit, and
  // 5.1.9 is followed by 5.2.0. The build number is the three digits after
  // the major version's thousands, so it grows with every version:
  // 5.1.9 is 5019, 5.2.0 is 5020.
  test('the version is decimal and the build number follows it', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'));
    final match =
        RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)$').firstMatch(line)!;
    final major = int.parse(match[1]!),
        minor = int.parse(match[2]!),
        patch = int.parse(match[3]!),
        build = int.parse(match[4]!);
    expect(minor, inInclusiveRange(0, 9), reason: 'after x.9.y comes (x+1).0.0');
    expect(patch, inInclusiveRange(0, 9), reason: 'after x.y.9 comes x.(y+1).0');
    expect(build, major * 1000 + minor * 10 + patch);
  });

  test('a build without a test number shows the plain version', () {
    expect(testBuildNumber, 0);
    expect(appVersionLabel, appVersion);
  });
}
