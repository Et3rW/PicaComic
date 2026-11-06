import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<Uri> requests;
  late List<String> history;
  late String language;
  late Map<String, dynamic> data;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    requests = [];
    history = List.from(appdata.searchHistory);
    language = appdata.settings[69];
    appdata.settings[69] = '0';
    data = {};
    NhentaiTagSettings.dataProvider = () => data;
    NhentaiTagSettings.saver = () async {};
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options.uri);
        handler.resolve(Response<String>(
          requestOptions: options,
          statusCode: 200,
          data: '<div class="gallery" data-tags="20905">'
              '<a href="/g/101/"><img src="https://example.com/a.jpg"></a>'
              '<div class="caption">Title</div></div>',
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

  Future<void> setDefaults() => NhentaiTagSettings.setDefaultExcludes(const [
        NhentaiTagTerm('tag', 'yaoi'),
        NhentaiTagTerm('tag', 'guro'),
      ]);

  test('search appends default exclusions but records the typed keyword',
      () async {
    await setDefaults();
    final result = await nhentai.searchPageData!
        .loadPage!('tag:"glasses" tag:"yaoi"', 1, ['']);
    expect(result.error, isFalse);
    expect(requests.single.path, '/search/');
    // yaoi is included explicitly, so only guro is added.
    expect(requests.single.queryParameters['q'],
        'tag:"glasses" tag:"yaoi" -tag:"guro"');
    expect(appdata.searchHistory.last, 'tag:"glasses" tag:"yaoi"');
  });

  test('search without defaults is unchanged', () async {
    await nhentai.searchPageData!.loadPage!('touhou', 2, ['&sort=popular']);
    expect(requests.single.queryParameters,
        {'q': 'touhou', 'page': '2', 'sort': 'popular'});
  });

  test('recent category uses search when defaults exist', () async {
    await setDefaults();
    await nhentai.categoryComicsData!
        .load('full-color', '/tag/full-color', [''], 3);
    expect(requests.single.path, '/search/');
    expect(requests.single.queryParameters, {
      'q': 'tag:"full color" -tag:"yaoi" -tag:"guro"',
      'page': '3',
    });
  });

  test('stacked tags search the combined query without history', () async {
    await setDefaults();
    final param = nhentaiStackParam(const [
      NhentaiTagTerm('language', 'chinese'),
      NhentaiTagTerm('tag', 'glasses'),
    ]);
    await nhentai.categoryComicsData!
        .load('combo', param, ['&sort=popular'], 2);
    expect(requests.single.path, '/search/');
    expect(requests.single.queryParameters, {
      'q': 'language:chinese tag:"glasses" -tag:"yaoi" -tag:"guro"',
      'page': '2',
      'sort': 'popular',
    });
    expect(appdata.searchHistory, history);
  });

  test('stacked tags get the global language unless they have one', () async {
    appdata.settings[69] = '3';
    await nhentai.categoryComicsData!.load(
        'combo',
        nhentaiStackParam(const [
          NhentaiTagTerm('tag', 'a'),
          NhentaiTagTerm('tag', 'b'),
        ]),
        [''],
        1);
    expect(requests.last.queryParameters['q'],
        'tag:"a" tag:"b" language:japanese');
    await nhentai.categoryComicsData!.load(
        'combo',
        nhentaiStackParam(const [
          NhentaiTagTerm('language', 'english'),
          NhentaiTagTerm('tag', 'b'),
        ]),
        [''],
        1);
    expect(requests.last.queryParameters['q'], 'language:english tag:"b"');
  });

  test('non-namespace category keeps its route even with defaults', () async {
    await setDefaults();
    await nhentai.categoryComicsData!.load('x', '/search/x', [''], 1);
    expect(requests.single.path, '/search/x/');
  });

  test('recent category keeps its route without defaults', () async {
    await nhentai.categoryComicsData!
        .load('full-color', '/tag/full-color', [''], 3);
    expect(requests.single.path, '/tag/full-color/');
  });

  test('global language filter keeps history and adds defaults', () async {
    await setDefaults();
    appdata.settings[69] = '1';
    await nhentai.categoryComicsData!
        .load('glasses', '/tag/glasses', ['&sort=popular-week'], 1);
    expect(requests.single.queryParameters, {
      'q': 'tag:glasses language:chinese -tag:"yaoi" -tag:"guro"',
      'page': '1',
      'sort': 'popular-week',
    });
    expect(appdata.searchHistory.last, 'tag:glasses language:chinese');
  });

  test('autocomplete sends one request without type and parses results',
      () async {
    final bodies = <Object?>[];
    network.dio.close();
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options.uri);
        bodies.add(options.data);
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: [
            {'type': 'parody', 'name': 'touhou project', 'count': 23493},
            {'type': 'artist', 'name': 'to', 'count': 6},
          ],
        ));
      }));
    final res = await network.autocompleteTags('to');
    expect(requests.single.path, '/api/v2/tags/autocomplete');
    expect(bodies.single, {'query': 'to', 'limit': 20});
    expect(res.data.map((e) => '${e.type}:${e.name}'),
        ['parody:touhou project', 'artist:to']);
  });

  test('autocomplete failure is reported as an error', () async {
    network.dio.close();
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 429),
        ));
      }));
    final res = await network.autocompleteTags('to');
    expect(res.error, isTrue);
  });
}
