import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart';

dynamic nhentaiFetchedPayload(Element script) {
  dynamic wrapper;
  try {
    wrapper = jsonDecode(script.text);
  } on FormatException {
    wrapper = jsonDecode(parseFragment(script.text).text ?? '');
  }
  if (wrapper is! Map || wrapper['body'] is! String) return null;
  return jsonDecode(wrapper['body'] as String);
}

/// Convert a category slug back to a quoted namespace search phrase.
String nhentaiCategoryQuery(String path) {
  final parts =
      Uri.parse(path).pathSegments.where((s) => s.isNotEmpty).toList();
  if (parts.length != 2 ||
      !const {
        'tag',
        'artist',
        'group',
        'parody',
        'character',
        'language',
        'category',
      }.contains(parts.first)) {
    throw const FormatException('Invalid nhentai category path');
  }
  final name = parts.last
      .replaceAll('-', ' ')
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"');
  return '${parts.first}:"$name"';
}

/// Only the page parameter is a page number; queries can contain other digits.
int nhentaiLastPage(Document document, int currentPage) {
  var last = currentPage;
  for (final link in document.querySelectorAll('section.pagination a[href]')) {
    final uri = Uri.tryParse(link.attributes['href']!);
    final page = int.tryParse(uri?.queryParameters['page'] ?? '');
    if (page != null && page > last) last = page;
  }
  return last;
}

/// Index list-page metadata once, without fetching every gallery detail page.
Map<String, Set<String>> nhentaiTagIdsFromFetchedData(Document document) {
  final result = <String, Set<String>>{};
  for (final script
      in document.querySelectorAll('script[data-sveltekit-fetched]')) {
    try {
      final payload = nhentaiFetchedPayload(script);
      final dynamic galleries = payload is List
          ? payload
          : payload is Map && payload['result'] is List
              ? payload['result']
              : payload is Map && payload['id'] != null
                  ? [payload]
                  : null;
      if (galleries is! List) continue;
      for (final gallery in galleries) {
        if (gallery is! Map || gallery['tag_ids'] is! List) continue;
        final id = _numericId(gallery['id']);
        if (id == null) continue;
        final tags = result.putIfAbsent(id, () => <String>{});
        for (final value in gallery['tag_ids'] as List) {
          final tag = _numericId(value);
          if (tag != null) tags.add(tag);
        }
      }
    } catch (_) {
      // A malformed or unrelated block must not hide other galleries' tags.
    }
  }
  return result;
}

String? _numericId(dynamic value) {
  if (value is! int && value is! String) return null;
  final id = value.toString().trim();
  return RegExp(r'^\d+$').hasMatch(id) ? id : null;
}

Set<String> nhentaiCardTagIds(Element card, Iterable<String> fetchedTags) => {
      ...fetchedTags,
      for (final value
          in (card.attributes['data-tags'] ?? '').split(RegExp(r'\s+')))
        if (_numericId(value) case final String id) id,
    };

String nhentaiLanguage(Set<String> tags) {
  if (tags.contains('12227')) return 'English';
  if (tags.contains('6346')) return '日本語';
  if (tags.contains('29963')) return '中文';
  return 'Unknown';
}

bool nhentaiFavoriteState(Document document, String id) {
  for (final script in document.querySelectorAll(
    'script[data-sveltekit-fetched]',
  )) {
    try {
      final path = Uri.tryParse(script.attributes['data-url'] ?? '')?.path;
      if (path != '/api/v2/galleries/$id' && path != '/api/v2/galleries/$id/') {
        continue;
      }
      final payload = nhentaiFetchedPayload(script);
      if (payload is Map && payload['is_favorited'] is bool) {
        return payload['is_favorited'] as bool;
      }
    } catch (_) {
      // Older pages can still expose the state through the button below.
    }
  }
  final button = document.querySelector('button#favorite');
  final pressed = button?.attributes['aria-pressed'];
  if (pressed == 'true' || pressed == 'false') return pressed == 'true';
  final label = (button?.querySelector('span.text')?.text ?? button?.text ?? '')
      .trim()
      .toLowerCase();
  return label == 'unfavorite' ||
      label == 'unfavourite' ||
      label == 'remove from favorites';
}
