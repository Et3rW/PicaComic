import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/page_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

String embedded(String path, Object payload) =>
    '<script data-sveltekit-fetched data-url="$path">'
    '${jsonEncode({'body': jsonEncode(payload)})}</script>';

String card(String id, {String oldTags = ''}) =>
    '<div class="gallery" data-tags="$oldTags">'
    '<a href="/g/$id/"><img src="https://example.com/cover.jpg"></a>'
    '<div class="caption">Sample $id</div></div>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<String> requests;

  void serve(String html) {
    network.dio.close();
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options.uri.toString());
          handler.resolve(Response<String>(
            requestOptions: options,
            data: html,
            statusCode: 200,
          ));
        },
      ));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    network.logged = true;
    network.dio = Dio();
    requests = [];
  });
  tearDown(() {
    network.dio.close();
    cookies.dispose();
    SingleInstanceCookieJar.instance = null;
    network.cookieJar = null;
    network.logged = false;
  });

  test(
      'explore popular and latest cards retain embedded tags without data-tags',
      () async {
    serve('${embedded('/api/v2/galleries/popular', [
          {
            'id': 42,
            'tag_ids': [29963, 20905]
          },
        ])}${embedded('/api/v2/galleries/all', {
          'result': [
            {
              'id': 43,
              'tag_ids': ['12227', '8378']
            },
          ]
        })}'
        '<div class="container index-container index-popular">${card('42')}</div>'
        '<div class="container index-container">${card('43')}</div>');
    final response = await network.getHomePage();
    expect(response.error, isFalse);
    expect(response.data.popular.single.lang, '中文');
    expect(response.data.popular.single.tags, contains('full color'));
    expect(response.data.latest.single.lang, 'English');
    expect(response.data.latest.single.tags, contains('glasses'));
    expect(requests, hasLength(1));
  });

  test('favorites keep tags with a single list request', () async {
    serve('${embedded('/api/v2/galleries/favorites', {
          'result': [
            {
              'id': 42,
              'tag_ids': [29963, 20905]
            },
          ]
        })}${card('42')}');
    final response = await network.getFavorites(1);
    expect(response.error, isFalse);
    expect(response.data.single.tags, contains('full color'));
    expect(requests, hasLength(1));
  });

  test('search, categories and explore pagination also carry tags', () async {
    serve('${embedded('/api/v2/galleries/search', {
          'result': [
            {
              'id': 42,
              'tag_ids': [29963, 20905]
            },
          ]
        })}${card('42')}');
    final history = List<String>.from(appdata.searchHistory);
    addTearDown(() => appdata.searchHistory = history);
    final search = await network.search('synthetic search', 1);
    final category =
        await network.getCategoryComics('/tag/sample', 1, NhentaiSort.recent);
    final home = NhentaiHomePageData([], []);
    final more = await network.loadMoreHomePageData(home);
    expect(search.data.single.tags, contains('full color'));
    expect(category.data.single.tags, contains('full color'));
    expect(more.error, isFalse);
    expect(home.latest.single.tags, contains('full color'));
    expect(home.page, 2);
    expect(requests, hasLength(3));
  });

  test('detail recommendations use their own embedded tag IDs', () async {
    serve('${embedded('/api/v2/galleries/42', {
          'id': 42,
          'tag_ids': [20905]
        })}'
        '${embedded('/api/v2/galleries/42/related', [
          {
            'id': 43,
            'tag_ids': [8378]
          },
        ])}'
        '<div id="cover"><a><img src="https://example.com/cover.jpg"></a></div>'
        '<h1 class="title"><span>Example</span></h1>${card('43')}');
    final response = await network.getComicInfo('42');
    expect(response.error, isFalse);
    expect(response.data.recommendations.single.tags, ['glasses']);
    expect(requests, hasLength(1));
  });

  test('legacy tags, whitespace and unknown IDs stay compatible', () {
    final document =
        parse(card('42', oldTags: ' 29963\t20905\n8378 20905 999999999 '));
    final comic = network.parseComic(document.querySelector('.gallery')!);
    expect(comic.lang, '中文');
    expect(comic.tags.where((t) => t == 'full color'), hasLength(1));
    expect(comic.tags, contains('glasses'));
    expect(comic.tags, isNot(contains('999999999')));
  });

  test('bad blocks and unrelated tag records cannot erase valid metadata', () {
    final document = parse('<script data-sveltekit-fetched>invalid</script>'
        '${embedded('/api/v2/galleries/popular', [
          {
            'id': 42,
            'tag_ids': [20905, '8378', 20905, null, {}, 1.5]
          },
          {'id': 43, 'tag_ids': null},
          null,
        ])}'
        '${embedded('/api/v2/galleries/all', {
          'result': [
            {
              'id': '42',
              'tag_ids': [29963]
            },
          ]
        })}'
        '${embedded('/api/v2/tags', [
          {'id': 100, 'name': 'unrelated'}
        ])}');
    final tags = nhentaiTagIdsFromFetchedData(document);
    expect(tags, {
      '42': {'20905', '8378', '29963'}
    });
  });

  test('language matching uses whole IDs instead of substrings', () {
    expect(nhentaiLanguage({'129963', '122270', '63460'}), 'Unknown');
    expect(nhentaiLanguage({'29963'}), '中文');
  });

  test('embedded and legacy IDs merge without duplicates', () {
    final document = parse('${embedded('/api/v2/galleries/42', {
          'id': 42,
          'tag_ids': [20905, 29963],
        })}${card('42', oldTags: '20905 8378')}');
    final comic = network.parseComic(document.querySelector('.gallery')!,
        nhentaiTagIdsFromFetchedData(document));
    expect(comic.tags.where((t) => t == 'full color'), hasLength(1));
    expect(comic.tags, contains('glasses'));
  });

  for (final detailed in [true, false]) {
    testWidgets(
        'tag chips are ${detailed ? 'visible in detailed' : 'hidden in brief'} mode',
        (tester) async {
      final previous = appdata.settings[44];
      addTearDown(() => appdata.settings[44] = previous);
      appdata.settings[44] = detailed ? '0,1.0' : '1,1.0';
      final document = parse('${embedded('/api/v2/galleries/42', {
            'id': 42,
            'tag_ids': [20905, 8378],
          })}${card('42')}');
      final comic = network.parseComic(document.querySelector('.gallery')!,
          nhentaiTagIdsFromFetchedData(document));
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
