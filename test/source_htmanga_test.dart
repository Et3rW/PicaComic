import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';

import 'support/fake_http.dart';

// Fixtures are pages saved from www.wnacg.com (see doc/source-tests.md).
void main() {
  final http = useFakeHttp();
  final network = HtmangaNetwork();

  test('home page sections', () async {
    http.file(RegExp(r'^https://www\.wnacg\.com/?$'), 'htmanga/home.html');
    final res = await network.getHomePage();
    expect(res.errorMessage, isNull);
    final home = res.data;
    expect(home.links, hasLength(5));
    expect(home.links.values.first, startsWith('https://www.wnacg.com/albums'));
    expect(home.comics, hasLength(5));
    for (final section in home.comics) {
      expect(section, hasLength(2));
    }
    final first = home.comics.first.first;
    expect(first.name, '样本标题1');
    expect(first.id, '404929');
    expect(first.pages, 44);
    expect(first.time, '2026-11-16');
    expect(first.image,
        'https://t4.qy0.ru/data/t/4049/29/17947585252412827.jpg');
  });

  group('gallery list', () {
    test('page 2 of a category', () async {
      http.file('albums-index-page-2-cate-5.html', 'htmanga/list.html');
      final res = await network.getComicList(
          'https://www.wnacg.com/albums-index-cate-5.html', 2);
      expect(res.errorMessage, isNull);
      expect(http.urls.last,
          'https://www.wnacg.com/albums-index-page-2-cate-5.html');
      expect(res.subData, 15242);
      expect(res.data, hasLength(3));
      final first = res.data.first;
      expect(first.name, '样本标题1');
      expect(first.id, '404929');
      expect(first.pages, 44);
      expect(first.time, '創建於2026-11-16');
      expect(first.image,
          'https://t4.qy0.ru/data/t/4049/29/17947585252412827.jpg');
    });

    test('page 2 of the unfiltered list and of a ranking', () async {
      http.file('albums-index-page-2.html', 'htmanga/list.html');
      await network.getComicList('https://www.wnacg.com/albums.html', 2);
      expect(http.urls.last, 'https://www.wnacg.com/albums-index-page-2.html');

      http.file('albums-favorite_ranking-page-3-type-day', 'htmanga/list.html');
      await network.getComicList(
          'https://www.wnacg.com/albums-favorite_ranking-type-day.html', 3);
      expect(http.urls.last,
          'https://www.wnacg.com/albums-favorite_ranking-page-3-type-day.html');
    });
  });

  group('search', () {
    late List<String> history;
    setUp(() => history = List.of(appdata.searchHistory));
    tearDown(() => appdata.searchHistory = history);

    test('results and request', () async {
      http.file('/search/', 'htmanga/search.html');
      final res = await network.search('touhou project', 2);
      expect(res.errorMessage, isNull);
      expect(http.urls.last,
          'https://www.wnacg.com/search/?q=touhou%20project&f=_all&s=create_time_DESC&syn=yes&p=2');
      expect(res.data, hasLength(3));
      expect(res.data.first.name, '样本标题1');
      expect(res.data.first.id, '404844');
      expect(res.data.first.pages, 22);
      // The date and the time of day used to be glued together.
      expect(res.data.first.time, '創建於2026-11-15 16:52:32');
      // 8,887 results, three per page in this trimmed fixture.
      expect(res.subData, 8887 ~/ 3 + 1);
    });
  });

  test('gallery details', () async {
    http.file('photos-index-page-1-aid-404929', 'htmanga/info.html');
    final res = await network.getComicInfo('404929');
    expect(res.errorMessage, isNull);
    final info = res.data;
    expect(info.id, '404929');
    expect(info.name, '样本标题');
    expect(info.category, '同人誌／漢化');
    expect(info.pages, 44);
    expect(info.coverPath,
        'https://t4.qy0.ru/data/t/4049/29/17947585252412827.jpg');
    expect(info.tags.keys, ['标签1', '标签2', '标签3', '标签4', '标签5', '标签6', '标签7', '标签8']);
    expect(info.tags['标签1'], '/albums-index-tag-标签1.html');
    // The site now puts an empty paragraph in front of the description.
    expect(info.description, '簡介：样本简介');
    expect(info.uploader, 'uploader1');
    expect(info.avatar, startsWith('https://www.wnacg.com/'));
    expect(info.uploadNum, 252);
    expect(info.thumbnails, hasLength(3));
    expect(info.thumbnails.first,
        'https://t4.qy0.ru/data/t/4049/29/17947585252412827.jpg');
  });

  test('image list keeps the verify token', () async {
    http.file('photos-gallery-aid-404929', 'htmanga/gallery.js');
    final res = await network.getImages('404929');
    expect(res.data, [
      'https://img5.qy0.ru/data/4049/29/01.jpg?verify=1794744000-y5FxH-151CyuYKVrlF6seBfxBJIoxZwAKS1D6B2IaEo',
      'https://img5.qy0.ru/data/4049/29/02.jpg?verify=1794744000-Z2VuUa8sl6OasohWlk8gH3jAo4vdJFsrSOAS-zQAylw',
      'https://img5.qy0.ru/data/4049/29/03.jpg?verify=1794744000-YKIKlHkHETnq-TT36BM6faqOUPMQH7tOpht4JpMOLAQ',
    ]);
  });

  test('image list in the older script form', () {
    expect(
      HtmangaNetwork.parseImageList(
          'var imglist = [{url: "//img.example/data/1/01.jpg"},'
          '{url: "//img.example/data/1/[02](a).png"}];'),
      [
        'https://img.example/data/1/01.jpg',
        'https://img.example/data/1/[02](a).png',
      ],
    );
    expect(HtmangaNetwork.parseImageList('//img.example/a/01.jpg //img.example/a/02.jpg'),
        ['https://img.example/a/01.jpg', 'https://img.example/a/02.jpg']);
  });
}
