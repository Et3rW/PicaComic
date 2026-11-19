// These are tests, but outside test/ so the normal run skips them.
// ignore_for_file: invalid_use_of_visible_for_testing_member

// Checks every built-in source against the real site.
//
// Not part of the normal test run (it lives outside test/): it needs network
// access and depends on the sites. Run it with
//
//     flutter test test_live
//
// A source fails when its site answers but the app can no longer make sense
// of the answer. A site that cannot be reached from this machine (blocked,
// down, challenge page) is reported as skipped, not failed.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/picacg_network/headers.dart' as picacg;
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/file_type.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Unreachable implements Exception {
  final String message;
  Unreachable(this.message);
}

final _networkFailure = RegExp(
    r'SocketException|HandshakeException|HttpException|TlsException|'
    r'Failed host lookup|[Tt]imed? ?out|超时|Connection (closed|reset|refused)|'
    r'status code of (403|429|5\d\d)|Cloudflare|[Cc]hallenge|temporarily banned');

/// The data of [res], or [Unreachable] when the request itself failed.
T need<T>(Res<T> res, String what) {
  if (!res.error) return res.data;
  final message = res.errorMessage ?? 'unknown error';
  if (_networkFailure.hasMatch(message)) {
    throw Unreachable('$what: $message');
  }
  fail('$what: $message');
}

/// Loads one image the way the reader does and checks what ends up in the
/// cache.
Future<void> expectLoads(Stream<DownloadProgress> image) async {
  final DownloadProgress last;
  try {
    last = await image.last;
  } on DioException catch (e) {
    throw Unreachable('image host: ${e.message ?? e.error}');
  }
  expect(last.finished, isTrue);
  final data = last.data ?? await last.getFile().readAsBytes();
  expect(data, isNotEmpty);
  expect(detectFileType(data).mime, startsWith('image/'),
      reason: 'what was downloaded is not an image');
  expect(last.getFile().lengthSync(), data.length,
      reason: 'the cached file differs from the image');
}

