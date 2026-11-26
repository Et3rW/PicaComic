import 'package:flutter/material.dart';

typedef ActionFunc = void Function();

enum ComicType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htManga,
  htFavorite,
  nhentai,
  other;

  @override
  toString() => name;
}

const String webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";

//App版本
const appVersion = "5.3.0";

/// Order of a test build since the last release, given to the build with
/// `--dart-define=PICA_TEST_NUMBER=3`; 0 for releases.
const testBuildNumber = int.fromEnvironment('PICA_TEST_NUMBER');

/// A test build's version, given with `--dart-define=PICA_TEST_VERSION=5.2.3`
/// (see doc/releasing.md).
const _testVersion = String.fromEnvironment('PICA_TEST_VERSION');

/// The version shown in the app: 5.2.3 for the third test build after 5.2.0.
/// Release update checks compare [appVersion].
const appVersionLabel = testBuildNumber <= 0
    ? appVersion
    : _testVersion != ""
        ? _testVersion
        : "$appVersion.$testBuildNumber";

//定义宽屏设备的临界值
const changePoint = 600;
const changePoint2 = 1300;

List<MaterialAccentColor> get colors => [
  Colors.redAccent,
  Colors.pinkAccent,
  Colors.purpleAccent,
  Colors.indigoAccent,
  Colors.blueAccent,
  Colors.cyanAccent,
  Colors.tealAccent,
  Colors.greenAccent,
  Colors.limeAccent,
  Colors.yellowAccent,
  Colors.amberAccent,
  Colors.orangeAccent,
];

const builtInSources = [
  "picacg",
  "ehentai",
  "jm",
  "hitomi",
  "htmanga",
  "nhentai"
];
