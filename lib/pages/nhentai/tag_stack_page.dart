import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

String nhentaiNamespaceLabel(String namespace) => switch (namespace) {
      'tag' => '标签'.tl,
      'artist' => '画师'.tl,
      'parody' => '原作'.tl,
      'character' => '角色'.tl,
      'group' => '团队'.tl,
      'language' => '语言'.tl,
      'category' => '分类'.tl,
      _ => namespace,
    };

/// Chinese name of an nhentai tag when the UI language is Chinese.
String nhentaiTermTranslation(String namespace, String value) {
  if (App.locale.languageCode != 'zh') return '';
  var v = value.toLowerCase();
  String? result = switch (namespace) {
    'tag' => TagsTranslation.femaleTags[v] ??
        TagsTranslation.maleTags[v] ??
        TagsTranslation.mixedTags[v] ??
        TagsTranslation.otherTags[v],
    'artist' => TagsTranslation.artistTags[v],
    'parody' => TagsTranslation.parodyTags[v],
    'character' => TagsTranslation.characterTranslations[v],
    'group' => TagsTranslation.groupTags[v],
    'language' => TagsTranslation.languageTranslations[v],
    _ => null,
  };
  return result == null || result == value ? '' : result;
}

/// Short chip label: the Chinese name when known, otherwise the tag itself.
String nhentaiTermShortLabel(NhentaiTagTerm term) {
  var translated = nhentaiTermTranslation(term.namespace, term.value);
  var name = translated.isEmpty ? term.value : translated;
  return '${term.exclude ? '−' : ''}$name';
}

/// Suggestions from the bundled tag translations and nhentai tag list.
/// Matches English names by prefix/word and Chinese names by substring.
List<NhentaiTagSuggestion> nhentaiLocalTagSuggestions(String input,
    {int limit = 30}) {
  var text = input.trim().toLowerCase();
  if (text.isEmpty) return const [];
  var scored = <(int, NhentaiTagSuggestion)>[];
  var seen = <String>{};

  void consider(String namespace, String name, String translation) {
    var key = '$namespace:$name';
    if (seen.contains(key)) return;
    int? score;
    if (name == text || translation == text) {
      score = 0;
    } else if (name.startsWith(text) || translation.startsWith(text)) {
      score = 1;
    } else if (name.split(' ').any((w) => w.startsWith(text))) {
      score = 2;
    } else if (name.contains(text) || translation.contains(text)) {
      score = 3;
    }
    if (score == null) return;
    seen.add(key);
    scored.add((score, NhentaiTagSuggestion(namespace, name)));
  }

  void scan(Map<String, String> map, String namespace) {
    for (var e in map.entries) {
      consider(namespace, e.key.toLowerCase(), e.value);
    }
  }

  scan(TagsTranslation.femaleTags, 'tag');
  scan(TagsTranslation.maleTags, 'tag');
  scan(TagsTranslation.mixedTags, 'tag');
  scan(TagsTranslation.otherTags, 'tag');
  for (var name in nhentaiTags.values) {
    consider('tag', name.toLowerCase(), '');
  }
  scan(TagsTranslation.parodyTags, 'parody');
  scan(TagsTranslation.characterTranslations, 'character');
  scan(TagsTranslation.artistTags, 'artist');
  scan(TagsTranslation.groupTags, 'group');
  scan(TagsTranslation.languageTranslations, 'language');

  scored.sort((a, b) {
    var c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.name.length.compareTo(b.$2.name.length);
  });
  return [for (var s in scored.take(limit)) s.$2];
}

/// Remembers which tag page a comic was opened from, so tapping a tag on
/// that comic can stack onto the page's tags.
class NhentaiTagStackContext {
  NhentaiTagStackContext._();

  static final _pages = <_NhentaiTagStackPageState>[];

  /// Per comic, the contexts it was opened with, oldest first. A comic can
  /// be open on several pages at once (e.g. from two stacked tag pages);
  /// closing one tag page drops only its own entries.
  static final _comics =
      <String, List<(_NhentaiTagStackPageState?, List<NhentaiTagTerm>)>>{};

  static const _maxEntriesPerComic = 8;

  /// Called when a comic is opened. Records the tags of the tag page that is
  /// currently on top, or that it was opened from somewhere else.
  static void onComicOpened(String comicId) {
    _NhentaiTagStackPageState? current;
    for (var page in _pages.reversed) {
      if (page.mounted && ModalRoute.of(page.context)?.isCurrent == true) {
        current = page;
        break;
      }
    }
    var entries = _comics.putIfAbsent(comicId, () => []);
    entries.add((current, List.unmodifiable(current?.terms ?? const [])));
    if (entries.length > _maxEntriesPerComic) entries.removeAt(0);
  }

