import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/hitomi_network/image.dart';

import 'support/fake_http.dart';

// How every kind of image is fetched, cached and cleaned up. The image
// bytes are arbitrary: nothing here decodes them.
void main() {
  final http = useFakeHttp();
  // Created on first use: it needs the cookie jar from useFakeHttp.
  late final manager = ImageManager();
  final sources = ComicSource.sources;

  // A JPEG header followed by filler, so type detection has something to see.
  Uint8List jpeg(int length, [int fill = 7]) => Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(length - 4, fill)]);

  const jpegHeaders = {'content-type': 'image/jpeg'};

  var serial = 0;
  String unique(String prefix) => '$prefix${serial++}';

  setUpAll(() => ComicSource.sources = [ehentai]);
  tearDownAll(() => ComicSource.sources = sources);

  tearDown(() {
    expect(ImageManager.loadingItems, isEmpty,
        reason: 'an image was left marked as loading');
  });

  int requestsFor(String part) =>
      http.urls.where((url) => url.contains(part)).length;

  /// Every file in the cache directory.
  Set<String> filesOnDisk() {
    final dir = Directory(CacheManager.cachePath);
    if (!dir.existsSync()) return {};
    return {
      for (final file in dir.listSync(recursive: true).whereType<File>())
        file.path,
    };
  }

  group('plain image', () {
    test('is downloaded, reported and cached', () async {
      final url = 'https://img.example/${unique('a')}.jpg';
      final bytes = jpeg(3000);
      http.on(url, (request) {
        expect(request.headers['User-Agent'], webUA);
        expect(request.headers['X-Test'], '1');
        return FakeResponse.chunked(
            [bytes.sublist(0, 1000), bytes.sublist(1000)],
            headers: {...jpegHeaders, 'Content-Length': '3000'});
      });
      final events = await manager.getImage(url, {'X-Test': '1'}).toList();

      expect(events.first.currentBytes, 0);
      expect(events.first.finished, isFalse);
      expect(events.map((e) => e.currentBytes), containsAllInOrder([1000, 3000]));
      final last = events.last;
      expect(last.finished, isTrue);
      expect(last.data, bytes);
      expect(last.ext, 'jpg');
      expect(last.url, url);
      // Only the last event is complete.
      expect(events.where((e) => e.finished), hasLength(1));

      final cached = await CacheManager().findCache(url);
      expect(cached, last.savePath);
      expect(File(cached!).readAsBytesSync(), bytes);
      expect(CacheManager().getType(url), 'jpg');
    });

    test('a cached image is not downloaded again', () async {
      final url = 'https://img.example/${unique('b')}.png';
      http.on(url, (_) =>
          FakeResponse(jpeg(100), headers: {'content-type': 'image/png'}));
      await manager.getImage(url).last;
      final events = await manager.getImage(url).toList();
      expect(requestsFor(url), 1);
      expect(events, hasLength(1));
      expect(events.single.finished, isTrue);
      expect(events.single.data, isNull);
      expect(events.single.ext, 'png');
      expect(File(events.single.savePath).lengthSync(), 100);
    });

    test('the type falls back to the address, then to jpg', () async {
      final webp = 'https://img.example/${unique('c')}.webp';
      http.on(webp, (_) => FakeResponse(jpeg(10)));
      expect((await manager.getImage(webp).last).ext, 'webp');
      final unknown = 'https://img.example/${unique('d')}';
      http.on(unknown, (_) => FakeResponse(jpeg(10)));
      expect((await manager.getImage(unknown).last).ext, 'jpg');
    });

    test('a 4xx answer is a BadRequestException and leaves no file',
        () async {
      final url = 'https://img.example/${unique('gone')}.jpg';
      http.on(url, (_) => FakeResponse('nope', status: 403));
      final before = filesOnDisk();
      await expectLater(manager.getImage(url).drain<void>(),
          throwsA(isA<BadRequestException>()));
      expect(await CacheManager().findCache(url), isNull);
      expect(filesOnDisk(), before);
    });

    test('cancelling removes the partial file', () async {
      final url = 'https://img.example/${unique('slow')}.jpg';
      http.on(url, (_) => FakeResponse.chunked(
          [for (var i = 0; i < 40; i++) jpeg(64 * 1024)],
          pause: const Duration(milliseconds: 20), headers: jpegHeaders));
      final before = filesOnDisk();
      var sawPartialFile = false;
      late final StreamSubscription<DownloadProgress> subscription;
      subscription = manager.getImage(url).listen((event) {
        // More than 1 MB received: part of it is on disk by now.
        if (event.currentBytes > 1200 * 1024) {
          sawPartialFile = File(event.savePath).existsSync();
          subscription.cancel();
        }
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(sawPartialFile, isTrue);
      expect(await CacheManager().findCache(url), isNull);
      expect(filesOnDisk(), before);
    });

    test('s.exhentai.org images are fetched from ehgt.org, three at a time',
        () async {
      final names = [for (var i = 0; i < 5; i++) unique('t')];
      var active = 0, most = 0;
      http.on('ehgt.org/t/', (_) async {
        active++;
        if (active > most) most = active;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        active--;
        return FakeResponse(jpeg(20), headers: jpegHeaders);
      });
      await Future.wait([
        for (final name in names)
          manager.getImage('https://s.exhentai.org/t/$name.jpg').drain<void>(),
      ]);
      expect(requestsFor('ehgt.org/t/'), 5);
      expect(requestsFor('s.exhentai.org'), 0);
      expect(most, lessThanOrEqualTo(3));
      expect(manager.ehgtLoading, 0);
    });

    test('the ehgt limit is released after a failure', () async {
      http.on('ehgt.org/fail/', (_) => FakeResponse('x', status: 404));
      await expectLater(
          manager.getImage('https://ehgt.org/fail/${unique('f')}.jpg').drain<void>(),
          throwsA(isA<BadRequestException>()));
      expect(manager.ehgtLoading, 0);
    });
  });

  group('hitomi image', () {
    const hash =
        '22cefb5a6b2362452903f15ad7e7c593955d7edf87559541a209a1f9c29ede62';

    test('is resolved through gg.js and cached under its hash', () async {
      GG.cacheTime = null;
      http.file('/gg.js', 'hitomi/gg.js');
      final bytes = jpeg(500);
      http.on('/742/$hash.webp', (request) {
        expect(request.headers['Referer'], 'https://hitomi.la/reader/9.html');
        return FakeResponse(bytes,
            headers: {'content-type': 'image/webp', 'content-length': '500'});
      });
      final file = HitomiFile('1.png', hash, false, true, 10, 10, '9');
      final events = await manager.getHitomiImage(file, '9').toList();
      final last = events.last;
      // The size is announced, but an event only counts as finished once the
      // file is complete on disk: downloads copy the file at that moment.
      expect(events.where((e) => e.finished), hasLength(1));
      expect(File(last.savePath).lengthSync(), 500);
      expect(last.data, bytes);
      expect(last.ext, 'webp');
      expect(await CacheManager().findCache(hash), last.savePath);

      final again = await manager.getHitomiImage(file, '9').toList();
      expect(again.single.ext, 'webp');
      expect(requestsFor('/742/$hash.webp'), 1);
    });
  });

  group('jm image', () {
    test('is cached under the address without its query', () async {
      // Chapter ids below the scramble id are not scrambled, so the bytes
      // are stored as they arrive.
      final name = unique('jm');
      final url = 'https://cdn.example/media/photos/100/$name.webp?v=123';
      final bytes = jpeg(800);
      http.on('/media/photos/100/$name.webp', (request) {
        expect(request.headers['X-Requested-With'], isNotNull);
        return FakeResponse.chunked([bytes.sublist(0, 300), bytes.sublist(300)],
            headers: {'content-type': 'image/webp'});
      });
      final events = await manager.getJmImage(url, null,
          epsId: '100', scrambleId: '220980', bookId: '$name.webp').toList();
      expect(events.last.data, bytes);
      expect(events.last.ext, 'webp');
      expect(events.last.finished, isTrue);
      // The size is unknown until the end, so no earlier event is complete.
      expect(events.where((e) => e.finished), hasLength(1));

      final key = url.split('?').first;
      final cached = await CacheManager().findCache(key);
      expect(File(cached!).readAsBytesSync(), bytes);

      final again = await manager.getJmImage('$key?v=456', null,
          epsId: '100', scrambleId: '220980', bookId: '$name.webp').toList();
      expect(again.single.finished, isTrue);
      expect(requestsFor('/media/photos/100/$name.webp'), 1);
    });

    test('a failed download leaves no file', () async {
      final url = 'https://cdn.example/media/photos/100/${unique('jm')}.webp';
      http.on(url, (_) => FakeResponse('x', status: 404));
      final before = filesOnDisk();
      await expectLater(
          manager.getJmImage(url, null,
              epsId: '100', scrambleId: '220980', bookId: 'x.webp').drain<void>(),
          throwsA(isA<BadRequestException>()));
      expect(filesOnDisk(), before);
    });
  });

  group('image of a custom source', () {
    test('page image', () async {
      final url = 'https://img.example/${unique('custom')}.jpg';
      final bytes = jpeg(600);
      http.on(url, (request) {
        expect(request.headers['user-agent'], webUA);
        return FakeResponse(bytes, headers: jpegHeaders);
      });
      final last =
          await manager.getCustomImage(url, 'comic', 'ep', 'ehentai').last;
      expect(last.data, bytes);
      expect(last.ext, 'jpg');
      final key = 'ehentaicomicep$url';
      expect(await CacheManager().findCache(key), last.savePath);
      final again =
          await manager.getCustomImage(url, 'comic', 'ep', 'ehentai').toList();
      expect(again.single.finished, isTrue);
      expect(again.single.ext, 'jpg');
      expect(requestsFor(url), 1);
    });

    test('thumbnail', () async {
      final url = 'https://img.example/${unique('thumb')}.jpg';
      final bytes = jpeg(200);
      http.on(url, (request) {
        expect(request.headers['Referer'], 'https://ref.example/');
        return FakeResponse(bytes, headers: jpegHeaders);
      });
      final last = await manager
          .getCustomThumbnail(url, 'ehentai', {'Referer': 'https://ref.example/'})
          .last;
      expect(last.data, bytes);
      expect(last.finished, isTrue);
      expect(await CacheManager().findCache('ehentai$url'), last.savePath);
    });

    test('an unknown source is an error', () async {
      await expectLater(
          manager.getCustomImage('https://img.example/x.jpg', 'c', 'e', 'nope')
              .drain<void>(),
          throwsA(contains('Unknown Comic Source')));
    });
  });

  group('e-hentai image', () {
    const link = 'https://e-hentai.org/g/4331550/a41fff6a79/';
    late Gallery gallery;

    String api({required String image, String? nl, String original = ''}) =>
        jsonEncode({
          'i3': '<a onclick="return load_image(2)" href="#">'
              '<img id="img" src="$image" style="width:1280px" /></a>',
          'i6': '<div><a href="#" id="loadfail" onclick="return nl(\'$nl\')">'
              'Reload broken image</a></div>'
              '<div><a href="$original">Download original</a></div>',
        });

    setUpAll(() async {
      http.file('/g/4331550/a41fff6a79/', 'eh/gallery.html');
      http.file(RegExp(r'/s/[0-9a-f]+/4331550-\d+$'), 'eh/reader.html');
    });

    setUp(() async {
      gallery = (await EhNetwork().getGalleryInfo(link)).data;
    });

    test('is resolved through the reader page and the API', () async {
      final image = 'https://hath.example/${unique('eh')}/1.webp';
      final bytes = jpeg(900);
      Map<String, dynamic>? apiCall;
      http.on('api.e-hentai.org/api.php', (request) {
        apiCall = Map<String, dynamic>.from(request.data as Map);
        return FakeResponse(api(image: image, nl: '111-222'));
      });
      http.on(image, (_) => FakeResponse.chunked(
          [bytes.sublist(0, 400), bytes.sublist(400)],
          headers: {'Content-Length': '900'}));

      final events = await manager.getEhImageNew(gallery, 1).toList();
      expect(apiCall, {
        'gid': 4331550,
        'imgkey': 'c301571671',
        'method': 'showpage',
        'page': 1,
        'showkey': 'vdoxvuxaooh',
      });
      expect(events.last.finished, isTrue);
      expect(events.last.data, bytes);
      expect(events.last.ext, 'jpg');
      expect(events.where((e) => e.finished), hasLength(1));
      expect(File((await CacheManager().findCache('${link}1'))!).readAsBytesSync(),
          bytes);

      final again = await manager.getEhImageNew(gallery, 1).toList();
      expect(again.single.finished, isTrue);
      expect(requestsFor(image), 1);
    });

    test('a failed image is retried through the reload key', () async {
      final broken = 'https://hath.example/${unique('eh')}/broken.webp';
      final good = 'https://hath.example/${unique('eh')}/good.webp';
      final bytes = jpeg(700);
      gallery.auth!['showKey'] = 'vdoxvuxaooh';
      http.on('api.e-hentai.org/api.php',
          (_) => FakeResponse(api(image: broken, nl: '111-222')));
      http.on(broken, (_) => FakeResponse.chunked(
          [bytes.sublist(0, 100)], status: 500));
      // The reader page asked with ?nl= gives another server.
      http.on(RegExp(r'/s/[0-9a-f]+/4331550-2\?nl=111-222$'), (_) => FakeResponse(
          fixture('eh/reader.html').replaceFirst(
              RegExp(r'(<img[^>]*id="img"[^>]*src=")[^"]+'), '<img id="img" src="$good')));
      http.on(good, (_) => FakeResponse(bytes, headers: {'Content-Length': '700'}));

      final last = await manager.getEhImageNew(gallery, 2).last;
      expect(last.data, bytes);
      expect(requestsFor(broken), greaterThanOrEqualTo(1));
      expect(requestsFor(good), 1);
      expect(File((await CacheManager().findCache('${link}2'))!).lengthSync(), 700);
    });

    test('an image without an announced size loads', () async {
      final image = 'https://hath.example/${unique('eh')}/nosize.webp';
      final bytes = jpeg(400);
      gallery.auth!['showKey'] = 'vdoxvuxaooh';
      http.on('api.e-hentai.org/api.php',
          (_) => FakeResponse(api(image: image, nl: '1-2')));
      http.on(image, (_) => FakeResponse.chunked([bytes]));
      final events = await manager.getEhImageNew(gallery, 4).toList();
      expect(events.last.data, bytes);
      expect(events.where((e) => e.finished), hasLength(1));
      expect(requestsFor(image), 1);
    });

    test('a gallery in the multi-page viewer gets its images from the API',
        () async {
      final image = 'https://hath.example/${unique('eh')}/mpv.webp';
      final bytes = jpeg(300);
      final requests = <Map<String, dynamic>>[];
      http.on(RegExp(r'/s/[0-9a-f]+/4331550-5$'), (_) => FakeResponse(
          '<html><body><script type="text/javascript">'
          'var gid=4331550; var mpvkey = "mpv123"; '
          'var imagelist = [{"n":"1.jpg","k":"k1"},{"n":"2.jpg","k":"k2"},'
          '{"n":"3.jpg","k":"k3"},{"n":"4.jpg","k":"k4"},{"n":"5.jpg","k":"k5"}]; '
          'var pagecount = 5;</script></body></html>'));
      http.on('api.e-hentai.org/api.php', (request) {
        requests.add(Map<String, dynamic>.from(request.data as Map));
        return FakeResponse(jsonEncode({'i': image, 's': 'nl-1'}));
      });
      http.on(image, (_) => FakeResponse(bytes));

      final last = await manager.getEhImageNew(gallery, 5).last;
      expect(requests.single, {
        'gid': 4331550,
        'imgkey': 'k5',
        'method': 'imagedispatch',
        'page': 5,
        'mpvkey': 'mpv123',
      });
      expect(last.data, bytes);
      expect(File((await CacheManager().findCache('${link}5'))!).lengthSync(), 300);
    });

    test('the limit page is reported as ImageExceedError', () async {
      gallery.auth!['showKey'] = 'vdoxvuxaooh';
      http.on('api.e-hentai.org/api.php', (_) => FakeResponse(
          api(image: 'https://ehgt.org/g/509.gif', nl: '1-2')));
      final before = filesOnDisk();
      await expectLater(manager.getEhImageNew(gallery, 3).drain<void>(),
          throwsA(isA<ImageExceedError>()));
      expect(await CacheManager().findCache('${link}3'), isNull);
      expect(filesOnDisk(), before);
    });
  });

}
