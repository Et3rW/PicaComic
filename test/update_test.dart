import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/network/update.dart';

void main() {
  const releaseFiles = [
    UpdateFile('PicaComic-5.1.8-macos-universal.zip', 'https://x/mac', 1),
    UpdateFile('PicaComic-5.1.8-unsigned.ipa', 'https://x/ipa', 2),
    UpdateFile('PicaComic-5.1.8.apk', 'https://x/apk', 3),
    UpdateFile('SHA256SUMS-android.txt', 'https://x/sums-android', 4),
    UpdateFile('SHA256SUMS-ios.txt', 'https://x/sums-ios', 5),
  ];
  const testFiles = [
    UpdateFile('PicaComic-5.1.9.3-test.apk', 'https://x/test-apk', 6),
    UpdateFile('SHA256SUMS.txt', 'https://x/sums', 7),
  ];

  group('the package to install', () {
    test('a release build takes the release APK and its checksums', () {
      final update = androidUpdateIn(releaseFiles, '5.1.8')!;
      expect(update.apk.url, 'https://x/apk');
      expect(update.checksums!.name, 'SHA256SUMS-android.txt');
    });

    test('a test build takes the test APK', () {
      final update = androidUpdateIn(testFiles, '5.1.9.3', test: true)!;
      expect(update.apk.name, 'PicaComic-5.1.9.3-test.apk');
      expect(update.checksums!.name, 'SHA256SUMS.txt');
    });

    test('neither takes the other channel\'s APK', () {
      expect(androidUpdateIn(testFiles, '5.1.9.3'), isNull);
      expect(androidUpdateIn(releaseFiles, '5.1.8', test: true), isNull);
    });

    test('release files are read from the GitHub answer', () {
      final files = UpdateFile.listFrom([
        {'name': 'a.apk', 'browser_download_url': 'https://x/a', 'size': 9},
        {'name': 'broken'},
        'junk',
      ]);
      expect(files.map((f) => [f.name, f.url, f.size]), [
        ['a.apk', 'https://x/a', 9],
      ]);
      expect(UpdateFile.listFrom(null), isEmpty);
    });
  });

  test('the checksum of a file is read from a sha256sum listing', () {
    const listing = '''
0c767f91df23b8fc288f57155a9d8a34e86240b4133bdd245be276332f2f6bf9  PicaComic-5.1.9-test.apk
F972208CD5B8158FC1306EFDE8C8884A6E62A0E37035D49B99E1CC7B147FBE47 *PicaComic-5.1.9.3-test.apk
''';
    expect(checksumFor(listing, 'PicaComic-5.1.9.3-test.apk'),
        'f972208cd5b8158fc1306efde8c8884a6e62a0e37035d49b99e1cc7b147fbe47');
    expect(checksumFor(listing, 'PicaComic-5.1.9.apk'), isNull);
  });

  test('release notes are shown whole, as plain text', () {
    const notes = '''
5.1.9 的第 3 个测试版。

- **翻译改成整本**：点 `翻译` 按钮。
- 参考了 [ccbkv/PicaComic](https://github.com/ccbkv/PicaComic)。

---

## 已知限制
第六行
第七行''';
    expect(plainReleaseNotes(notes), '''
5.1.9 的第 3 个测试版。

• 翻译改成整本：点 翻译 按钮。
• 参考了 ccbkv/PicaComic。

已知限制
第六行
第七行''');
  });

  test('versions compare by their numbers', () {
    expect(compareVersions('5.2.0', '5.1.9'), greaterThan(0));
    expect(compareVersions('6.0.0', '5.9.9'), greaterThan(0));
    expect(compareVersions('5.1.9.10', '5.1.9.3'), greaterThan(0));
    expect(compareVersions('5.1.9.1', '5.1.9'), greaterThan(0));
    expect(compareVersions('5.1.9', '5.1.9.0'), 0);
    expect(compareVersions('5.1.8', '5.1.9.3'), lessThan(0));
  });

  test('a test build looks for the newest four-number pre-release', () {
    final releases = [
      {'tag_name': 'v5.1.9.3', 'prerelease': true},
      {'tag_name': 'v5.1.9-test.2', 'prerelease': true},
      {'tag_name': 'v5.2.0.1', 'prerelease': true},
      {'tag_name': 'v5.1.9.12', 'prerelease': true, 'draft': true},
      {'tag_name': 'v5.1.8', 'prerelease': false},
      {'tag_name': 'v5.1.9.4', 'prerelease': false},
    ];
    expect(newestTestRelease(releases)!['tag_name'], 'v5.2.0.1');
    expect(newestTestRelease([releases[1], releases[4]]), isNull);
    expect(newestTestRelease(null), isNull);
  });

  test('a release build without a test number is on the release channel', () {
    expect(isTestBuild, isFalse);
    expect(currentVersion, appVersion);
  });
}
