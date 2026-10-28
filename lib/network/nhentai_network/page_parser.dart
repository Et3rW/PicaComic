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
