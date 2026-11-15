import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/hitomi_network/image.dart';

import 'support/fake_http.dart';

// Fixtures are responses saved from ltn.gold-usergeneratedcontent.net
// (see doc/source-tests.md).
void main() {
  final http = useFakeHttp();
  final network = HiNetwork();
  const domain = 'gold-usergeneratedcontent.net';
  const hash =
      '22cefb5a6b2362452903f15ad7e7c593955d7edf87559541a209a1f9c29ede62';

  setUpAll(() {
    http.file('galleryblock/4331776.html', 'hitomi/galleryblock.html');
    http.file('galleries/4331776.js', 'hitomi/gallery.js');
    http.file('/gg.js', 'hitomi/gg.js');
  });

  test('gallery block', () async {
    final res = await network.getComicInfoBrief('4331776');
    expect(res.errorMessage, isNull);
    final brief = res.data;
    expect(brief.name, 'Sample Gallery');
    expect(brief.type.trim(), 'image set');
    expect(brief.lang.trim(), '日本語');
    expect(brief.artist, 'artist1');
    expect(brief.time, '2026-11-15 11:17:00-06');
    expect(brief.link,
        'https://hitomi.la/imageset/sample-gallery-english-4331776.html');
    expect(brief.cover,
        matches('^https://atn\\.$domain/webpbigtn/[0-9a-f]/[0-9a-f]{2}/[0-9a-f]{64}\\.webp\$'));
    // The series comes first, then the tags.
    expect(brief.tagList.first.name, 'series1');
    expect(brief.tagList.first.link, '/series/series1-all.html');
    expect(brief.tagList.map((tag) => tag.name),
        containsAll(['tag1 ♀', 'tag3 ♂']));
    expect(brief.tagList, hasLength(13));
  });

  test('gallery details', () async {
    final res = await network.getComicInfo('4331776');
    expect(res.errorMessage, isNull);
    final comic = res.data;
    expect(comic.id, '4331776');
    expect(comic.name, 'Sample Gallery');
    expect(comic.type, 'imageset');
    expect(comic.lang, 'japanese');
    expect(comic.time, '2026-11-15 11:17:00-06');
    expect(comic.artists, ['artist1']);
    // Missing artists and groups are shown as N/A.
    expect(comic.group, ['N/A']);
    expect(comic.related, [4163085, 2728247]);
    expect(comic.parodys!.single.name, 'parody1');
    expect(comic.parodys!.single.link,
        'https://ltn.$domain/series/parody1-all.html');
    expect(comic.characters!.map((tag) => tag.name),
        ['character1', 'character2', 'character3', 'character4']);
    expect(comic.tags.map((tag) => tag.name),
        ['tag1 ♀', 'tag2 ♀', 'tag3 ♂', 'tag4 ♀']);
    expect(comic.tags.first.link,
        'https://ltn.$domain/tag/female%3Atag1-all.html');
    expect(comic.files, hasLength(3));
    expect(comic.files.first.name, '0001_151616732_p0.png');
    expect(comic.files.first.hash, hash);
    expect(comic.files.first.width, 1306);
    expect(comic.files.first.height, 1148);
    expect(comic.files.first.hasAvif, isTrue);
  });

  test('a link to the gallery page works as the id', () async {
    final res = await network.getComicInfo(
        'https://hitomi.la/imageset/sample-gallery-english-4331776.html');
    expect(res.data.id, '4331776');
  });

  group('image addresses from gg.js', () {
    final file = HitomiFile('0001.png', hash, false, true, 1148, 1306, '4331776');

    setUp(() => GG.cacheTime = null);

    test('full image', () async {
      // The hash ends in "e62": gg.s gives 0x2e6 = 742, which is not one of
      // the listed cases, so the default server (o = 1 -> "w2") is used.
      final url = await GG().urlFromUrlFromHash('4331776', file, 'webp', null);
      expect(url, 'https://w2.$domain/1794762001/742/$hash.webp');
      final request = http.requests.last;
      expect(request.uri.host, 'ltn.$domain');
      expect(request.headers['Referer'], 'https://hitomi.la/reader/4331776.html');
    });

    test('listed cases switch to the other server', () async {
      // 0x6f8 = 1784 is the first case in the fixture.
      final other = HitomiFile('a.png', '${'0' * 61}f86', false, true, 1, 1, '1');
      final url = await GG().urlFromUrlFromHash('1', other, 'webp', null);
      expect(url, startsWith('https://w1.$domain/1794762001/1784/'));
    });

    test('thumbnail', () async {
      final url = await GG()
          .urlFromUrlFromHash('4331776', file, 'webpsmallsmalltn', 'webp');
      expect(url, 'https://btn.$domain/webpsmallsmalltn/2/e6/$hash.webp');
    });
  });

  test('gallery ids are read from the binary index with a range request',
      () async {
    http.on('index-all.nozomi', (request) {
      expect(request.headers['Range'], 'bytes=0-99');
      final ids = ByteData(12)
        ..setInt32(0, 4331781)
        ..setInt32(4, 4331776)
        ..setInt32(8, 77);
      return FakeResponse(ids.buffer.asUint8List(),
          status: 206, headers: {'content-range': 'bytes 0-11/4960920'});
    });
    final res = await network.getComics('https://ltn.$domain/index-all.nozomi');
    expect(res.errorMessage, isNull);
    expect(res.data.comicIds, [4331781, 4331776, 77]);
    expect(res.data.total, 4960920);
    expect(res.data.toLoad, 100);
  });
}
