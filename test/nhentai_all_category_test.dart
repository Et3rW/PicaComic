// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The "all" category picks no tag and no language: the newest galleries come
// from the home page, other orders and the user's excluded tags need search.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<Uri> requests;
  late String language;
  late Map<String, dynamic> sourceData;
  late Duration retryDelay;
  // Answers for search requests, in turn; the last one repeats.
  late List<String> searchAnswers;

  String gallery(int id) => '<div class="gallery" data-tags="20905">'
      '<a href="/g/$id/"><img src="https://example.com/a.jpg"></a>'
      '<div class="caption">Gallery $id</div></div>';
  const pagination = '<section class="pagination"><a class="last" '
      'href="/?page=900">Last</a></section>';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    requests = [];
    searchAnswers = ['<div>${gallery(7)}</div>$pagination'];
    language = appdata.settings[69];
    // A language set for searches does not apply here.
    appdata.settings[69] = '1';
    sourceData = {};
    NhentaiTagSettings.dataProvider = () => sourceData;
    NhentaiTagSettings.saver = () async {};
    retryDelay = NhentaiNetwork.retryDelay;
    NhentaiNetwork.retryDelay = Duration.zero;
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options.uri);
        String body;
        if (options.uri.path == '/') {
          // The first page shows popular galleries above the newest.
          body = '<div class="container index-container index-popular">'
              '${gallery(1)}</div>'
              '<div class="container index-container">${gallery(2)}${gallery(3)}</div>'
              '$pagination';
        } else {
          body = searchAnswers.length > 1
              ? searchAnswers.removeAt(0)
              : searchAnswers.first;
        }
        handler.resolve(Response<String>(
            requestOptions: options, statusCode: 200, data: body));
      }));
  });

  tearDown(() {
    network.dio.close();
    network.cookieJar = null;
    cookies.dispose();
    SingleInstanceCookieJar.instance = null;
    appdata.settings[69] = language;
    NhentaiTagSettings.dataProvider = () => ComicSource.find('nhentai')?.data;
    NhentaiNetwork.retryDelay = retryDelay;
  });

  Future<Res<List<BaseComic>>> load(NhentaiSort sort, int page) =>
      nhentai.categoryComicsData!.load('全部', '/all/all', [sort.value], page);

  test('is the first category of nhentai', () {
    var first = nhentai.categoryData!.categories.first;
    expect(first.categories, ['全部']);
    expect(first.categoryParams, ['/all/all']);
  });

  test('the newest are the home page without its popular galleries', () async {
    var res = await load(NhentaiSort.recent, 2);
    expect(res.error, isFalse);
    expect(requests.single.path, '/');
    expect(requests.single.queryParameters, {'page': '2'});
    expect([for (var c in res.data) c.id], ['2', '3']);
    expect(res.subData, 900);
  });

  test('another order searches everything, with no language', () async {
    var res = await load(NhentaiSort.popularWeek, 3);
    expect(res.error, isFalse);
    expect(requests.single.path, '/search/');
    expect(requests.single.queryParameters,
        {'q': ' ', 'page': '3', 'sort': 'popular-week'});
    expect(res.data.single.id, '7');
  });

  test('the tags the user always excludes still are', () async {
    await NhentaiTagSettings.setDefaultExcludes(
        [const NhentaiTagTerm('tag', 'yaoi')]);
    for (var sort in [NhentaiSort.recent, NhentaiSort.popularAll]) {
      requests.clear();
      var res = await load(sort, 1);
      expect(res.error, isFalse);
      expect(requests.single.path, '/search/');
      expect(requests.single.queryParameters['q'], '-tag:"yaoi"');
      expect(res.data.single.id, '7');
    }
  });

  test('an empty answer from search is asked again', () async {
    searchAnswers = [
      '<h2>No results found</h2>',
      '<h2>No results found</h2>',
      '<div>${gallery(8)}</div>$pagination',
    ];
    var res = await load(NhentaiSort.popularToday, 1);
    expect(requests, hasLength(3));
    expect(res.data.single.id, '8');
  });

  test('a search that stays empty gives up after two more tries', () async {
    searchAnswers = ['<h2>No results found</h2>'];
    var res = await load(NhentaiSort.popularToday, 1);
    expect(requests, hasLength(3));
    expect(res.error, isFalse);
    expect(res.data, isEmpty);
  });
}
