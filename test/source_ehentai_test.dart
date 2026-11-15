import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';

import 'support/fake_http.dart';

// Fixtures are pages saved from e-hentai.org (see doc/source-tests.md).
void main() {
  final http = useFakeHttp();
  const galleryLink = 'https://e-hentai.org/g/4331550/a41fff6a79/';

  Future<List<EhGalleryBrief>> list(String mode) async {
    http.file('e-hentai.org/?mode=$mode', 'eh/list_$mode.html');
    final res =
        await EhNetwork().getGalleries('https://e-hentai.org/?mode=$mode');
    expect(res.errorMessage, isNull);
    expect(res.data.next, 'https://e-hentai.org/?f_cats=767&next=4329782');
    return res.data.galleries;
  }

  void expectFirst(EhGalleryBrief g) {
    expect(g.title, 'Sample Gallery 1');
    expect(g.type, 'Non-H');
    expect(g.time, '2026-11-15 15:03');
    expect(g.coverPath, 'https://ehgt.org/w/02/801/87793-l10d8xe5.webp');
    expect(g.stars, 1.5);
    expect(g.link, galleryLink);
  }

  group('gallery list', () {
    test('compact mode', () async {
      final galleries = await list('compact');
      expect(galleries, hasLength(3));
      expectFirst(galleries.first);
      expect(galleries.first.uploader, 'uploader1');
      expect(galleries.first.pages, 26);
      expect(galleries.first.tags, [
        'language:chinese',
        'language:translated',
        'parody:pokemon',
        'character:pikachu',
        'character:totodile',
      ]);
      expect(galleries[2].pages, 577);
      expect(galleries[2].stars, 4.5);
    });

    test('minimal mode', () async {
      final galleries = await list('minimal');
      expect(galleries, hasLength(3));
      expectFirst(galleries.first);
      expect(galleries.first.uploader, 'uploader1');
    });

    test('extended mode', () async {
      final galleries = await list('extended');
      expect(galleries, hasLength(3));
      expectFirst(galleries.first);
      expect(galleries.first.uploader, 'uploader1');
      expect(galleries.first.pages, 26);
      expect(galleries.first.tags, contains('character:pikachu'));
    });

    test('thumbnail mode', () async {
      final galleries = await list('thumbnail');
      expect(galleries, hasLength(3));
      expectFirst(galleries.first);
      expect(galleries.first.pages, 26);
    });

    test('a temporary IP ban is reported instead of an empty list', () async {
      http.text('e-hentai.org/?banned',
          'Your IP address has been temporarily banned for excessive pageloads.');
      final res = await EhNetwork().getGalleries('https://e-hentai.org/?banned');
      expect(res.error, isTrue);
      expect(res.errorMessage, contains('temporarily banned'));
    });
  });

  group('gallery page', () {
    setUp(() => http.file('/g/4331550/a41fff6a79/', 'eh/gallery.html'));

    test('details', () async {
      final res = await EhNetwork().getGalleryInfo(galleryLink);
      expect(res.errorMessage, isNull);
      final g = res.data;
      expect(g.title, 'Sample Gallery');
      expect(g.subTitle, 'サンプル');
      expect(g.type, 'Non-H');
      expect(g.time, '2026-11-15 15:03');
      expect(g.uploader, 'uploader1');
      expect(g.stars, 1.5);
      expect(g.rating, 'Average: 1.50');
      expect(g.coverPath, 'https://ehgt.org/w/02/801/87793-l10d8xe5.webp');
      expect(g.tags, {
        'language': ['chinese', 'translated'],
        'parody': ['pokemon'],
        'character': ['pikachu', 'totodile'],
      });
      expect(g.favorite, isFalse);
      expect(g.maxPage, '26');
      expect(g.pageSize, 20);
      expect(g.ext, 'webp');
      expect(g.link, galleryLink);
    });

    test('values the reader and the API need', () async {
      final auth = (await EhNetwork().getGalleryInfo(galleryLink)).data.auth!;
      expect(auth['gid'], '4331550');
      expect(auth['token'], 'a41fff6a79');
      expect(auth['apikey'], '0123456789abcdef0123');
      expect(auth['api_url'], 'https://api.e-hentai.org/api.php');
      // Sprite sheet of the first thumbnails, then the number of sheets.
      expect(auth['thumbnailKey'], matches(r'^https://\S+/4331550-0\.webp 2$'));
      expect(auth['archiveDownload'],
          'https://e-hentai.org/archiver.php?gid=4331550&token=a41fff6a79');
    });

    test('comments', () async {
      final comments =
          (await EhNetwork().getGalleryInfo(galleryLink)).data.comments;
      expect(comments, hasLength(1));
      expect(comments.single.name, 'commenter1');
      expect(comments.single.content, 'Sample comment 1');
      expect(comments.single.time, '15 November 2026, 15:03');
      expect(comments.single.score, 0);
      expect(comments.single.voteUP, isNull);
    });

    test('reader links', () async {
      final first = await EhNetwork().getReaderLink(galleryLink, 1);
      expect(first.data, 'https://e-hentai.org/s/c301571671/4331550-1');
      final second = await EhNetwork().getReaderLink(galleryLink, 2);
      expect(second.data, 'https://e-hentai.org/s/5ea288ff22/4331550-2');
    });

    test('content warning page is reported as such', () async {
      http.text('/g/1/warn/',
          '<html><body><h1>Content Warning</h1><a>Never Warn Me Again</a></body></html>');
      final res = await EhNetwork().getGalleryInfo('https://e-hentai.org/g/1/warn/');
      expect(res.errorMessage, 'Content Warning');
    });
  });

  test('reader page gives the image and the reload key', () async {
    http.file('/s/c301571671/4331550-1', 'eh/reader.html');
    final (image, nl) = await EhNetwork()
        .getImageLinkWithNL('4331550', 'c301571671', 1, '25920-498545');
    expect(image, matches(r'^https://\S+\.hath\.network/h/\S+/1\.webp$'));
    expect(nl, '25920-498545');
    expect(http.urls.last,
        'https://e-hentai.org/s/c301571671/4331550-1?nl=25920-498545');
  });

  group('search', () {
    late List<String> history;
    setUp(() {
      history = List.of(appdata.searchHistory);
      http.file('f_search=', 'eh/list_compact.html');
    });
    tearDown(() => appdata.searchHistory = history);

    test('keyword and filters go into the request', () async {
      final res = await EhNetwork().search(r'language:chinese$  "female:glasses$"',
          fCats: 767, startPages: 10, endPages: 200, minStars: 4);
      expect(res.data.galleries, hasLength(3));
      final uri = Uri.parse(http.urls.last);
      expect(uri.queryParameters, {
        'f_search': r'language:chinese$ "female:glasses$"',
        'f_cats': '767',
        'f_spf': '10',
        'f_spt': '200',
        'f_srdd': '4',
      });
      expect(appdata.searchHistory.last, r'language:chinese$  "female:glasses$"');
    });

    test('translated tag alternatives are reduced to the original tag',
        () async {
      await EhNetwork().search('female:"big breasts | 巨乳" touhou');
      expect(Uri.parse(http.urls.last).queryParameters['f_search'],
          r'female:"big breasts$" touhou');
    });
  });
}