  /// Tags of the page [comicId] was last opened from; empty if none.
  static List<NhentaiTagTerm> termsForComic(String comicId) =>
      _comics[comicId]?.lastOrNull?.$2 ?? const [];

  static void _register(_NhentaiTagStackPageState page) => _pages.add(page);

  static void _unregister(_NhentaiTagStackPageState page) {
    _pages.remove(page);
    for (var entries in _comics.values) {
      entries.removeWhere((e) => identical(e.$1, page));
    }
    _comics.removeWhere((_, entries) => entries.isEmpty);
  }
}

/// Category page for one or more nhentai tags. Tags are shown as chips in
/// the title; each has a delete button while more than one is left.
class NhentaiTagStackPage extends StatefulWidget {
  const NhentaiTagStackPage({super.key, required this.terms, this.category});

  final List<NhentaiTagTerm> terms;

  /// Category name of the classic page this replaces, if any. Only used to
  /// pick which sort options apply.
  final String? category;

  @override
  State<NhentaiTagStackPage> createState() => _NhentaiTagStackPageState();
}

class _NhentaiTagStackPageState extends State<NhentaiTagStackPage> {
  late List<NhentaiTagTerm> terms = List.of(widget.terms);

  late final CategoryComicsData data = nhentai.categoryComicsData!;

  late final List<CategoryComicsOptions> options = data.options
      .where((e) => !e.notShowWhen.contains(widget.category))
      .where((e) => e.showWhen == null || e.showWhen!.contains(widget.category))
      .toList();

  late List<String> optionsValue =
      options.map((e) => e.options.keys.first).toList();

  String get param => nhentaiStackParam(terms);

  String get category =>
      terms.length == 1 ? (widget.category ?? terms.single.value) : 'combo';

  @override
  void initState() {
    super.initState();
    NhentaiTagStackContext._register(this);
  }

  @override
  void dispose() {
    NhentaiTagStackContext._unregister(this);
    super.dispose();
  }

  void remove(NhentaiTagTerm term) {
    if (terms.length <= 1) return;
    setState(() {
      terms = terms.where((t) => !t.sameTarget(term)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: buildTitle()),
      body: _NhentaiTagStackComicsList(
        key: ValueKey('$param with $optionsValue'),
        loader: data.load,
        category: category,
        param: param,
        options: optionsValue,
        header: buildOptions(),
      ),
    );
  }

  Widget buildTitle() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var term in terms)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: '${term.namespace}:${term.value}',
                child: InputChip(
                  label: Text(nhentaiTermShortLabel(term)),
                  labelStyle: const TextStyle(fontSize: 14),
                  visualDensity: VisualDensity.compact,
                  onDeleted: terms.length > 1 ? () => remove(term) : null,
                  deleteButtonTooltipMessage: '移除'.tl,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildOptions() {
    var children = <Widget>[];
    for (var i = 0; i < options.length; i++) {
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var option in options[i].options.entries)
            OptionChip(
              text: option.value.tl,
              isSelected: option.key == optionsValue[i],
              onTap: () {
                if (option.key == optionsValue[i]) return;
                setState(() {
                  optionsValue = List.of(optionsValue)..[i] = option.key;
                });
              },
            ),
        ],
      ));
      if (i != options.length - 1) children.add(const SizedBox(height: 8));
    }
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [...children, const Divider()],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}

class _NhentaiTagStackComicsList extends ComicsPage<BaseComic> {
  const _NhentaiTagStackComicsList({
    super.key,
    required this.loader,
    required this.category,
    required this.param,
    required this.options,
    required this.header,
  });

  final CategoryComicsLoader loader;

  final String category;

  final String param;

  final List<String> options;

  @override
  final Widget header;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) =>
      loader(category, param, options, i);

  @override
  String get sourceKey => 'nhentai';

  @override
  String? get tag => 'nhentai tag stack $param with $options';

  @override
  String? get title => null;
}

/// Opens the page for [terms] after stacking [term] onto [base], or tells
/// the user why nothing happened.
void openNhentaiTagStack(
    BuildContext context, List<NhentaiTagTerm> base, NhentaiTagTerm term) {
  var result = nhentaiStackAdd(base, term);
  switch (result.outcome) {
    case NhentaiStackOutcome.duplicate:
      showToast(message: '这个标签已经在当前组合里了'.tl);
    case NhentaiStackOutcome.limit:
      showToast(
          message: '最多同时 @n 个标签'.tlParams({'n': '$nhentaiTagStackLimit'}));
    case NhentaiStackOutcome.added:
      context.to(() => NhentaiTagStackPage(terms: result.terms));
  }
}

