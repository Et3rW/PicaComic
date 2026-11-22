import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/translation_backup.dart';
import 'package:pica_comic/foundation/page_translation/translation_settings.dart';
import 'package:pica_comic/foundation/page_translation/translation_store.dart';
import 'package:pica_comic/foundation/page_translation/translator.dart';

// Exporting the user data takes page translation's settings and translated
// pages along; importing it brings them into another install.
void main() {
  late Directory root;
  late TranslationSettings settings;
  late TranslationStore store;

  const claude = TranslatorProvider(
    id: 'p1',
    name: 'Claude',
    kind: TranslatorKind.anthropic,
    url: 'https://api.anthropic.com',
    key: 'secret-1',
    model: 'm',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('pica_backup_test');
    settings = TranslationSettings(File('${root.path}/a/settings.json'))
      ..saveProvider(claude)
      ..setTarget('en')
      ..setPrompt('Be brief.');
    store = TranslationStore('${root.path}/a.db')
      ..put('page-1', StoredPage(100, 200, const []))
      ..put('page-2', StoredPage(300, 400, const []));
  });

  tearDown(() {
    store.close();
    root.deleteSync(recursive: true);
  });

  TranslationSettings otherSettings() =>
      TranslationSettings(File('${root.path}/b/settings.json'));

  test('a backup restores the settings, keys and pages elsewhere', () {
    var dir = Directory('${root.path}/backup');
    var files = TranslationBackup.write(dir, settings: settings, store: store);
    expect(files.map((f) => f.split('/').last),
        [TranslationBackup.settingsFile, TranslationBackup.pagesFile]);

    var settings2 = otherSettings();
    var store2 = TranslationStore('${root.path}/b.db');
    addTearDown(store2.close);
    expect(TranslationBackup.read(dir, settings: settings2, store: store2), 2);
    expect(settings2.target.code, 'en');
    expect(settings2.customPrompt, 'Be brief.');
    expect(settings2.activeProvider?.key, 'secret-1');
    expect(store2.count, 2);
    expect(store2.get('page-2')?.width, 300);

    // What was imported is kept.
    var reloaded = TranslationSettings(File('${root.path}/b/settings.json'));
    expect(reloaded.activeProvider?.key, 'secret-1');
  });

  test('without keys and pages, as for a sync server', () {
    var dir = Directory('${root.path}/backup');
    var files = TranslationBackup.write(dir,
        settings: settings, store: store, keys: false, pages: false);
    expect(files, hasLength(1));
    var json = File(files.single).readAsStringSync();
    expect(json, isNot(contains('secret-1')));
    expect(jsonDecode(json)['providers'][0]['url'], claude.url);
  });

  test('a service saved without its key keeps the key it has here', () {
    var dir = Directory('${root.path}/backup');
    TranslationBackup.write(dir,
        settings: settings, store: store, keys: false, pages: false);

    var here = otherSettings()
      ..saveProvider(claude.copyWith(key: 'secret-here', model: 'old'))
      ..saveProvider(const TranslatorProvider(
          id: 'p2',
          name: 'Only here',
          kind: TranslatorKind.google,
          url: '',
          key: '',
          model: ''));
    var store2 = TranslationStore('${root.path}/b.db');
    addTearDown(store2.close);
    TranslationBackup.read(dir, settings: here, store: store2);
    var p1 = here.providers.firstWhere((p) => p.id == 'p1');
    expect(p1.key, 'secret-here');
    expect(p1.model, 'm');
    expect(here.providers.map((p) => p.id), ['p1', 'p2']);
    expect(store2.count, 0);
  });

  test('a page translated on both sides keeps the newer translation', () async {
    var store2 = TranslationStore('${root.path}/b.db')
      ..put('page-1', StoredPage(1, 1, const []))
      ..put('page-3', StoredPage(7, 7, const []));
    addTearDown(store2.close);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store.put('page-2', StoredPage(999, 999, const []));
    // page-3 in the backup is newer than here.
    store.put('page-3', StoredPage(8, 8, const []));
    // page-1 in the backup is older than here, page-2 is newer.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store2.put('page-2', StoredPage(2, 2, const []));
    store.put('page-1', StoredPage(5, 5, const []));
    // Make page-1 here newer than the backup's.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    store2.put('page-1', StoredPage(1, 1, const []));

    var dir = Directory('${root.path}/backup');
    TranslationBackup.write(dir, settings: settings, store: store);
    expect(TranslationBackup.read(dir, settings: otherSettings(), store: store2),
        1);
    expect(store2.get('page-1')?.width, 1);
    expect(store2.get('page-2')?.width, 2);
    expect(store2.get('page-3')?.width, 8);
  });

  test('an older backup file there is replaced', () {
    var dir = Directory('${root.path}/backup');
    TranslationBackup.write(dir, settings: settings, store: store);
    store.put('page-3', StoredPage(5, 5, const []));
    TranslationBackup.write(dir, settings: settings, store: store);
    var store2 = TranslationStore('${root.path}/b.db');
    addTearDown(store2.close);
    expect(TranslationBackup.read(dir, settings: otherSettings(), store: store2),
        3);
  });

  test('a backup without page translation changes nothing', () {
    var dir = Directory('${root.path}/empty')..createSync();
    var here = otherSettings()..saveProvider(claude);
    var store2 = TranslationStore('${root.path}/b.db');
    addTearDown(store2.close);
    expect(TranslationBackup.read(dir, settings: here, store: store2), 0);
    expect(here.providers.single.key, 'secret-1');
  });
}
