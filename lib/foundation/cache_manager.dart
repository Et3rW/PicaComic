import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:sqlite3/sqlite3.dart';

/// Result of [scanCacheDirectory].
class CacheScanResult {
  const CacheScanResult(
      this.size, this.removedFiles, this.removedBytes, this.missingEntries);

  /// Bytes of the files left in the cache directory.
  final int size;

  /// Untracked files that were deleted.
  final int removedFiles;

  final int removedBytes;

  /// Tracked `dir/name` entries whose file no longer exists.
  final List<String> missingEntries;
}

/// Walks [cachePath] once: deletes files that no cache row refers to and that
/// were last modified before [orphanCutoffMs], and sums the size of the rest.
///
/// Untracked files appear when a download is cancelled or the app is killed
/// while an image is being written (the row is only added once the file is
/// complete). They used to pile up forever and made [CacheManager.checkCache]
/// spin. The cutoff keeps files that are being written right now.
///
/// Runs in a background isolate, so it only takes sendable arguments.
CacheScanResult scanCacheDirectory(
    String cachePath, Set<String> known, int orphanCutoffMs) {
  var dir = Directory(cachePath);
  var size = 0, removedFiles = 0, removedBytes = 0;
  var seen = <String>{};
  if (dir.existsSync()) {
    for (var entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      var rel = entity.path.substring(cachePath.length + 1).replaceAll('\\', '/');
      int length;
      DateTime modified;
      try {
        var stat = entity.statSync();
        length = stat.size;
        modified = stat.modified;
      } catch (_) {
        continue;
      }
      if (known.contains(rel)) {
        seen.add(rel);
        size += length;
      } else if (modified.millisecondsSinceEpoch < orphanCutoffMs) {
        try {
          entity.deleteSync();
          removedFiles++;
          removedBytes += length;
        } catch (_) {
          size += length;
        }
      } else {
        // Probably being written right now.
        size += length;
      }
    }
  }
  return CacheScanResult(size, removedFiles, removedBytes,
      known.difference(seen).toList(growable: false));
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

CacheScanResult _scanInIsolate((String, Set<String>, int) args) =>
    scanCacheDirectory(args.$1, args.$2, args.$3);

class CacheManager {
  static String get cachePath =>
      instance?._cacheDir ?? '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  final String _cacheDir;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  int get limitSize => _limitSize;

  /// Most entries kept, regardless of their size.
  static const maxEntries = 2000;

  /// Files without a cache row younger than this are kept by the scan.
  static const orphanGracePeriod = Duration(minutes: 10);

  /// A full scan of the cache directory runs at most this often.
  static const rescanInterval = Duration(minutes: 5);

  /// The entry count is checked after this many writes.
  static const countCheckInterval = 100;

  CacheManager._create(this._cacheDir, String dbPath) {
    Directory(_cacheDir).createSync(recursive: true);
    _db = sqlite3.open(dbPath);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    // 旧版本的表中没有type字段，需要添加
    try {
      _db.execute('''
        ALTER TABLE cache ADD COLUMN type TEXT
      ''');
    } catch (e) {
      // ignore
    }
    _scanTask = _scan();
  }

  factory CacheManager() => instance ??=
      CacheManager._create('${App.cachePath}/cache', '${App.dataPath}/cache.db');

  /// Replaces [instance] with a manager on the given paths. The directory
  /// scan then runs on the calling isolate.
  @visibleForTesting
  static CacheManager createForTest(String cacheDir, String dbPath) {
    instance?._db.dispose();
    _scanInline = true;
    return instance = CacheManager._create(cacheDir, dbPath);
  }

  /// Tests run the scan on the current isolate.
  static bool _scanInline = false;

  Future<void>? _scanTask;

  DateTime? _lastScan;

  int _writesSinceCountCheck = 0;

  /// Removes untracked files and recomputes [currentSize] from disk.
  Future<void> _scan() async {
    _lastScan = DateTime.now();
    var known = <String>{
      for (var row in _db.select('SELECT dir, name FROM cache'))
        '${row[0]}/${row[1]}'
    };
    var cutoff =
        DateTime.now().subtract(orphanGracePeriod).millisecondsSinceEpoch;
    CacheScanResult result;
    try {
      result = _scanInline
          ? scanCacheDirectory(_cacheDir, known, cutoff)
          : await compute(_scanInIsolate, (_cacheDir, known, cutoff));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Cache", "Scan failed: $e\n$s");
      // Let the next check try again.
      _scanTask = null;
      return;
    }
    _currentSize = result.size;
    for (var entry in result.missingEntries) {
      var slash = entry.indexOf('/');
      _db.execute('DELETE FROM cache WHERE dir = ? AND name = ?',
          [entry.substring(0, slash), entry.substring(slash + 1)]);
    }
    if (result.removedFiles > 0 || result.missingEntries.isNotEmpty) {
      LogManager.addLog(
          LogLevel.info,
          "Cache",
          "Removed ${result.removedFiles} untracked files "
              "(${_mb(result.removedBytes)}), "
              "${result.missingEntries.length} entries without file; "
              "size ${_mb(result.size)}");
    }
  }

  /// set cache size limit in MB
  void setLimitSize(int size){
    _limitSize = size * 1024 * 1024;
  }

  void setType(String key, String? type){
    _db.execute('''
      UPDATE cache
      SET type = ?
      WHERE key = ?
    ''', [type, key]);
  }

  String? getType(String key){
    var res = _db.select('''
      SELECT type FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return null;
    }
    return res.first[0];
  }

  Future<(String, String, File)> _newFile(String key) async {
    this.dir++;
    this.dir %= 100;
    var dir = this.dir.toString();
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$_cacheDir/$dir/$name');
    while(await file.exists()){
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$_cacheDir/$dir/$name');
    }
    await file.create(recursive: true);
    return (dir, name, file);
  }

  /// Records a complete file for [key]. A file already cached for the same
  /// key is deleted instead of being left behind untracked.
  Future<void> _commit(String key, String dir, String name, int expires,
      int bytes) async {
    var old = _db.select(
        'SELECT dir, name FROM cache WHERE key = ?', [key]);
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''', [key, dir, name, expires]);
    if (_currentSize != null) {
      _currentSize = _currentSize! + bytes;
    }
    for (var row in old) {
      if (row[0] == dir && row[1] == name) continue;
      await _deleteFile(row[0] as String, row[1] as String);
    }
    await _afterWrite();
  }

  Future<void> _deleteFile(String dir, String name) async {
    var file = File('$_cacheDir/$dir/$name');
    try {
      if (await file.exists()) {
        var size = await file.length();
        await file.delete();
        if (_currentSize != null) {
          _currentSize = _currentSize! - size;
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /// Cleans up only when needed, instead of after every image.
  Future<void> _afterWrite() async {
    _writesSinceCountCheck++;
    var overSize = _currentSize != null && _currentSize! > _limitSize;
    if (overSize || _writesSinceCountCheck >= countCheckInterval) {
      _writesSinceCountCheck = 0;
      await checkCache();
    }
  }

  Future<void> writeCache(String key, Uint8List data, [int duration = 7 * 24 * 60 * 60 * 1000]) async{
    var (dir, name, file) = await _newFile(key);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    await _commit(key, dir, name, expires, data.length);
  }

  Future<CachingFile> openWrite(String key) async{
    var (dir, name, file) = await _newFile(key);
    return CachingFile._(key, dir, name, file);
  }

  Future<String?> findCache(String key) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$_cacheDir/$dir/$name');
    if(await file.exists()){
      return file.path;
    }
    return null;
  }

  bool _isChecking = false;

  Future<void> checkCache() async{
    if(_isChecking){
      return;
    }
    _isChecking = true;
    try {
      // The size must be known before comparing it with the limit.
      await (_scanTask ??= _scan());
      if (_currentSize == null) return;

      var now = DateTime.now().millisecondsSinceEpoch;
      var expired = _db.select('''
        SELECT dir, name FROM cache
        WHERE expires < ?
      ''', [now]);
      _db.execute('''
        DELETE FROM cache
        WHERE expires < ?
      ''', [now]);
      for (var row in expired) {
        await _deleteFile(row[0] as String, row[1] as String);
      }

      var count = _db.select('SELECT COUNT(*) FROM cache').first[0] as int;

      while (_currentSize! > _limitSize || count > maxEntries) {
        var rows = _db.select('''
          SELECT key, dir, name FROM cache
          ORDER BY expires ASC
          limit 10
        ''');
        if (rows.isEmpty) {
          // Everything tracked is gone, so the rest of the size is files
          // without a row. Never loop here: rescan to remove old ones.
          var last = _lastScan;
          if (last == null ||
              DateTime.now().difference(last) > rescanInterval) {
            _scanTask = _scan();
          }
          break;
        }
        for (var row in rows) {
          _db.execute('DELETE FROM cache WHERE key = ?', [row[0]]);
          await _deleteFile(row[1] as String, row[2] as String);
          count--;
          if (_currentSize! <= _limitSize && count <= maxEntries) {
            break;
          }
        }
      }
    } finally {
      _isChecking = false;
    }
  }

  Future<void> delete(String key) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if(res.isEmpty){
      return;
    }
    var row = res.first;
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
    await _deleteFile(row[1] as String, row[2] as String);
  }

  Future<void> clear() async {
    await Directory(_cacheDir).delete(recursive: true);
    Directory(_cacheDir).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }

  Future<void> deleteKeyword(String keyword) async{
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key LIKE ?
    ''', ['%$keyword%']);
    for(var row in res){
      var key = row[0] as String;
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [key]);
      await _deleteFile(row[1] as String, row[2] as String);
    }
  }
}

class CachingFile{
  CachingFile._(this.key, this.dir, this.name, this.file);

  final String key;

  final String dir;

  final String name;

  final File file;

  /// Bytes, not a List<int> of 8-byte integers.
  final _buffer = BytesBuilder(copy: false);

  int _written = 0;

  bool _done = false;

  Future<void> writeBytes(List<int> data) async{
    _buffer.add(data);
    if(_buffer.length > 1024 * 1024){
      _written += _buffer.length;
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
  }

  Future<void> close() async{
    if (_done) return;
    if(_buffer.isNotEmpty){
      _written += _buffer.length;
      await file.writeAsBytes(_buffer.takeBytes(), mode: FileMode.append);
    }
    _done = true;
    await CacheManager()._commit(key, dir, name,
        DateTime.now().millisecondsSinceEpoch + 7 * 24 * 60 * 60 * 1000,
        _written);
  }

  /// Deletes the partial file. Does nothing once [close] has completed.
  Future<void> cancel() async{
    if (_done) return;
    _done = true;
    _buffer.clear();
    await file.deleteIgnoreError();
  }

  void reset() {
    _buffer.clear();
    _written = 0;
    if(file.existsSync()) {
      file.deleteSync();
    }
  }
}
