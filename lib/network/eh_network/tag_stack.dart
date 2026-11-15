/// Tag stacking for e-hentai: tapping a tag on a gallery opened from a tag
/// search searches that search's tags plus the new one, e.g.
/// `language:chinese` + `female:glasses`.
library;

/// Most tags in one stack, the same as for nhentai.
const ehTagStackLimit = 5;

/// One `namespace:value` term of an e-hentai search.
class EhTagTerm {
  const EhTagTerm(this.namespace, this.value,
      {this.exact = false, this.exclude = false});

  final String namespace;

  final String value;

  /// Written with a trailing `$`: match the whole tag, not a prefix.
  final bool exact;

  final bool exclude;

  bool sameTarget(EhTagTerm other) =>
      namespace == other.namespace &&
      value.toLowerCase() == other.value.toLowerCase();

  String toKeyword() {
    var text = '$value${exact ? r'$' : ''}';
    if (text.contains(' ')) text = '"$text"';
    return '${exclude ? '-' : ''}$namespace:$text';
  }

  @override
  String toString() => toKeyword();
}

final _term = RegExp(r'^(-)?([a-z]+):(?:"([^"]+)"|([^\s"]+))$');

/// Values of the `language` namespace that are not a language.
const _languageFlags = {'translated', 'rewrite', 'speechless', 'text cleaned'};

/// A gallery has one language, so stacking two languages always gives no
/// results; a new language replaces the old one instead.
bool isEhLanguage(EhTagTerm term) =>
    term.namespace == 'language' &&
    !_languageFlags.contains(term.value.trim().toLowerCase());

List<String> _split(String keyword) {
  var tokens = <String>[];
  var buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < keyword.length; i++) {
    var char = keyword[i];
    if (char == '"') quoted = !quoted;
    if (char.trim().isEmpty && !quoted) {
      if (buffer.isNotEmpty) tokens.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  return tokens;
}

/// The tags of a search made only of tags, or null when the keyword is empty
/// or contains anything else (free text, a quoted title).
List<EhTagTerm>? ehTermsFromKeyword(String keyword) {
  var terms = <EhTagTerm>[];
  for (var token in _split(keyword.trim())) {
    var match = _term.firstMatch(token);
    if (match == null) return null;
    var value = (match[3] ?? match[4]!).trim();
    var exact = false;
    // `"big breasts | 巨乳"` from the suggestions: the first name is the tag.
    if (value.contains(' | ')) {
      value = value.split(' | ').first.trim();
      exact = true;
    }
    if (value.endsWith(r'$')) {
      value = value.substring(0, value.length - 1).trim();
      exact = true;
    }
    if (value.isEmpty) return null;
    terms.add(EhTagTerm(match[2]!, value,
        exact: exact, exclude: match[1] != null));
  }
  return terms.isEmpty ? null : terms;
}

String ehKeywordFromTerms(List<EhTagTerm> terms) =>
    terms.map((term) => term.toKeyword()).join(' ');

enum EhStackOutcome { added, duplicate, limit }

class EhStackResult {
  const EhStackResult(this.outcome, this.terms);

  final EhStackOutcome outcome;

  /// The new stack, or the unchanged one when nothing was added.
  final List<EhTagTerm> terms;
}

EhStackResult ehStackAdd(
  List<EhTagTerm> base,
  EhTagTerm term, {
  int limit = ehTagStackLimit,
}) {
  if (base.any((t) => t.sameTarget(term))) {
    return EhStackResult(EhStackOutcome.duplicate, base);
  }
  var next = [
    for (var t in base)
      if (!(isEhLanguage(term) && isEhLanguage(t))) t,
    term,
  ];
  if (next.length > limit) {
    return EhStackResult(EhStackOutcome.limit, base);
  }
  return EhStackResult(EhStackOutcome.added, next);
}
