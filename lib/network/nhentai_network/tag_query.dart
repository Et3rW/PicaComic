/// nhentai search query model used by the multi-tag search.
///
/// nhentai's `/search?q=` already supports combining terms in one request:
/// every term must match (AND), `-` excludes a term, and `pages:` /
/// `uploaded:` / `favorites:` filter by numbers. Verified against the live
/// site on 2026-11-06, e.g. `tag:"big breasts" -tag:"glasses"` returns the
/// `tag:"big breasts"` count minus the `glasses` overlap.
///
/// The term/namespace split and the numeric filters follow the idea of
/// NhentaiFilterTerm / buildNhentaiCategoryQueryFromParam written by fengye39
/// for ccbkv/PicaComic; this is a separate implementation that also supports
/// exclusion and parsing a query back into terms.
library;

/// Namespaces nhentai accepts in a search query.
const nhentaiTagNamespaces = <String>[
  'tag',
  'artist',
  'parody',
  'character',
  'group',
  'language',
  'category',
];

/// Gallery tag field names on the nhentai detail page, mapped to namespaces.
String? nhentaiNamespaceOfField(String field) {
  return switch (field) {
    'Tags' || 'Tag' => 'tag',
    'Artists' || 'Artist' => 'artist',
    'Parodies' || 'Parody' => 'parody',
    'Characters' || 'Character' => 'character',
    'Groups' || 'Group' => 'group',
    'Languages' || 'Language' => 'language',
    'Categories' || 'Category' => 'category',
    _ => null,
  };
}

/// One entry returned by the nhentai tag autocomplete API.
class NhentaiTagSuggestion {
  const NhentaiTagSuggestion(this.type, this.name, [this.count = 0]);

  final String type;

  final String name;

  final int count;

  NhentaiTagTerm toTerm({bool exclude = false}) =>
      NhentaiTagTerm(type, name, exclude: exclude);
}

List<NhentaiTagSuggestion> parseNhentaiTagSuggestions(Object? data) {
  if (data is Map && data['result'] is List) data = data['result'];
  if (data is! List) return const [];
  var result = <NhentaiTagSuggestion>[];
  for (var item in data) {
    if (item is! Map) continue;
    var type = item['type']?.toString().trim() ?? '';
    var name = item['name']?.toString().trim() ?? '';
    if (!nhentaiTagNamespaces.contains(type) || name.isEmpty) continue;
    var count = item['count'];
    result.add(NhentaiTagSuggestion(
        type, name, count is int ? count : int.tryParse('$count') ?? 0));
  }
  return result;
}