void source(String name, Future<void> Function() body) {
  test(name, () async {
    try {
      await body();
    } on Unreachable catch (e) {
      // ignore: avoid_print
      print('::warning title=$name unreachable::${e.message}');
      markTestSkipped('$name could not be reached: ${e.message}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() {
    // The test binding blocks HTTP; these checks are about the real network.
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

  source('e-hentai', () async {
    final network = EhNetwork();
    // Category filter 767 = Non-H only.
    final list = need(
        await network.getGalleries('https://e-hentai.org/?f_cats=767'), 'list');
    expect(list.galleries, isNotEmpty, reason: 'no galleries in the list');
    expect(list.next, isNotNull, reason: 'no link to the next page');
    final first = list.galleries.first;
    expect(first.title, isNotEmpty);
    expect(first.link, matches(r'^https://e-hentai\.org/g/\d+/[0-9a-f]+/$'));
    expect(first.coverPath, startsWith('http'));

    final gallery = need(await network.getGalleryInfo(first.link), 'gallery');
    expect(gallery.title, isNotEmpty);
    expect(int.parse(gallery.maxPage), greaterThan(0));
    expect(gallery.auth!['gid'], isNotEmpty);
    expect(gallery.auth!['token'], isNotEmpty);

    final reader = need(await network.getReaderLink(first.link, 1), 'reader');
    expect(reader, matches(r'^https://e-hentai\.org/s/[0-9a-f]+/\d+-1$'));
    await expectLoads(ImageManager().getEhImageNew(gallery, 1));
  });

  source('wnacg', () async {
    final network = HtmangaNetwork();
    final base = HtmangaNetwork.baseUrl;
    final home = need(await network.getHomePage(), 'home page');
    expect(home.links, isNotEmpty, reason: 'no sections on the home page');
    expect(home.comics.expand((section) => section), isNotEmpty);

    final list = need(await network.getComicList('$base/albums.html', 1), 'list');
    expect(list, isNotEmpty, reason: 'no galleries in the list');
    // A series (合集) lists its chapters, which are galleries of their own,
    // and has no pages itself: check the first ordinary gallery.
    HtComicBrief? first;
    HtComicInfo? info;
    for (final comic in list.take(6)) {
      expect(comic.name, isNotEmpty);
      expect(int.parse(comic.id), greaterThan(0));
      final candidate = need(await network.getComicInfo(comic.id), 'gallery');
      expect(candidate.name, isNotEmpty);
      if (candidate.thumbnails.isNotEmpty) {
        first = comic;
        info = candidate;
        break;
      }
    }
    expect(first, isNotNull, reason: 'no gallery with thumbnails among the first six');
    expect(info!.pages, greaterThan(0));

    final images = need(await network.getImages(first!.id), 'image list');
    expect(images, isNotEmpty, reason: 'no images for gallery ${first.id}');
    await expectLoads(ImageManager().getImage(images.first));
  });

  source('hitomi', () async {
    final network = HiNetwork();
    final domain = network.baseDomain;
    final list = need(
        await network.getComics('https://ltn.$domain/index-all.nozomi'), 'index');
    expect(list.comicIds, isNotEmpty);
    expect(list.total, greaterThan(1000));

    final id = list.comicIds.first.toString();
    final comic = need(await network.getComicInfo(id), 'gallery');
    expect(comic.name, isNotEmpty);
    expect(comic.files, isNotEmpty);

    await expectLoads(ImageManager().getHitomiImage(comic.files.first, id));
  });

  source('jm', () async {
    final network = JmNetwork();
    final domains = await network.getApiDomains();
    if (domains.error) throw Unreachable('domain list: ${domains.errorMessage}');
    appdata.appSettings.jmApiDomains = List<String>.from(domains.data);

    final home = need(await network.getHomePage(), 'home page');
    expect(home.items, isNotEmpty);
    final comics = home.items.expand((item) => item.comics).toList();
    expect(comics, isNotEmpty, reason: 'no comics on the home page');

    final id = comics.first.id;
    final info = need(await network.getComicInfo(id), 'album');
    expect(info.name, isNotEmpty);

    final chapter = info.series.isEmpty ? id : info.series.values.first;
    final images = need(await network.getChapter(chapter), 'chapter');
    expect(images, isNotEmpty, reason: 'no images in chapter $chapter');
    final image = images.first;
    await expectLoads(ImageManager().getJmImage(image, null,
        epsId: chapter,
        scrambleId: '220980',
        bookId: image.substring(image.lastIndexOf('/') + 1)));
  });

  source('nhentai', () async {
    final network = NhentaiNetwork();
    await network.init();
    final home = need(await network.getHomePage(), 'home page');
    expect(home.latest, isNotEmpty, reason: 'no galleries on the home page');
    final first = home.latest.first;
    expect(first.title, isNotEmpty);

    final comic = need(await network.getComicInfo(first.id), 'gallery');
    expect(comic.title, isNotEmpty);
    expect(comic.thumbnails, isNotEmpty);

    final images = need(await network.getImages(first.id), 'image list');
    expect(images, isNotEmpty);
    await expectLoads(ImageManager().getImage(images.first));
  });

  // Every picacg endpoint needs an account. Without one the only thing that
  // can be checked is that the server still accepts how requests are signed:
  // it then answers "unauthorized" rather than rejecting the signature.
  source('picacg', () async {
    final options = picacg.getHeaders('get', '', 'categories');
    options.validateStatus = (_) => true;
    options.responseType = ResponseType.plain;
    final dio = logDio(options);
    try {
      final Response<String> res;
      try {
        res = await dio.get<String>('https://picaapi.picacomic.com/categories');
      } on DioException catch (e) {
        throw Unreachable('api: ${e.message ?? e.error}');
      }
      final Object? body;
      try {
        body = jsonDecode(res.data ?? '');
      } on FormatException {
        throw Unreachable('api answered ${res.statusCode} without JSON');
      }
      expect(body, isA<Map>());
      expect(res.statusCode, 401, reason: 'unexpected answer: $body');
      expect((body as Map)['message'], 'unauthorized',
          reason: 'unexpected answer: $body');
    } finally {
      dio.close(force: true);
    }
  });
}
