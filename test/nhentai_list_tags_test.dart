import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/page_parser.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// nhentai's API, cut down to the fields the app reads. The shapes are those
// of https://nhentai.net/api/v2 (checked 2026-11-26).
Map<String, dynamic> item(int id, List<Object> tagIds,
        {bool blacklisted = false}) =>
    {
      'id': id,
      'media_id': '${id}0',
      'english_title': 'Sample $id',
      'japanese_title': 'サンプル $id',
      'thumbnail': 'galleries/${id}0/thumb.webp',
      'thumbnail_width': 250,
      'thumbnail_height': 350,
      'num_pages': 3,
      'num_favorites': 1,
      'tag_ids': tagIds,
      'blacklisted': blacklisted,
    };

Map<String, dynamic> page(List<Map<String, dynamic>> items, {int pages = 7}) =>
    {'result': items, 'num_pages': pages, 'per_page': 25, 'total': 170};

Map<String, dynamic> gallery(int id) => {
      'id': id,
      'media_id': '${id}0',
      'title': {
        'english': '[Artist] Sample $id [Chinese]',
        'japanese': '[作者] サンプル $id',
        'pretty': 'Sample $id',
      },
      'cover': {'path': 'galleries/${id}0/cover.webp', 'width': 350, 'height': 500},
      'thumbnail': {'path': 'galleries/${id}0/thumb.webp', 'width': 250, 'height': 350},
      'scanlator': '',
      'upload_date': 1795723740,
      'tags': [
        {'id': 29963, 'type': 'language', 'name': 'chinese', 'slug': 'chinese', 'url': '/language/chinese/', 'count': 1},
        {'id': 20905, 'type': 'tag', 'name': 'full color', 'slug': 'full-color', 'url': '/tag/full-color/', 'count': 1},
        {'id': 8378, 'type': 'tag', 'name': 'glasses', 'slug': 'glasses', 'url': '/tag/glasses/', 'count': 1},
        {'id': 5, 'type': 'artist', 'name': 'someone', 'slug': 'someone', 'url': '/artist/someone/', 'count': 1},
        {'id': 6, 'type': 'category', 'name': 'manga', 'slug': 'manga', 'url': '/category/manga/', 'count': 1},
      ],
      'num_pages': 2,
      'num_favorites': 3,
      'pages': [
        for (var n = 1; n <= 2; n++)
          {
            'number': n,
            'path': 'galleries/${id}0/$n.webp',
            'width': 1280,
            'height': 1800,
            'thumbnail': 'galleries/${id}0/${n}t.webp',
            'thumbnail_width': 200,
            'thumbnail_height': 280,
          },
      ],
      'related': [item(43, [8378])],
      'is_favorited': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<RequestOptions> requests;

  /// Answers each request with what [answer] gives for its path: a JSON
  /// value, or an int for an error status.
  void serve(Object? Function(Uri uri) answer) {
    network.dio.close();
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.path == '/api/v2/cdn') {
            handler.resolve(Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: jsonEncode({
                'image_servers': ['https://i7.example'],
                'thumb_servers': ['https://t7.example'],
              }),
            ));
            return;
          }
          requests.add(options);
          final body = answer(options.uri);
          if (body is int) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response<String>(
                requestOptions: options,
                statusCode: body,
                data: '{"error": "status $body"}',
              ),
            ));
            return;
          }
          handler.resolve(Response<String>(
            requestOptions: options,
            data: jsonEncode(body),
            statusCode: 200,
          ));
        },
      ));
  }

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    network.logged = true;
    network.dio = Dio();
    requests = [];
    NhentaiNetwork.rateLimitDelay = Duration.zero;
  });
  tearDown(() {
    network.dio.close();
    cookies.dispose();
    SingleInstanceCookieJar.instance = null;
    network.cookieJar = null;
    network.logged = false;
  });

  test('the home page has the popular strip and the newest', () async {
    serve((uri) => switch (uri.path) {
          '/api/v2/galleries/popular' => [item(42, [29963, 20905])],
          '/api/v2/galleries' => page([item(43, ['12227', '8378'])]),
          _ => 404,
        });
    final response = await network.getHomePage();
    expect(response.error, isFalse);
    expect(response.data.popular.single.lang, '中文');
    expect(response.data.popular.single.tags, contains('full color'));
    expect(response.data.popular.single.cover,
        'https://t7.example/galleries/420/thumb.webp');
    expect(response.data.latest.single.lang, 'English');
    expect(response.data.latest.single.tags, contains('glasses'));
    expect(requests.map((r) => r.uri.path),
        unorderedEquals(['/api/v2/galleries/popular', '/api/v2/galleries']));
  });

  test('the newest still show when the popular strip fails', () async {
    serve((uri) => uri.path == '/api/v2/galleries'
        ? page([item(43, [8378])])
        : 500);
    final response = await network.getHomePage();
    expect(response.error, isFalse);
    expect(response.data.popular, isEmpty);
    expect(response.data.latest.single.id, '43');
  });

  test('loading more asks for the next page of the newest', () async {
    serve((uri) => page([item(44, [20905])]));
    final home = NhentaiHomePageData([], []);
    final more = await network.loadMoreHomePageData(home);
    expect(more.error, isFalse);
    expect(home.latest.single.tags, contains('full color'));
    expect(home.page, 2);
    expect(requests.single.uri.queryParameters, {'page': '2'});
  });

  test('favorites send the user token and give the page count', () async {
    cookies.saveFromResponse(Uri.parse(network.baseUrl), [
      Cookie('access_token', 'secret-token'),
    ]);
    serve((uri) => page([item(42, [29963, 20905])], pages: 4));
    final response = await network.getFavorites(2);
    expect(response.error, isFalse);
    expect(response.data.single.tags, contains('full color'));
    expect(response.subData, 4);
    expect(requests.single.uri.path, '/api/v2/favorites');
    expect(requests.single.uri.queryParameters, {'page': '2'});
    expect(requests.single.headers['Authorization'], 'User secret-token');
  });

  test('anonymous requests carry no token', () async {
    network.logged = false;
    serve((uri) => page([item(42, [])]));
    await network.searchQuery('x', 1, NhentaiSort.recent);
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
  });

  test('blacklisted comics are left out of lists', () async {
    serve((uri) => page([item(42, []), item(43, [], blacklisted: true)]));
    final response = await network.searchQuery('x', 1, NhentaiSort.recent);
    expect(response.data.map((c) => c.id), ['42']);
  });

  test('the detail page comes from one request with related comics',
      () async {
    serve((uri) => uri.path == '/api/v2/galleries/42' ? gallery(42) : 404);
    final response = await network.getComicInfo('42');
    expect(response.error, isFalse);
    expect(requests.single.uri.queryParameters,
        {'include': 'related,favorite'});
    final comic = response.data;
    expect(comic.id, '42');
    expect(comic.title, '[Artist] Sample 42 [Chinese]');
    expect(comic.subTitle, '[作者] サンプル 42');
    expect(comic.cover, 'https://t7.example/galleries/420/cover.webp');
    expect(comic.tags['Tags'], ['full color', 'glasses']);
    expect(comic.tags['Artists'], ['someone']);
    expect(comic.tags['Languages'], ['chinese']);
    expect(comic.tags['Categories'], ['manga']);
    expect(comic.tags['Parodies'], isEmpty);
    expect(comic.tags['Pages'], ['2']);
    expect(comic.tags['时间'], hasLength(1));
    expect(comic.favorite, isTrue);
    expect(comic.thumbnails, [
      'https://t7.example/galleries/420/1t.webp',
      'https://t7.example/galleries/420/2t.webp',
    ]);
    expect(comic.recommendations.single.tags, ['glasses']);
  });

  test('not logged in, the detail page does not ask for the favorite',
      () async {
    network.logged = false;
    serve((uri) => gallery(42));
    final response = await network.getComicInfo('42');
    expect(requests.single.uri.queryParameters, {'include': 'related'});
    expect(response.data.favorite, isFalse);
  });

  test('a random comic is looked up first', () async {
    serve((uri) => switch (uri.path) {
          '/api/v2/galleries/random' => {'id': 42},
          '/api/v2/galleries/42' => gallery(42),
          _ => 404,
        });
    final response = await network.getComicInfo('');
    expect(response.data.id, '42');
  });

  test('images come from the image server', () async {
    serve((uri) => gallery(42));
    final response = await network.getImages('42');
    expect(response.data, [
      'https://i7.example/galleries/420/1.webp',
      'https://i7.example/galleries/420/2.webp',
    ]);
  });

  test('comments are read page by page', () async {
    serve((uri) => {
          'result': [
            {
              'id': int.parse(uri.queryParameters['page']!),
              'gallery_id': 42,
              'poster': {'id': 1, 'username': 'someone', 'avatar_url': 'avatars/1.png'},
              'post_date': 1795723396,
              'body': 'page ${uri.queryParameters['page']}',
            },
          ],
          'num_pages': 2,
        });
    final response = await network.getComments('42');
    expect(response.data.map((c) => c.content), ['page 1', 'page 2']);
    expect(response.data.first.avatar, 'https://i7.example/avatars/1.png');
    expect(response.data.first.userName, 'someone');
    expect(response.data.first.date, 1795723396);
  });

  test('a limited request is asked again once', () async {
    var calls = 0;
    serve((uri) => ++calls == 1 ? 429 : page([item(42, [])]));
    final response = await network.searchQuery('x', 1, NhentaiSort.recent);
    expect(response.error, isFalse);
    expect(calls, 2);
  });

  test('still limited, the error says to try again later', () async {
    serve((uri) => 429);
    final response = await network.searchQuery('x', 1, NhentaiSort.recent);
    expect(response.error, isTrue);
    expect(response.errorMessage, '请求太频繁, 请稍后再试');
    expect(requests, hasLength(2));
  });

  test('an API error is not taken for a Cloudflare check', () async {
    serve((uri) => 403);
    final response = await network.getComicInfo('42');
    expect(response.error, isTrue);
    expect(response.errorMessage, isNot(contains('Cloudflare')));
  });

  test('an expired token is refreshed and the request asked again', () async {
    cookies.saveFromResponse(Uri.parse(network.baseUrl), [
      Cookie('access_token', 'old'),
      Cookie('refresh_token', 'refresh'),
    ]);
    serve((uri) {
      if (uri.path == '/api/v2/auth/refresh') {
        return {'access_token': 'new', 'refresh_token': 'refresh2', 'user': {}};
      }
      return requests.last.headers['Authorization'] == 'User new'
          ? page([item(42, [])])
          : 401;
    });
    final response = await network.getFavorites(1);
    expect(response.error, isFalse);
    expect(requests.map((r) => r.uri.path), [
      '/api/v2/favorites',
      '/api/v2/auth/refresh',
      '/api/v2/favorites',
    ]);
    expect(requests[1].data, {'refresh_token': 'refresh'});
  });

  test('language matching uses whole IDs instead of substrings', () {
    expect(nhentaiLanguage({'129963', '122270', '63460'}), 'Unknown');
    expect(nhentaiLanguage({'29963'}), '中文');
  });

  test('unknown tag IDs are left out of list tags', () {
    final comic = network.parseComic(item(42, [29963, 20905, '8378', 999999999]));
    expect(comic.lang, '中文');
    expect(comic.tags, containsAll(['full color', 'glasses']));
    expect(comic.tags, isNot(contains('999999999')));
  });

  for (final detailed in [true, false]) {
    testWidgets(
        'tag chips are ${detailed ? 'visible in detailed' : 'hidden in brief'} mode',
        (tester) async {
      final previous = appdata.settings[44];
      addTearDown(() => appdata.settings[44] = previous);
      appdata.settings[44] = detailed ? '0,1.0' : '1,1.0';
      final comic = network.parseComic(item(42, [20905, 8378]));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(width: 400, height: 220, child: _TagTestTile(comic)),
      ))));
      expect(find.text('full color'), detailed ? findsOneWidget : findsNothing);
      expect(find.text('glasses'), detailed ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _TagTestTile extends ComicTile {
  final NhentaiComicBrief comic;
  const _TagTestTile(this.comic);
  @override
  Widget get image => const ColoredBox(color: Colors.grey);
  @override
  String get title => comic.title;
  @override
  String get subTitle => comic.id;
  @override
  String get description => comic.lang;
  @override
  List<String> get tags => comic.tags;
  @override
  void onTap_() {}
}
