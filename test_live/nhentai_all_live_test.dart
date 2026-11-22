// These are tests, but outside test/ so the normal run skips them.
// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member

// Checks nhentai's "all galleries" category against the real site: no tag and
// no language picked, with and without the user's excluded tags, in every
// order. Run it with
//
//     flutter test test_live/nhentai_all_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    AppTranslation.translations = {};
    root = Directory.systemTemp.createTempSync('pica_live_test');
    CacheManager.instance =
        CacheManager.createForTest('${root.path}/cache', '${root.path}/cache.db');
    SingleInstanceCookieJar.instance = null;
    SingleInstanceCookieJar(':memory:');
  });

  tearDownAll(() {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    CacheManager.instance = null;
    root.deleteSync(recursive: true);
  });

  test('every gallery, in each order', () async {
    final network = NhentaiNetwork();
    await network.init();
    for (final sort in [NhentaiSort.recent, NhentaiSort.popularWeek]) {
      for (final excludes in ['', '-tag:yaoi']) {
        final pages = <List<String>>[];
        for (final page in [1, 2]) {
          final res =
              await network.getAllComics(page, sort, excludes: excludes);
          print('$sort "$excludes" page $page: ${res.errorMessage ?? ''} '
              '${res.error ? '' : '${res.data.length} galleries, last page ${res.subData}'}');
          expect(res.error, isFalse, reason: res.errorMessage);
          expect(res.data, isNotEmpty);
          expect(res.subData, greaterThan(1));
          pages.add([for (final comic in res.data) comic.id]);
          // One request at a time, as a reader would; the site limits bursts.
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        expect(pages[0].toSet().intersection(pages[1].toSet()), isEmpty,
            reason: 'page 2 repeats page 1');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
