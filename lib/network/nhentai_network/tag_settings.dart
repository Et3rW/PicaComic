import 'package:flutter/foundation.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';

/// nhentai tag settings, stored in the nhentai comic source data file
/// (`comic_source/nhentai.data`).
class NhentaiTagSettings {
  NhentaiTagSettings._();

  static const _stackEnabledKey = 'tagStackEnabled';

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

  /// Whether tapping a tag stacks it onto the tag page the comic was opened
  /// from. On by default.
  static bool get stackEnabled => dataProvider()?[_stackEnabledKey] != false;

  static Future<void> setStackEnabled(bool value) async {
    var data = dataProvider();
    if (data == null) return;
    data[_stackEnabledKey] = value;
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
