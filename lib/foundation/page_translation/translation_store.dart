import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'page_renderer.dart';

/// The text result of one translated page.
class StoredPage {
  StoredPage(this.width, this.height, this.blocks);

  /// Size of the page the block rectangles refer to.
  final int width;
  final int height;

  /// Empty when the page has no text worth translating.
  final List<TranslatedBlock> blocks;
}

/// Keeps what was recognized and translated on each page, so a page is paid
/// for once: the rendered image is only a cache and can be drawn again from
/// this. Nothing here expires; the user clears it in settings.
class TranslationStore {
  TranslationStore(String path) : _db = sqlite3.open(path) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS pages (
        key TEXT PRIMARY KEY NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        blocks TEXT NOT NULL,
        time INTEGER NOT NULL
      )
    ''');
  }

  final Database _db;

  StoredPage? get(String key) {
    var rows = _db.select(
        'SELECT width, height, blocks FROM pages WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    var row = rows.first;
    try {
      return StoredPage(row['width'] as int, row['height'] as int, [
        for (var block in jsonDecode(row['blocks'] as String) as List)
          TranslatedBlock.fromJson(block as Map),
      ]);
    } catch (_) {
      // Written by a version with another format: translate again.
      remove(key);
      return null;
    }
  }

  void put(String key, StoredPage page) {
    _db.execute(
      'INSERT OR REPLACE INTO pages (key, width, height, blocks, time) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        key,
        page.width,
        page.height,
        jsonEncode([for (var block in page.blocks) block.toJson()]),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  void remove(String key) =>
      _db.execute('DELETE FROM pages WHERE key = ?', [key]);

  int get count =>
      _db.select('SELECT COUNT(*) AS n FROM pages').first['n'] as int;

  void clear() => _db.execute('DELETE FROM pages');

  void close() => _db.dispose();
}
