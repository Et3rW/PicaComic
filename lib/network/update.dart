import 'dart:convert';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/app_dio.dart';

String? _updateInfo;
List<UpdateFile> _updateFiles = const [];
String? _latestVersion;

/// A file attached to a release.
class UpdateFile {
  const UpdateFile(this.name, this.url, this.size);

  final String name;
  final String url;
  final int size;

  static List<UpdateFile> listFrom(Object? assets) => [
        if (assets is List)
          for (var asset in assets)
            if (asset is Map &&
                asset['name'] is String &&
                asset['browser_download_url'] is String)
              UpdateFile(asset['name'], asset['browser_download_url'],
                  asset['size'] is int ? asset['size'] : 0),
      ];
}

/// The Android package of a release and the file holding its checksum.
class AndroidUpdate {
  const AndroidUpdate(this.apk, this.checksums);

  final UpdateFile apk;
  final UpdateFile? checksums;
}

/// Finds the Android package among [files] of release [version]. A release
/// build takes the release APK (`PicaComic-5.1.8.apk`), a test build the
/// test APK (`PicaComic-5.1.9.3-test.apk`); neither takes the other's.
AndroidUpdate? androidUpdateIn(List<UpdateFile> files, String version,
    {bool test = false}) {
  bool isTestApk(UpdateFile f) => f.name.endsWith('-test.apk');
  var apk = test
      ? files.where((f) => f.name == 'PicaComic-$version-test.apk').firstOrNull ??
          files.where(isTestApk).firstOrNull
      : files.where((f) => f.name == 'PicaComic-$version.apk').firstOrNull ??
          files
              .where((f) => f.name.endsWith('.apk') && !isTestApk(f))
              .firstOrNull;
  if (apk == null) return null;
  var checksums = files
          .where((f) => f.name == 'SHA256SUMS-android.txt')
          .firstOrNull ??
      files.where((f) => f.name == 'SHA256SUMS.txt').firstOrNull;
  return AndroidUpdate(apk, checksums);
}

/// The Android package of the release found by the last update check.
AndroidUpdate? get latestAndroidUpdate => _latestVersion == null
    ? null
    : androidUpdateIn(_updateFiles, _latestVersion!, test: isTestBuild);

/// Test builds look for newer test builds, releases for newer releases.
bool get isTestBuild => testBuildNumber > 0;

/// The version this build compares with: 5.1.9.3 for a test build.
String get currentVersion => isTestBuild ? appVersionLabel : appVersion;

/// Compares dotted version numbers as numbers: 5.1.10 is above 5.1.9 and
/// 5.1.9.1 above 5.1.9. Returns a positive number when [a] is newer.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [
        for (var part in v.split('.')) int.tryParse(part) ?? 0,
      ];
  var x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    var d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Test builds are pre-releases tagged with four numbers (v5.1.9.3). The
/// newest of [releases], a list from the GitHub API, or null.
Map? newestTestRelease(Object? releases) {
  Map? newest;
  String? newestVersion;
  if (releases is! List) return null;
  for (var release in releases) {
    if (release is! Map || release['prerelease'] != true) continue;
    if (release['draft'] == true) continue;
    var tag = release['tag_name'];
    if (tag is! String) continue;
    var match = RegExp(r'^v(\d+\.\d+\.\d+\.\d+)$').firstMatch(tag);
    if (match == null) continue;
    var version = match[1]!;
    if (newestVersion == null || compareVersions(version, newestVersion) > 0) {
      newest = release;
      newestVersion = version;
    }
  }
  return newest;
}

/// The SHA-256 that a `sha256sum` listing gives for [fileName].
String? checksumFor(String listing, String fileName) {
  for (var line in const LineSplitter().convert(listing)) {
    var match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (match != null && match[2]!.trim() == fileName) {
      return match[1]!.toLowerCase();
    }
  }
  return null;
}

/// Release notes are written in Markdown; the update dialog shows them as
/// plain text.
String plainReleaseNotes(String markdown) {
  var lines = <String>[];
  for (var line in const LineSplitter().convert(markdown)) {
    line = line
        // [text](url) and images
        .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAllMapped(RegExp(r'^(\s*)[-*] '), (m) => '${m[1]}• ')
        .replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    if (line.trim() == '---') line = '';
    lines.add(line.trimRight());
  }
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// The newest version on this build's channel: the latest release, or for
/// a test build the newest test build.
Future<String> getLatestVersion() async {
  var dio = logDio();
  Map release;
  if (isTestBuild) {
    var res = await dio.get(
        "https://api.github.com/repos/Et3rW/PicaComic/releases?per_page=30");
    release = newestTestRelease(res.data) ?? (throw "No test build found");
  } else {
    var res = await dio
        .get("https://api.github.com/repos/Et3rW/PicaComic/releases/latest");
    release = res.data as Map;
  }
  _updateInfo = release["body"];
  _updateFiles = UpdateFile.listFrom(release["assets"]);
  _latestVersion = (release["tag_name"] as String).replaceFirst("v", "");
  return _latestVersion!;
}

Future<bool?> checkUpdate() async {
  try {
    var res = await getLatestVersion();
    if (isTestBuild) return compareVersions(res, currentVersion) > 0;
    return compareSemVer(res, appVersion);
  } catch (e) {
    return null;
  }
}

bool compareSemVer(String ver1, String ver2) {
  ver1 = ver1.replaceFirst("-", ".");
  ver2 = ver2.replaceFirst("-", ".");
  List<String> v1 = ver1.split('.');
  List<String> v2 = ver2.split('.');

  for (int i = 0; i < 3; i++) {
    int num1 = int.parse(v1[i]);
    int num2 = int.parse(v2[i]);

    if (num1 > num2) {
      return true;
    } else if (num1 < num2) {
      return false;
    }
  }

  var v14 = v1.elementAtOrNull(3);
  var v24 = v2.elementAtOrNull(3);

  if (v14 != v24) {
    if (v14 == null && v24 != "hotfix") {
      return true;
    } else if (v14 == null) {
      return false;
    }
    if (v24 == null) {
      if (v14 == "hotfix") {
        return true;
      }
      return false;
    }
    return v14.compareTo(v24) > 0;
  }

  return false;
}

/// The notes of the release found by the last update check, in full.
Future<String?> getUpdatesInfo() async {
  if (_updateInfo == null) return null;
  return plainReleaseNotes(_updateInfo!);
}

Future<String> getDownloadUrl() async {
  if (isTestBuild && _latestVersion != null) {
    return "https://github.com/Et3rW/PicaComic/releases/tag/v$_latestVersion";
  }
  return "https://github.com/Et3rW/PicaComic/releases/latest";
}
