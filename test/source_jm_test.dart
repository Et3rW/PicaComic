import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pointycastle/export.dart';

import 'support/fake_http.dart';

/// Encrypts [json] the way the JM API does for the request's timestamp, so
/// the tests go through the real token check and decryption.
FakeResponse jmResponse(RequestOptions request, String json) {
  final tokenParam = request.headers['tokenparam'] as String;
  final time = tokenParam.split(',').first;
  expect(request.headers['token'],
      md5.convert(utf8.encode('${time}18comicAPPContent')).toString());
  expect(tokenParam, '$time,${appdata.settings[89]}');

  final key = md5.convert(utf8.encode('$time${JmNetwork.kJmSecret}')).toString();
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
    ..init(true,
        PaddedBlockCipherParameters(KeyParameter(utf8.encode(key)), null));
  final data = base64Encode(cipher.process(Uint8List.fromList(utf8.encode(json))));
  return FakeResponse(jsonEncode({'code': 200, 'data': data}));
}

// Fixtures are decrypted responses saved from the JM API
// (see doc/source-tests.md).
void main() {
  final http = useFakeHttp();
  final network = JmNetwork();

  void serve(String path, String name) =>
      http.on(path, (request) => jmResponse(request, fixture(name)));

  test('home page sections', () async {
    serve('/promote?', 'jm/promote.json');
    final res = await network.getHomePage();
    expect(res.errorMessage, isNull);
    final items = res.data.items;
    expect(items.map((item) => item.id), ['26', '29', '30']);
    expect(items.first.name, '連載更新→右滑看更多→');
    expect(items.first.category, isFalse);
    expect(items.first.comics, hasLength(2));
    final comic = items[1].comics.first;
    expect(comic.id, '1490921');
    expect(comic.name, '样本标题1');
    expect(comic.author, '作者1');
    expect(comic.categories.map((c) => '${c.id}:${c.name}'), ['2:單本', '5:韓漫']);
    // A category without an id is left out.
    expect(items.first.comics.first.categories.map((c) => c.name), ['韓漫']);
  });

  group('search', () {
    late List<String> history;
    setUp(() {
      history = List.of(appdata.searchHistory);
      serve('/search?', 'jm/search.json');
    });
    tearDown(() => appdata.searchHistory = history);

    test('results and page count', () async {
      final res = await network.searchNew('touhou  project', 1, ComicsOrder.latest);
      expect(res.errorMessage, isNull);
      expect(http.urls.last,
          endsWith('/search?&search_query=touhou+project&o=${ComicsOrder.latest}'));
      expect(res.data.map((c) => c.id), ['1490554', '1487665', '1478182']);
      expect(res.data.first.name, '样本标题1');
      expect(res.data.first.tags, ['同人', '同人']);
      // 148 results, three per page in this trimmed fixture.
      expect(res.subData, 50);
    });

    test('later pages add the page number', () async {
      await network.searchNew('touhou', 3, ComicsOrder.latest);
      expect(http.urls.last, endsWith('&o=${ComicsOrder.latest}&page=3'));
    });
  });

  test('album details', () async {
    serve('/album?id=1490554', 'jm/album.json');
    final res = await network.getComicInfo('1490554');
    expect(res.errorMessage, isNull);
    final info = res.data;
    expect(info.id, '1490554');
    expect(info.name, '样本标题');
    expect(info.author, ['作者1']);
    expect(info.likes, 418);
    expect(info.views, 6637);
    expect(info.comments, 3);
    expect(info.tags, ['tags1', 'tags2', 'tags3']);
    expect(info.works, ['works1']);
    expect(info.actors, ['actors1']);
    expect(info.liked, isFalse);
    expect(info.favorite, isFalse);
    expect(info.series, isEmpty);
    expect(info.relatedComics.map((c) => c.id), ['34', '45']);
  });

  test('chapter images', () async {
    serve('/chapter?&id=1490554', 'jm/chapter.json');
    final res = await network.getChapter('1490554');
    expect(res.errorMessage, isNull);
    final base = appdata.settings[86];
    expect(res.data, [
      '$base/media/photos/1490554/00001.webp',
      '$base/media/photos/1490554/00002.webp',
      '$base/media/photos/1490554/00003.webp',
    ]);
  });

  test('an error status is reported with the server message', () async {
    http.on('/album?id=404', (_) => FakeResponse(
        jsonEncode({'code': 401, 'errorMsg': '請先登入會員'}), status: 401));
    final res = await network.getComicInfo('404');
    expect(res.error, isTrue);
    expect(res.errorMessage, '請先登入會員');
  });
}