/// Settings page for tags excluded from every nhentai search.
class NhentaiDefaultExcludesPage extends StatefulWidget {
  const NhentaiDefaultExcludesPage({super.key});

  @override
  State<NhentaiDefaultExcludesPage> createState() =>
      _NhentaiDefaultExcludesPageState();
}

class _NhentaiDefaultExcludesPageState
    extends State<NhentaiDefaultExcludesPage> {
  final input = TextEditingController();
  var local = <NhentaiTagSuggestion>[];
  var remote = <NhentaiTagSuggestion>[];
  Timer? debounce;
  CancelToken? cancelToken;

  List<NhentaiTagTerm> get terms => NhentaiTagSettings.defaultExcludes.terms;

  @override
  void dispose() {
    debounce?.cancel();
    cancelToken?.cancel();
    input.dispose();
    super.dispose();
  }

  void onChanged(String value) {
    debounce?.cancel();
    cancelToken?.cancel();
    var text = value.trim();
    setState(() {
      local = nhentaiLocalTagSuggestions(text);
      remote = [];
    });
    // The API only knows English names.
    if (text.length < 2 || !RegExp(r'^[\x20-\x7e]+$').hasMatch(text)) return;
    debounce = Timer(const Duration(milliseconds: 450), () async {
      var token = cancelToken = CancelToken();
      var result =
          await NhentaiNetwork().autocompleteTags(text, cancelToken: token);
      if (!mounted || token.isCancelled || input.text.trim() != text) return;
      setState(() => remote = result.dataOrNull ?? const []);
    });
  }

  Future<void> add(NhentaiTagTerm term) async {
    var next = NhentaiTagQuery(terms: terms).add(term.copyWith(exclude: true));
    await NhentaiTagSettings.setDefaultExcludes(next.terms);
    input.clear();
    onChanged('');
  }

  Future<void> addTyped() async {
    var text = input.text.trim();
    if (text.isEmpty) return;
    var parsed = NhentaiTagQuery.parse(text);
    if (parsed.terms.length == 1 && parsed.text.isEmpty) {
      await add(parsed.terms.single);
      return;
    }
    // E-Hentai style `female:glasses` is a plain tag on nhentai.
    var plain = text
        .replaceFirst(RegExp(r'^(female|male|mixed|other):'), '')
        .replaceAll('"', '')
        .trim();
    if (plain.isNotEmpty) await add(NhentaiTagTerm('tag', plain));
  }

  @override
  Widget build(BuildContext context) {
    var seen = <String>{};
    var suggestions = [
      for (var s in [...remote, ...local])
        if (seen.add('${s.type}:${s.name.toLowerCase()}')) s,
    ];
    return Scaffold(
      appBar: Appbar(title: Text('默认排除的标签'.tl)),
      body: ValueListenableBuilder(
        valueListenable: NhentaiTagSettings.changes,
        builder: (context, _, __) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '每次 nhentai 搜索和分类页都会自动排除这些标签。搜索里手动写了某个标签时, 以手写的为准。'.tl,
              style: TextStyle(color: context.colorScheme.outline),
            ),
            const SizedBox(height: 12),
            if (terms.isEmpty)
              Text('未设置'.tl)
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var term in terms)
                    InputChip(
                      label: Text(
                          '${nhentaiTermShortLabel(term)}  ${term.namespace == 'tag' ? '' : nhentaiNamespaceLabel(term.namespace)}'
                              .trim()),
                      onDeleted: () => NhentaiTagSettings.setDefaultExcludes(
                          terms.where((t) => !t.sameTarget(term)).toList()),
                      deleteButtonTooltipMessage: '移除'.tl,
                    ),
                ],
              ),
            const SizedBox(height: 16),
            TextField(
              controller: input,
              onChanged: onChanged,
              onSubmitted: (_) => addTyped(),
              decoration: InputDecoration(
                labelText: '添加标签'.tl,
                hintText: '输入标签名, 中英文都可以'.tl,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '添加'.tl,
                  icon: const Icon(Icons.add),
                  onPressed: addTyped,
                ),
              ),
            ),
            for (var s in suggestions.take(30))
              ListTile(
                dense: true,
                title: Text(s.name),
                subtitle: Text([
                  nhentaiNamespaceLabel(s.type),
                  if (nhentaiTermTranslation(s.type, s.name).isNotEmpty)
                    nhentaiTermTranslation(s.type, s.name),
                  if (s.count > 0) '${s.count}',
                ].join(' · ')),
                trailing: const Icon(Icons.add),
                onTap: () => add(s.toTerm()),
              ),
          ],
        ),
      ),
    );
  }
}
