// These are tests, but outside test/ so the normal run skips them.
// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member

// Checks the rule34video source against the real site: lists, search,
// categories, a video page, and that its smallest file can be fetched in
// parts the way the player and the downloader do. Run it with
//
//     flutter test test_live/rule34video_live_test.dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/file_downloader.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/network/rule34video/rule34video_network.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final network = Rule34VideoNetwork();

  setUpAll(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    AppTranslation.translations = {};
    root = Directory.systemTemp.createTempSync('pica_live_test');
    CacheManager.instance = CacheManager.createForTest(
        '${root.path}/cache', '${root.path}/cache.db');
    SingleInstanceCookieJar.instance = null;
    SingleInstanceCookieJar(':memory:');
  });

  tearDownAll(() {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    CacheManager.instance = null;
    root.deleteSync(recursive: true);
  });

  T need<T>(dynamic res, String what) {
    expect(res.error, isFalse, reason: '$what: ${res.errorMessage}');
    return res.data as T;
  }

  void checkList(List<R34VideoBrief> videos, String what) {
    expect(videos.length, greaterThan(10), reason: what);
    for (var v in videos) {
      expect(v.id, matches(RegExp(r'^\d+/[^/]+$')), reason: what);
      expect(v.title, isNotEmpty, reason: '$what ${v.id}');
      expect(v.cover, startsWith('https://'), reason: '$what ${v.id}');
      expect(v.duration, matches(RegExp(r'^\d+(:\d+)+$')),
          reason: '$what ${v.id}');
    }
  }

  test('lists, in each order and on two pages', () async {
    for (var sort in [R34Sort.latest, R34Sort.mostViewed, R34Sort.topRated]) {
      var first = await network.getList(Rule34VideoNetwork.latestPath, 1, sort);
      var second =
          await network.getList(Rule34VideoNetwork.latestPath, 2, sort);
      var a = need<List<R34VideoBrief>>(first, '$sort 1');
      var b = need<List<R34VideoBrief>>(second, '$sort 2');
      checkList(a, '$sort');
      expect(first.subData, greaterThan(100));
      expect(
          a.map((v) => v.id).toSet().intersection(b.map((v) => v.id).toSet()),
          isEmpty,
          reason: '$sort page 2 repeats page 1');
      print('$sort: ${a.first.title} (${a.first.duration}) ${a.first.info}');
    }
    var week = await network.getList(
        Rule34VideoNetwork.popularPath, 1, R34Sort.viewedWeek);
    checkList(need(week, 'week'), 'week');
  });

  test('search and categories', () async {
    var res = await network.search('big boobs', 2, R34Sort.mostViewed);
    checkList(need(res, 'search'), 'search');
    print('search pages: ${res.subData}');

    var categories = await network.getCategories(1);
    var list = need<List<R34Category>>(categories, 'categories');
    expect(list.length, greaterThan(20));
    expect(list.first.path, startsWith('/categories/'));
    expect(categories.subData, greaterThan(5));
    print('categories: ${list.take(5).map((c) => c.name).join(', ')}');

    var videos = await network.getList(list.first.path, 1);
    checkList(need(videos, list.first.name), list.first.name);
  });

  test('a video page gives every quality, and the file can be fetched',
      () async {
    var latest = need<List<R34VideoBrief>>(
        await network.getList(
            Rule34VideoNetwork.popularPath, 1, R34Sort.viewedWeek),
        'list');
    var video =
        need<R34Video>(await network.getVideo(latest.first.id), 'video');
    print('${video.title}: ${video.sources.map((s) => s.label).join(', ')}; '
        '${video.duration}, ${video.views}, ${video.added}; '
        'by ${video.uploader}; artists ${video.artists}; '
        '${video.categories.length} categories, ${video.tags.length} tags');
    expect(video.title, isNotEmpty);
    expect(video.sources, isNotEmpty);
    expect(video.sources.first.height,
        lessThanOrEqualTo(video.sources.last.height));
    expect(video.poster, startsWith('https://'));
    expect(video.tags, isNotEmpty);
    expect(video.timeline?.at(const Duration(seconds: 1)), isNotNull);

    var dio = Dio(BaseOptions(headers: {'User-Agent': 'Mozilla/5.0'}));
    var head = await dio.head<void>(video.sources.first.url);
    var length = int.parse(head.headers.value('content-length')!);
    expect(length, greaterThan(1000));
    var part = await dio.get<List<int>>(video.sources.first.url,
        options: Options(
            responseType: ResponseType.bytes,
            headers: {'Range': 'bytes=0-1023'}));
    expect(part.statusCode, 206);
    expect(part.data, hasLength(1024));
    // An mp4 starts with an ftyp box.
    expect(String.fromCharCodes(part.data!.sublist(4, 8)), 'ftyp');
  });

  test('a short video downloads whole, the way downloads fetch it', () async {
    // The shortest video among the newest, to keep the file small.
    R34VideoBrief? short;
    for (var page = 1; page <= 3 && short == null; page++) {
      var list = need<List<R34VideoBrief>>(
          await network.getList(Rule34VideoNetwork.latestPath, page), 'list');
      for (var v in list) {
        var parts = v.duration.split(':').map(int.parse).toList();
        if (parts.length == 2 && parts[0] == 0 && parts[1] <= 40) short = v;
      }
    }
    if (short == null) {
      print('no short video among the newest; skipped');
      return;
    }
    var video = need<R34Video>(await network.getVideo(short.id), 'video');
    var source = video.sources.first;
    var path = '${root.path}/download/video.mp4';
    var downloader = FileDownloader(source.url, path, null);
    DownloadingStatus? last;
    await for (var status in downloader.start()) {
      last = status;
    }
    var file = File(path);
    print('${video.title} ${source.label}: ${file.lengthSync()} bytes');
    expect(last!.downloadedBytes, last.totalBytes);
    expect(file.lengthSync(), last.totalBytes);
    var head = file.openSync()..setPositionSync(4);
    expect(String.fromCharCodes(head.readSync(4)), 'ftyp');
    head.closeSync();
    expect(File('$path.download').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
