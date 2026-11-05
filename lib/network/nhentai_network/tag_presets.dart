import 'package:flutter/foundation.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';

class NhentaiTagPreset {
  const NhentaiTagPreset(this.name, this.query);

  final String name;

  /// nhentai search query, see [NhentaiTagQuery.toQuery].
  final String query;

  Map<String, dynamic> toJson() => {'name': name, 'query': query};

  static NhentaiTagPreset? fromJson(Object? json) {
    if (json is! Map) return null;
    var name = json['name'];
    var query = json['query'];
    if (name is! String || query is! String || name.trim().isEmpty) {
      return null;
    }
    return NhentaiTagPreset(name.trim(), query);
  }
}

/// Saved tag combinations and default exclusions, stored in the nhentai
/// comic source data file (`comic_source/nhentai.data`).
class NhentaiTagPresets {
  NhentaiTagPresets._();

  static const _presetsKey = 'multiTagPresets';

  static const _defaultExcludesKey = 'multiTagDefaultExcludes';

  /// Overridable for tests.
  @visibleForTesting
  static Map<String, dynamic>? Function() dataProvider =
      () => ComicSource.find('nhentai')?.data;

  /// Overridable for tests.
  @visibleForTesting
  static Future<void> Function() saver =
      () async => await ComicSource.find('nhentai')?.saveData();

  /// Bumped after every change, so widgets can listen.
  static final changes = ValueNotifier<int>(0);

  static List<NhentaiTagPreset> get presets {
    var raw = dataProvider()?[_presetsKey];
    if (raw is! List) return const [];
    return raw
        .map(NhentaiTagPreset.fromJson)
        .whereType<NhentaiTagPreset>()
        .toList(growable: false);
  }

  static Future<void> savePreset(NhentaiTagPreset preset) async {
    var data = dataProvider();
    if (data == null) return;
    var list = presets.where((p) => p.name != preset.name).toList()
      ..add(preset);
    data[_presetsKey] = list.map((p) => p.toJson()).toList();
    await _save();
  }

  static Future<void> removePreset(String name) async {
    var data = dataProvider();
    if (data == null) return;
    data[_presetsKey] = presets
        .where((p) => p.name != name)
        .map((p) => p.toJson())
        .toList();
    await _save();
  }

  /// Exclusions added to every nhentai search, as a query of `-ns:"value"`.
  static NhentaiTagQuery get defaultExcludes {
    var raw = dataProvider()?[_defaultExcludesKey];
    if (raw is! String || raw.trim().isEmpty) return NhentaiTagQuery.empty;
    var parsed = NhentaiTagQuery.parse(raw);
    return NhentaiTagQuery(
        terms: [for (var t in parsed.terms) t.copyWith(exclude: true)]);
  }

  static Future<void> setDefaultExcludes(List<NhentaiTagTerm> terms) async {
    var data = dataProvider();
    if (data == null) return;
    var query = NhentaiTagQuery(
        terms: [for (var t in terms) t.copyWith(exclude: true)]);
    if (query.terms.isEmpty) {
      data.remove(_defaultExcludesKey);
    } else {
      data[_defaultExcludesKey] = query.toQuery();
    }
    await _save();
  }

  /// Appends the default exclusions that [keyword] does not mention.
  ///
  /// A tag the user explicitly includes or excludes in [keyword] wins over
  /// the default, so a default exclusion can be overridden per search.
  static String applyDefaultExcludes(String keyword) {
    var defaults = defaultExcludes;
    if (defaults.terms.isEmpty) return keyword;
    // A bare gallery ID is a lookup, not a tag search.
    if (RegExp(r'^\s*\d+\s*$').hasMatch(keyword)) return keyword;
    var missing = NhentaiTagQuery.parse(keyword).missingTermsFrom(defaults);
    if (missing.isEmpty) return keyword;
    return [
      if (keyword.trim().isNotEmpty) keyword.trim(),
      for (var t in missing) t.toQuery(),
    ].join(' ');
  }

  static Future<void> _save() async {
    await saver();
    changes.value++;
  }
}

/// The combination being built across pages (detail page long-press menu,
/// search page, result page). Kept in memory only.
class NhentaiTagDraft {
  NhentaiTagDraft._();

  static final notifier = ValueNotifier<NhentaiTagQuery>(NhentaiTagQuery.empty);

  static NhentaiTagQuery get value => notifier.value;

  static set value(NhentaiTagQuery query) => notifier.value = query;

  static void add(NhentaiTagTerm term) => value = value.add(term);

  static void clear() => value = NhentaiTagQuery.empty;
}
