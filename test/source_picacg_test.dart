import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';

import 'support/fake_http.dart';

// Hand-written responses, see test/fixtures/picacg/README.md.
void main() {
  final http = useFakeHttp();
  const api = 'https://picaapi.picacomic.com';
  const storage = 'https://storage1.picacomic.com';
  late Object? previousToken;

  setUpAll(() {
    previousToken = picacg.data['token'];
    picacg.data['token'] = 'test-token';
  });
  tearDownAll(() => picacg.data['token'] = previousToken);

  void serve(String path, String name) => http.file('$api/$path', 'picacg/$name');

  test('requests are signed', () async {
    serve('categories', 'categories.json');
    await network.getCategories();
    final headers = http.requests.last.headers;
    expect(headers['authorization'], 'test-token');
    final raw = 'categories${headers['time']}${headers['nonce']}GET${headers['api-key']}'
        .toLowerCase();
    const secret =
        r'~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';
    expect(headers['signature'],
        Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(raw)).toString());
  });

  test('categories', () async {
    serve('categories', 'categories.json');
    final res = await network.getCategories();
    expect(res.errorMessage, isNull);
    // Web links are not categories.
    expect(res.data.map((c) => c.title), ['分類一', '分類二']);
    expect(res.data.map((c) => c.path), [
      '$storage/static/tobeimg/a.jpg',
      '$storage/static/b.jpg',
    ]);
  });

  test('search', () async {
    serve('comics/advanced-search?page=2', 'search.json');
    final res = await network.search('样本', 'dd', 2);
    expect(res.errorMessage, isNull);
    final request = http.requests.last;
    expect(request.method, 'POST');
    expect(request.data, {'keyword': '样本', 'sort': 'dd'});
    expect(res.subData, 3);
    // The entry without a cover is skipped.
    expect(res.data.map((c) => c.id),
        ['5f0000000000000000000001', '5f0000000000000000000002']);
    final first = res.data.first;
    expect(first.title, '样本标题1');
    expect(first.author, '作者1');
    expect(first.likes, 7);
    expect(first.pages, 24);
    expect(first.path, '$storage/static/tobeimg/c1.jpg');
    expect(first.tags, ['标签1', '分類一', '分類二']);
    expect(res.data[1].author, 'Unknown');
    expect(res.data[1].likes, 12);
  });

  test('comic details with chapters from every page', () async {
    serve('comics/5f0000000000000000000001/eps?page=1', 'eps_1.json');
    serve('comics/5f0000000000000000000001/eps?page=2', 'eps_2.json');
    http.text('$api/comics/5f0000000000000000000001/recommendation',
        '{"code":200,"message":"success","data":{"comics":[]}}');
    http.file(RegExp(r'/comics/5f0000000000000000000001$'), 'picacg/comic.json');
    final res = await network.getComicInfo('5f0000000000000000000001');
    expect(res.errorMessage, isNull);
    final comic = res.data;
    expect(comic.id, '5f0000000000000000000001');
    expect(comic.title, '样本标题1');
    expect(comic.description, '样本简介');
    expect(comic.author, '作者1');
    expect(comic.chineseTeam, '汉化组1');
    expect(comic.thumbUrl, '$storage/static/tobeimg/c1.jpg');
    expect(comic.categories, ['分類一', '分類二']);
    expect(comic.tags, ['标签1', '标签2']);
    expect(comic.likes, 7);
    expect(comic.comments, 3);
    expect(comic.isFavourite, isTrue);
    expect(comic.isLiked, isFalse);
    expect(comic.epsCount, 2);
    expect(comic.pagesCount, 24);
    expect(comic.time, '2026-11-01T08:00:00.000Z');
    expect(comic.creator.name, 'uploader1');
    expect(comic.creator.level, 4);
    expect(comic.creator.avatarUrl, '$storage/static/avatar.jpg');
    // The API lists the newest chapter first; the app reads oldest first.
    expect(comic.eps, ['第1話', '第2話', '第3話']);
    expect(comic.recommendation, isEmpty);
  });

  test('chapter images', () async {
    serve('comics/abc/order/1/pages?page=1', 'pages.json');
    final res = await network.getComicContent('abc', 1);
    expect(res.errorMessage, isNull);
    expect(res.data, [
      '$storage/static/tobeimg/01.jpg',
      'https://storage-b.picacomic.com/static/02.jpg',
    ]);
  });

  test('a 400 answer is reported with the server message', () async {
    http.on('$api/comics/gone/order/1/pages', (_) => FakeResponse(
        '{"code":400,"error":"1014","message":"under review","detail":":("}',
        status: 400));
    final res = await network.getComicContent('gone', 1);
    expect(res.error, isTrue);
    expect(res.errorMessage, 'under review');
  });
}
