import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/page_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<Uri> requests;
  late List<String> history;
  late String language;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    requests = [];
    history = List.from(appdata.searchHistory);
    language = appdata.settings[69];
    appdata.settings[69] = '0';
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        final uri = options.uri;
        if (uri.path == '/api/v2/cdn') {
          handler.resolve(Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: jsonEncode({
              'image_servers': ['https://i9.example'],
              'thumb_servers': ['https://t9.example'],
            }),
          ));
          return;
        }
        requests.add(uri);
        final page = int.parse(uri.queryParameters['page'] ?? '1');
        handler.resolve(Response<String>(
          requestOptions: options,
          statusCode: 200,
          data: jsonEncode({
            'result': [
              {
                'id': 100 + page,
                'media_id': '9$page',
                'english_title': 'Page $page',
                'thumbnail': 'galleries/9$page/thumb.webp',
                'tag_ids': [20905],
                'blacklisted': false,
              },
            ],
            'num_pages': 12,
            'per_page': 25,
            'total': 300,
          }),
        ));
      }));
  });

  tearDown(() {
    network.dio.close();
    network.cookieJar = null;
    cookies.dispose();
    SingleInstanceCookieJar.instance = null;
    appdata.searchHistory = history;
    appdata.settings[69] = language;
  });

  const sorts = {
    NhentaiSort.popularToday: 'popular-today',
    NhentaiSort.popularWeek: 'popular-week',
    NhentaiSort.popularMonth: 'popular-month',
    NhentaiSort.popularAll: 'popular',
  };

  for (final entry in sorts.entries) {
    test(
        'tag navigation ${entry.value} uses search with exact category and page',
        () async {
      for (final type in [
        'tag',
        'artist',
        'group',
        'parody',
        'character',
        'category',
      ]) {
        final result = await nhentai.categoryComicsData!
            .load('full-color', '/$type/full-color', [entry.key.value], 2);
        expect(result.error, isFalse);
        expect(requests.last.path, '/api/v2/search');
        expect(requests.last.queryParameters, {
          'query': '$type:"full color"',
          'page': '2',
          'sort': entry.value,
        });
        expect(result.data.single.id, '102');
        expect(result.subData, 12);
      }
      expect(appdata.searchHistory, history);
    });

    test('all languages ${entry.value} retain sorting across pages 1 to 3',
        () async {
      for (final lang in ['chinese', 'japanese', 'english']) {
        final ids = <String>[];
        for (var page = 1; page <= 3; page++) {
          final result = await nhentai.categoryComicsData!
              .load(lang, '/language/$lang', [entry.key.value], page);
          expect(result.error, isFalse);
          expect(requests.last.path, '/api/v2/search');
          expect(requests.last.queryParameters, {
            'query': 'language:"$lang"',
            'page': '$page',
            'sort': entry.value,
          });
          ids.add(result.data.single.id);
          expect(result.subData, 12);
        }
        expect(ids, ['101', '102', '103']);
      }
      expect(requests, hasLength(9));
    });
  }

  test('recent categories search their namespace by date on the page asked',
      () async {
    for (final (path, query) in [
      ('/tag/full-color', 'tag:"full color"'),
      ('/language/chinese', 'language:"chinese"'),
      ('/language/japanese', 'language:"japanese"'),
      ('/language/english', 'language:"english"'),
    ]) {
      final result =
          await network.getCategoryComics(path, 3, NhentaiSort.recent);
      expect(result.error, isFalse);
      expect(requests.last.path, '/api/v2/search');
      expect(requests.last.queryParameters,
          {'query': query, 'sort': 'date', 'page': '3'});
      expect(result.data.single.id, '103');
      expect(result.subData, 12);
    }
  });

  test('a list comic gets its cover from the thumbnail server', () async {
    final result = await network.search('x', 1);
    expect(result.data.single.cover, 'https://t9.example/galleries/91/thumb.webp');
    expect(result.data.single.title, 'Page 1');
    expect(result.data.single.tags, ['full color']);
  });

  test('an empty search lists the newest, or everything with a space',
      () async {
    await network.searchQuery('', 2, NhentaiSort.recent);
    expect(requests.last.path, '/api/v2/galleries');
    expect(requests.last.queryParameters, {'page': '2'});
    await network.searchQuery('  ', 2, NhentaiSort.popularWeek);
    expect(requests.last.path, '/api/v2/search');
    expect(requests.last.queryParameters,
        {'query': ' ', 'sort': 'popular-week', 'page': '2'});
  });

  test('global language filter also preserves search sort and page', () async {
    appdata.settings[69] = '1';
    for (final entry in sorts.entries) {
      final result = await nhentai.categoryComicsData!
          .load('glasses', '/tag/glasses', [entry.key.value], 3);
      expect(result.error, isFalse);
      expect(requests.last.queryParameters, {
        'query': 'tag:glasses language:chinese',
        'page': '3',
        'sort': entry.value,
      });
      expect(result.data.single.id, '103');
      expect(result.subData, 12);
    }
  });

  test('search pagination reads page only, not digits inside query', () async {
    final result =
        await network.search('artist:123', 2, NhentaiSort.popularAll);
    expect(result.error, isFalse);
    expect(result.subData, 12);
    expect(appdata.searchHistory.last, 'artist:123');
  });

  test('category search quotes multiword names and decodes URL components', () {
    expect(nhentaiCategoryQuery('/tag/full-color/'), 'tag:"full color"');
    expect(nhentaiCategoryQuery('/artist/c%2B%2B'), 'artist:"c++"');
    expect(nhentaiCategoryQuery('/group/%E7%A4%BA%E4%BE%8B'), 'group:"示例"');
  });

}