String _normalizeValue(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

String _escape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

class NhentaiTagTerm {
  const NhentaiTagTerm(this.namespace, this.value, {this.exclude = false});

  final String namespace;

  final String value;

  final bool exclude;

  /// Two terms with the same target refer to the same tag, regardless of
  /// whether they include or exclude it.
  String get target => '$namespace:${_normalizeValue(value)}';

  bool sameTarget(NhentaiTagTerm other) => target == other.target;

  NhentaiTagTerm copyWith({bool? exclude}) =>
      NhentaiTagTerm(namespace, value, exclude: exclude ?? this.exclude);

  NhentaiTagTerm toggled() => copyWith(exclude: !exclude);

  String toQuery() {
    var v = _normalizeValue(value);
    // Keep `language:chinese` unquoted: other parts of the app look for
    // `language:\w+` to detect or replace the language filter.
    var body = namespace == 'language' && RegExp(r'^\w+$').hasMatch(v)
        ? 'language:$v'
        : '$namespace:"${_escape(v)}"';
    return exclude ? '-$body' : body;
  }

  Map<String, dynamic> toJson() => {
        'namespace': namespace,
        'value': value,
        if (exclude) 'exclude': true,
      };

  @override
  bool operator ==(Object other) =>
      other is NhentaiTagTerm &&
      other.target == target &&
      other.exclude == exclude;

  @override
  int get hashCode => Object.hash(target, exclude);

  @override
  String toString() => toQuery();
}

enum NhentaiNumericField { pages, uploaded, favorites }

class NhentaiNumericFilter {
  const NhentaiNumericFilter(this.field, this.comparison, this.value,
      [this.unit = '']);

  final NhentaiNumericField field;

  /// One of `>`, `>=`, `<`, `<=`, `=` or empty (exact).
  final String comparison;

  final int value;

  /// Only used by [NhentaiNumericField.uploaded]: h, d, w, m or y.
  final String unit;

  String toQuery() => '${field.name}:$comparison$value$unit';

  @override
  bool operator ==(Object other) =>
      other is NhentaiNumericFilter &&
      other.field == field &&
      other.comparison == comparison &&
      other.value == value &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(field, comparison, value, unit);

  @override
  String toString() => toQuery();
}

class NhentaiTagQuery {
  const NhentaiTagQuery({
    this.terms = const [],
    this.filters = const [],
    this.text = '',
  });

  static const empty = NhentaiTagQuery();

  final List<NhentaiTagTerm> terms;

  final List<NhentaiNumericFilter> filters;

  /// Words that are not a namespaced term or numeric filter, kept verbatim.
  final String text;

  bool get isEmpty => terms.isEmpty && filters.isEmpty && text.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  List<NhentaiTagTerm> get includes =>
      terms.where((t) => !t.exclude).toList(growable: false);

  List<NhentaiTagTerm> get excludes =>
      terms.where((t) => t.exclude).toList(growable: false);

  NhentaiTagTerm? find(NhentaiTagTerm term) {
    for (var t in terms) {
      if (t.sameTarget(term)) return t;
    }
    return null;
  }

  /// Adds [term], replacing any term with the same target in place.
  NhentaiTagQuery add(NhentaiTagTerm term) {
    var index = terms.indexWhere((t) => t.sameTarget(term));
    var next = List<NhentaiTagTerm>.from(terms);
    if (index == -1) {
      next.add(term);
    } else {
      next[index] = term;
    }
    return copyWith(terms: next);
  }

  NhentaiTagQuery remove(NhentaiTagTerm term) =>
      copyWith(terms: terms.where((t) => !t.sameTarget(term)).toList());

  NhentaiTagQuery toggle(NhentaiTagTerm term) {
    var current = find(term);
    return current == null ? add(term) : add(current.toggled());
  }

  /// Sets the filter for [field] (and [comparison] family), or removes it
  /// when [filter] is null.
  NhentaiTagQuery setFilter(NhentaiNumericField field, String comparison,
      NhentaiNumericFilter? filter) {
    bool sameSlot(NhentaiNumericFilter f) =>
        f.field == field && _comparisonSide(f.comparison) == _comparisonSide(comparison);
    var next = filters.where((f) => !sameSlot(f)).toList();
    if (filter != null) next.add(filter);
    return copyWith(filters: next);
  }

  NhentaiNumericFilter? filterOf(NhentaiNumericField field, String comparison) {
    for (var f in filters) {
      if (f.field == field &&
          _comparisonSide(f.comparison) == _comparisonSide(comparison)) {
        return f;
      }
    }
    return null;
  }

  static int _comparisonSide(String comparison) => switch (comparison) {
        '>' || '>=' => 1,
        '<' || '<=' => -1,
        _ => 0,
      };

  /// Terms of [other] whose target is not mentioned in this query.
  List<NhentaiTagTerm> missingTermsFrom(NhentaiTagQuery other) => other.terms
      .where((t) => find(t) == null)
      .toList(growable: false);

  NhentaiTagQuery copyWith({
    List<NhentaiTagTerm>? terms,
    List<NhentaiNumericFilter>? filters,
    String? text,
  }) {
    return NhentaiTagQuery(
      terms: terms ?? this.terms,
      filters: filters ?? this.filters,
      text: text ?? this.text,
    );
  }

  String toQuery() {
    return [
      if (text.trim().isNotEmpty) text.trim(),
      for (var t in terms) t.toQuery(),
      for (var f in filters) f.toQuery(),
    ].join(' ');
  }

  @override
  String toString() => toQuery();

  static final _termPattern = RegExp(r'^(-?)([a-z]+):(.+)$', dotAll: true);

  static final _numericPattern = RegExp(r'^(>=|<=|>|<|=)?(\d+)([hdwmy])?$');

  /// Parses an nhentai search query. Anything that is not a recognised
  /// namespaced term or numeric filter is kept in [text].
  static NhentaiTagQuery parse(String query) {
    var terms = <NhentaiTagTerm>[];
    var filters = <NhentaiNumericFilter>[];
    var text = <String>[];
    for (var token in _tokenize(query)) {
      var match = _termPattern.firstMatch(token);
      if (match == null) {
        text.add(token);
        continue;
      }
      var exclude = match.group(1) == '-';
      var namespace = match.group(2)!;
      var rawValue = match.group(3)!;
      var value = _unquote(rawValue);
      if (nhentaiTagNamespaces.contains(namespace)) {
        if (value.trim().isEmpty) {
          text.add(token);
          continue;
        }
        var term = NhentaiTagTerm(namespace, value, exclude: exclude);
        var index = terms.indexWhere((t) => t.sameTarget(term));
        if (index == -1) {
          terms.add(term);
        } else {
          terms[index] = term;
        }
        continue;
      }
      var field = NhentaiNumericField.values
          .where((f) => f.name == namespace)
          .firstOrNull;
      var numeric = _numericPattern.firstMatch(value);
      if (field != null && !exclude && numeric != null) {
        var unit = numeric.group(3) ?? '';
        if (unit.isNotEmpty && field != NhentaiNumericField.uploaded) {
          text.add(token);
          continue;
        }
        filters.add(NhentaiNumericFilter(
          field,
          numeric.group(1) ?? '',
          int.parse(numeric.group(2)!),
          unit,
        ));
        continue;
      }
      text.add(token);
    }
    return NhentaiTagQuery(terms: terms, filters: filters, text: text.join(' '));
  }

  /// Splits on whitespace outside double quotes. Backslash escapes the next
  /// character inside quotes.
  static List<String> _tokenize(String query) {
    var tokens = <String>[];
    var buffer = StringBuffer();
    var inQuote = false;
    for (var i = 0; i < query.length; i++) {
      var c = query[i];
      if (inQuote && c == '\\' && i + 1 < query.length) {
        buffer
          ..write(c)
          ..write(query[++i]);
        continue;
      }
      if (c == '"') {
        inQuote = !inQuote;
        buffer.write(c);
        continue;
      }
      if (!inQuote && c.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }
      buffer.write(c);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  static String _unquote(String raw) {
    if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
      var inner = raw.substring(1, raw.length - 1);
      var out = StringBuffer();
      for (var i = 0; i < inner.length; i++) {
        if (inner[i] == '\\' && i + 1 < inner.length) {
          out.write(inner[++i]);
        } else {
          out.write(inner[i]);
        }
      }
      return out.toString();
    }
    // Unquoted values use hyphens for spaces in nhentai slugs (tag:big-breasts)
    // but real tags can contain hyphens too (x-ray), so keep them as typed.
    return raw;
  }
}
