import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';

void main() {
  late Directory root;
  late String cacheDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pica_cache_test');
    cacheDir = '${root.path}/cache';
  });

  tearDown(() {
    CacheManager.instance = null;
    root.deleteSync(recursive: true);
  });

  File writeUntracked(String rel, int bytes, {Duration age = Duration.zero}) {
    final file = File('$cacheDir/$rel')..createSync(recursive: true);
    file.writeAsBytesSync(Uint8List(bytes));
    if (age > Duration.zero) {
      file.setLastModifiedSync(DateTime.now().subtract(age));
    }
    return file;
  }

  CacheManager create() =>
      CacheManager.createForTest(cacheDir, '${root.path}/cache.db');

  int filesOnDisk() =>
      Directory(cacheDir).listSync(recursive: true).whereType<File>().length;

  test('scan removes old untracked files and keeps fresh ones', () {
    writeUntracked('1/old', 100, age: const Duration(hours: 1));
    writeUntracked('2/fresh', 50);
    writeUntracked('3/tracked', 30, age: const Duration(hours: 1));
    final result = scanCacheDirectory(
      cacheDir,
      {'3/tracked', '4/missing'},
      DateTime.now()
          .subtract(CacheManager.orphanGracePeriod)
          .millisecondsSinceEpoch,
    );
    expect(result.removedFiles, 1);
    expect(result.removedBytes, 100);
    expect(result.size, 80);
    expect(result.missingEntries, ['4/missing']);
    expect(File('$cacheDir/1/old').existsSync(), isFalse);
    expect(File('$cacheDir/2/fresh').existsSync(), isTrue);
  });

  test('startup cleans files left by cancelled or killed downloads',
      () async {
    writeUntracked('5/leftover', 4096, age: const Duration(days: 2));
    final manager = create();
    await manager.checkCache();
    expect(File('$cacheDir/5/leftover').existsSync(), isFalse);
    expect(manager.currentSize, 0);
  });

  test('untracked files over the limit no longer hang checkCache', () async {
    final manager = create();
    await manager.checkCache();
    manager.setLimitSize(1); // 1 MB
    for (var i = 0; i < 3; i++) {
      await manager.writeCache('k$i', Uint8List(100 * 1024));
    }
    // Fresh untracked files (e.g. images being written) above the limit:
    // they cannot be removed yet, which used to make the loop spin forever.
    writeUntracked('9/inflight', 2 * 1024 * 1024);
    // Make the manager see them, as a later directory scan would.
    CacheManager.instance = null;
    final reopened = create()..setLimitSize(1);
    await reopened
        .checkCache()
        .timeout(const Duration(seconds: 5), onTimeout: () {
      fail('checkCache did not finish');
    });
    // All tracked entries were evicted; the fresh file is kept.
    expect(await reopened.findCache('k0'), isNull);
    expect(File('$cacheDir/9/inflight').existsSync(), isTrue);
  });

  test('evicts oldest entries down to the size limit', () async {
    final manager = create();
    await manager.checkCache();
    manager.setLimitSize(1);
    for (var i = 0; i < 12; i++) {
      await manager.writeCache('k$i', Uint8List(100 * 1024), 1000 + i);
    }
    expect(manager.currentSize, lessThanOrEqualTo(1024 * 1024));
    expect(await manager.findCache('k0'), isNull);
    expect(await manager.findCache('k11'), isNotNull);
    expect(filesOnDisk(), lessThanOrEqualTo(10));
  });

  test('re-caching a key deletes the previous file', () async {
    final manager = create();
    await manager.checkCache();
    await manager.writeCache('same', Uint8List(1000));
    await manager.writeCache('same', Uint8List(2000));
    expect(filesOnDisk(), 1);
    expect(manager.currentSize, 2000);
    expect(File((await manager.findCache('same'))!).lengthSync(), 2000);
  });

  test('caching file tracks its size and cancel removes partial data',
      () async {
    final manager = create();
    await manager.checkCache();
    final done = await manager.openWrite('img');
    await done.writeBytes(Uint8List(700 * 1024));
    await done.writeBytes(Uint8List(700 * 1024));
    await done.close();
    expect(manager.currentSize, 1400 * 1024);
    expect(File((await manager.findCache('img'))!).lengthSync(), 1400 * 1024);
    // Cancelling after close keeps the cached file.
    await done.cancel();
    expect(await manager.findCache('img'), isNotNull);

    final partial = await manager.openWrite('img2');
    await partial.writeBytes(Uint8List(2 * 1024 * 1024));
    expect(partial.file.existsSync(), isTrue);
    await partial.cancel();
    expect(partial.file.existsSync(), isFalse);
    expect(await manager.findCache('img2'), isNull);
    expect(filesOnDisk(), 1);
  });

  test('entries whose file vanished are dropped by the scan', () async {
    var manager = create();
    await manager.checkCache();
    await manager.writeCache('gone', Uint8List(10));
    File((await manager.findCache('gone'))!).deleteSync();
    CacheManager.instance = null;
    manager = create();
    await manager.checkCache();
    expect(manager.getType('gone'), isNull);
    expect(await manager.findCache('gone'), isNull);
  });
}
