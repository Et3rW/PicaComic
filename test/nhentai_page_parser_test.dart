import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/network/nhentai_network/page_parser.dart';

String fetched(String id, bool favorite) =>
    '<script data-sveltekit-fetched data-url="/api/v2/galleries/$id">'
    '${jsonEncode({
      'body': jsonEncode({'is_favorited': favorite, 'title': '<sample>'}),
    })}'
    '</script>';

void main() {
  test('missing button is not a favorite', () {
    expect(nhentaiFavoriteState(parse('<main></main>'), '42'), isFalse);
  });
  test('API false takes precedence over stale button text', () {
    expect(
      nhentaiFavoriteState(
        parse(
          '${fetched('42', false)}'
          '<button id="favorite"><span class="text">Unfavorite</span></button>',
        ),
        '42',
      ),
      isFalse,
    );
  });
  test('API true and literal HTML in JSON are preserved', () {
    final document = parse(fetched('42', true));
    expect(nhentaiFavoriteState(document, '42'), isTrue);
    expect(
      nhentaiFetchedPayload(document.querySelector('script')!)['title'],
      '<sample>',
    );
  });
  test('another gallery does not determine this gallery favorite', () {
    expect(nhentaiFavoriteState(parse(fetched('99', true)), '42'), isFalse);
  });
  test('legacy button uses explicit positive state', () {
    for (final label in ['Favorite', '', 'Loading']) {
      expect(
        nhentaiFavoriteState(
          parse('<button id="favorite">$label</button>'),
          '42',
        ),
        isFalse,
      );
    }
    expect(
      nhentaiFavoriteState(
        parse('<button id="favorite"> Unfavorite </button>'),
        '42',
      ),
      isTrue,
    );
  });
}
