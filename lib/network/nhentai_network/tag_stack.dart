/// Tag stacking: tapping a tag on a comic opened from a tag page searches
/// the page's tags plus the new one, e.g. `language:chinese` + `glasses`.
library;

import 'tag_query.dart';

/// Most tags in one stack. Results get very thin beyond this, and every tag
/// makes the nhentai search slower.
const nhentaiTagStackLimit = 5;

/// Values of the nhentai `language` namespace that are not a language.
const _languageFlags = {'translated', 'rewrite', 'speechless', 'text cleaned'};

/// A gallery has one language, so stacking two languages always gives no
/// results; a new language replaces the old one instead.
bool isNhentaiLanguage(NhentaiTagTerm term) =>
    term.namespace == 'language' &&
    !_languageFlags.contains(term.value.trim().toLowerCase());

enum NhentaiStackOutcome { added, duplicate, limit }

class NhentaiStackResult {
  const NhentaiStackResult(this.outcome, this.terms);

  final NhentaiStackOutcome outcome;

  /// The new stack, or the unchanged one when nothing was added.
  final List<NhentaiTagTerm> terms;
}

NhentaiStackResult nhentaiStackAdd(
  List<NhentaiTagTerm> base,
  NhentaiTagTerm term, {
  int limit = nhentaiTagStackLimit,
}) {
  if (base.any((t) => t.sameTarget(term))) {
    return NhentaiStackResult(NhentaiStackOutcome.duplicate, base);
  }
  var next = [
    for (var t in base)
      if (!(isNhentaiLanguage(term) && isNhentaiLanguage(t))) t,
    term,
  ];
  if (next.length > limit) {
    return NhentaiStackResult(NhentaiStackOutcome.limit, base);
  }
  return NhentaiStackResult(NhentaiStackOutcome.added, next);
}

/// Category param understood by the nhentai category loader.
///
/// One tag keeps the classic `/namespace/slug` route so it loads exactly like
/// the old category page; several tags use `/combo/<encoded query>`.
String nhentaiStackParam(List<NhentaiTagTerm> terms) {
  if (terms.length == 1) {
    var t = terms.single;
    var slug = t.value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    return '/${t.namespace}/$slug';
  }
  return '/combo/${Uri.encodeComponent(NhentaiTagQuery(terms: terms).toQuery())}';
}

/// Terms of a category param, or null if it is not a tag route.
List<NhentaiTagTerm>? nhentaiTermsFromParam(String? param) {
  if (param == null) return null;
  var parts = param.split('/');
  if (parts.length != 3 || parts[0].isNotEmpty || parts[2].isEmpty) {
    return null;
  }
  if (parts[1] == 'combo') {
    String query;
    try {
      query = Uri.decodeComponent(parts[2]);
    } on ArgumentError {
      return null;
    }
    var terms = NhentaiTagQuery.parse(query).terms;
    return terms.isEmpty ? null : terms;
  }
  if (!nhentaiTagNamespaces.contains(parts[1])) return null;
  return [NhentaiTagTerm(parts[1], parts[2].replaceAll('-', ' '))];
}
