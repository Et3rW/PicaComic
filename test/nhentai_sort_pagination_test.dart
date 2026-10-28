import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
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
        requests.add(uri);
        if (uri.path.contains('/popular') &&
            !uri.path.startsWith('/language/')) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: 404),
          ));
          return;
        }
        // Reproduce the reported legacy Chinese route returning page one.
        final page = uri.path.startsWith('/language/chinese/popular')
            ? 1
            : int.parse(uri.queryParameters['page'] ?? '1');
        handler.resolve(Response<String>(
          requestOptions: options,
          statusCode: 200,
          data: '<div class="gallery" data-tags="20905">'
              '<a href="/g/${100 + page}/"><img src="https://example.com/a.jpg"></a>'
              '<div class="caption">Page $page</div></div>'
              '<section class="pagination"><a class="last" '
              'href="/search/?q=artist%3A123&amp;page=12&amp;sort=popular">Last</a></section>',
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
        expect(requests.last.path, '/search/');
        expect(requests.last.queryParameters, {
          'q': '$type:"full color"',
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
          expect(requests.last.path, '/search/');
          expect(requests.last.queryParameters, {
            'q': 'language:"$lang"',
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

  test('recent categories keep their working route and requested page',
      () async {
    for (final path in [
      '/tag/full-color',
      '/language/chinese',
      '/language/japanese',
      '/language/english'
    ]) {
      final result =
          await network.getCategoryComics(path, 3, NhentaiSort.recent);
      expect(result.error, isFalse);
      expect(requests.last.path, '$path/');
      expect(requests.last.queryParameters, {'page': '3'});
      expect(result.data.single.id, '103');
      expect(result.subData, 12);
    }
  });

  test('global language filter also preserves search sort and page', () async {
    appdata.settings[69] = '1';
    for (final entry in sorts.entries) {
      final result = await nhentai.categoryComicsData!
          .load('glasses', '/tag/glasses', [entry.key.value], 3);
      expect(result.error, isFalse);
      expect(requests.last.queryParameters, {
        'q': 'tag:glasses language:chinese',
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

  test('pagination accepts nested relative or absolute links and no last link',
      () {
    final doc = parse('<section class="pagination"><span>'
        '<a href="https://nhentai.net/search/?q=123&amp;page=9">Last</a></span>'
        '<a href="?q=456&amp;page=bad">Invalid</a>'
        '<a href="?q=789&amp;page=-3">Invalid</a></section>');
    expect(nhentaiLastPage(doc, 2), 9);
    expect(
        nhentaiLastPage(
            parse('<section class="pagination">'
                '<a href="?page=4">Next</a></section>'),
            3),
        4);
    expect(nhentaiLastPage(parse('<main></main>'), 3), 3);
  });
}
