import 'dart:convert';
import 'dart:io';

import 'translation_settings.dart';
import 'translation_store.dart';

/// Page translation's part of the user data backup: its settings and the
/// translated text of every page. The rendered pages are not part of it; they
/// are drawn again from the text when shown.
class TranslationBackup {
  /// Names of the files in the backup.
  static const settingsFile = 'page_translation.json';
  static const pagesFile = 'page_translation.db';

  /// Writes the backup's files into [directory] and returns their paths.
  /// Without [keys] the services' API keys are left out; without [pages],
  /// the translated pages.
  static List<String> write(
    Directory directory, {
    required TranslationSettings settings,
    required TranslationStore store,
    bool keys = true,
    bool pages = true,
  }) {
    directory.createSync(recursive: true);
    var written = <String>[];
    var settingsPath = '${directory.path}/$settingsFile';
    File(settingsPath).writeAsStringSync(jsonEncode(settings.toJson(keys: keys)));
    written.add(settingsPath);
    if (pages && store.count > 0) {
      var pagesPath = '${directory.path}/$pagesFile';
      var old = File(pagesPath);
      // VACUUM INTO refuses to write over a file.
      if (old.existsSync()) old.deleteSync();
      store.exportTo(pagesPath);
      written.add(pagesPath);
    }
    return written;
  }

  /// Takes on the backup files found in [directory], if any. Returns how
  /// many translated pages were added.
  static int read(
    Directory directory, {
    required TranslationSettings settings,
    required TranslationStore store,
  }) {
    var settingsJson = File('${directory.path}/$settingsFile');
    if (settingsJson.existsSync()) {
      try {
        settings.importJson(jsonDecode(settingsJson.readAsStringSync()));
      } on FormatException {
        // A damaged file: the settings stay as they are.
      }
    }
    var pages = File('${directory.path}/$pagesFile');
    if (!pages.existsSync()) return 0;
    return store.importFrom(pages.path);
  }
}
