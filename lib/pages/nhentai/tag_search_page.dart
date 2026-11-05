import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_presets.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

/// Opens the nhentai multi-tag search.
///
/// When [initialQuery] is given it replaces the current draft; otherwise the
/// draft built so far (e.g. from the comic page) is kept. [onSearch] receives
/// the final query; by default the result page replaces the editor.
Future<void> openNhentaiTagSearch(
  BuildContext context, {
  String? initialQuery,
  void Function(String query)? onSearch,
}) {
  if (initialQuery != null) {
    NhentaiTagDraft.value = NhentaiTagQuery.parse(initialQuery);
  }
  return context.to(() => NhentaiTagSearchPage(onSearch: onSearch));
}

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

String nhentaiTermLabel(NhentaiTagTerm term) {
  var translated = nhentaiTermTranslation(term.namespace, term.value);
  var name = translated.isEmpty ? term.value : '$translated ${term.value}';
  var prefix =
      term.namespace == 'tag' ? '' : '${nhentaiNamespaceLabel(term.namespace)}: ';
  return '${term.exclude ? '−' : ''}$prefix$name';
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

class NhentaiTagSearchPage extends StatefulWidget {
  const NhentaiTagSearchPage({super.key, this.onSearch});

  final void Function(String query)? onSearch;

  @override
  State<NhentaiTagSearchPage> createState() => _NhentaiTagSearchPageState();
}

class _NhentaiTagSearchPageState extends State<NhentaiTagSearchPage> {
  final inputController = TextEditingController();
  late final textController =
      TextEditingController(text: NhentaiTagDraft.value.text);
  final minPagesController = TextEditingController();
  final maxPagesController = TextEditingController();

  var localSuggestions = <NhentaiTagSuggestion>[];
  var remoteSuggestions = <NhentaiTagSuggestion>[];
  bool loadingRemote = false;
  Timer? debounce;
  CancelToken? cancelToken;

  NhentaiTagQuery get query => NhentaiTagDraft.value;

  set query(NhentaiTagQuery value) {
    NhentaiTagDraft.value = value;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    minPagesController.text =
        query.filterOf(NhentaiNumericField.pages, '>')?.value.toString() ?? '';
    maxPagesController.text =
        query.filterOf(NhentaiNumericField.pages, '<')?.value.toString() ?? '';
  }

  @override
  void dispose() {
    debounce?.cancel();
    cancelToken?.cancel();
    inputController.dispose();
    textController.dispose();
    minPagesController.dispose();
    maxPagesController.dispose();
    super.dispose();
  }

  void onInputChanged(String value) {
    debounce?.cancel();
    cancelToken?.cancel();
    var text = value.trim();
    setState(() {
      localSuggestions = nhentaiLocalTagSuggestions(text);
      remoteSuggestions = [];
      loadingRemote = false;
    });
    // The API only knows English names.
    if (text.length < 2 || !RegExp(r'^[\x20-\x7e]+$').hasMatch(text)) return;
    debounce = Timer(const Duration(milliseconds: 450), () async {
      var token = cancelToken = CancelToken();
      setState(() => loadingRemote = true);
      var result =
          await NhentaiNetwork().autocompleteTags(text, cancelToken: token);
      if (!mounted || token.isCancelled || inputController.text.trim() != text) {
        return;
      }
      setState(() {
        loadingRemote = false;
        // On failure keep the local suggestions only.
        remoteSuggestions = result.dataOrNull ?? const [];
      });
    });
  }

  void addTerm(NhentaiTagTerm term) {
    query = query.add(term);
    inputController.clear();
    onInputChanged('');
  }

  /// Adds whatever is typed as a plain tag, e.g. when nothing matches.
  void addTyped({bool exclude = false}) {
    var text = inputController.text.trim();
    if (text.isEmpty) return;
    // E-Hentai style `female:glasses` is a plain tag on nhentai.
    var ehStyle = RegExp(r'^(-?)(?:female|male|mixed|other):"?([^"]+)"?$')
        .firstMatch(text);
    if (ehStyle != null) {
      text = '${ehStyle.group(1)}tag:"${ehStyle.group(2)}"';
    }
    var parsed = NhentaiTagQuery.parse(text);
    if (parsed.terms.length == 1 && parsed.text.isEmpty) {
      var term = parsed.terms.single;
      addTerm(exclude ? term.copyWith(exclude: true) : term);
      return;
    }
    addTerm(NhentaiTagTerm('tag', text.replaceAll('"', ''), exclude: exclude));
  }

  NhentaiTagQuery buildFinalQuery() {
    var q = query.copyWith(text: textController.text.trim());
    int? parse(TextEditingController c) => int.tryParse(c.text.trim());
    // Keep a parsed `pages:>20` as is when the number was not edited,
    // otherwise the field means "at least" / "at most".
    NhentaiNumericFilter? bound(String side, int? value) {
      if (value == null) return null;
      var old = query.filterOf(NhentaiNumericField.pages, side);
      if (old != null && old.value == value) return old;
      return NhentaiNumericFilter(
          NhentaiNumericField.pages, side == '>' ? '>=' : '<=', value);
    }

    q = q.setFilter(NhentaiNumericField.pages, '>',
        bound('>', parse(minPagesController)));
    q = q.setFilter(NhentaiNumericField.pages, '<',
        bound('<', parse(maxPagesController)));
    return q;
  }

  void search() {
    var q = buildFinalQuery();
    NhentaiTagDraft.value = q;
    var text = q.toQuery();
    if (text.isEmpty) {
      showToast(message: '请至少添加一个标签'.tl);
      return;
    }
    if (widget.onSearch != null) {
      context.pop();
      widget.onSearch!(text);
    } else {
      context.off(() => SearchResultPage(keyword: text, sourceKey: 'nhentai'));
    }
  }

  void savePreset() {
    var q = buildFinalQuery();
    if (q.isEmpty) {
      showToast(message: '请至少添加一个标签'.tl);
      return;
    }
    var controller = TextEditingController(
      text: q.includes.map((t) => t.value).take(3).join(' + '),
    );
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('保存组合'.tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: '名称'.tl),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () async {
              var name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.of(dialogContext).pop();
              await NhentaiTagPresets.savePreset(
                  NhentaiTagPreset(name, q.toQuery()));
              showToast(message: '已保存'.tl);
            },
            child: Text('确认'.tl),
          ),
        ],
      ),
    );
  }

  void showPresets() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => ValueListenableBuilder(
        valueListenable: NhentaiTagPresets.changes,
        builder: (context, _, __) {
          var presets = NhentaiTagPresets.presets;
          if (presets.isEmpty) {
            return SizedBox(
              height: 160,
              child: Center(child: Text('还没有保存的组合'.tl)),
            );
          }
          return ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text('常用组合'.tl)),
              for (var p in presets)
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(p.query, maxLines: 2),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    loadQuery(NhentaiTagQuery.parse(p.query));
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => NhentaiTagPresets.removePreset(p.name),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void loadQuery(NhentaiTagQuery q) {
    textController.text = q.text;
    minPagesController.text =
        q.filterOf(NhentaiNumericField.pages, '>')?.value.toString() ?? '';
    maxPagesController.text =
        q.filterOf(NhentaiNumericField.pages, '<')?.value.toString() ?? '';
    query = q;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('组合标签搜索'.tl),
        actions: [
          IconButton(
            tooltip: '常用组合'.tl,
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: showPresets,
          ),
          IconButton(
            tooltip: '保存组合'.tl,
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: savePreset,
          ),
          IconButton(
            tooltip: '清空'.tl,
            icon: const Icon(Icons.clear_all),
            onPressed: () => loadQuery(NhentaiTagQuery.empty),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: search,
        icon: const Icon(Icons.search),
        label: Text('搜索'.tl),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 96 + context.padding.bottom),
        children: [
          buildSelected(),
          const SizedBox(height: 12),
          buildInput(),
          buildSuggestions(),
          const Divider(height: 32),
          buildFilters(),
          const Divider(height: 32),
          buildDefaultExcludes(),
        ],
      ),
    );
  }

  Widget buildSelected() {
    var terms = query.terms;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('已选标签'.tl, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '同时满足所有标签。点一下切换包含/排除，排除的标签显示为红色。'.tl,
          style: TextStyle(fontSize: 12, color: context.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        if (terms.isEmpty)
          Text('还没有选择标签'.tl,
              style: TextStyle(color: context.colorScheme.outline))
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var term in terms)
                NhentaiTermChip(
                  term: term,
                  onPressed: () => query = query.toggle(term),
                  onDeleted: () => query = query.remove(term),
                ),
            ],
          ),
      ],
    );
  }

  Widget buildInput() {
    return TextField(
      controller: inputController,
      onChanged: onInputChanged,
      onSubmitted: (_) => addTyped(),
      decoration: InputDecoration(
        labelText: '添加标签'.tl,
        hintText: '输入标签名, 中英文都可以'.tl,
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '包含'.tl,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => addTyped(),
            ),
            IconButton(
              tooltip: '排除'.tl,
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => addTyped(exclude: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSuggestions() {
    var seen = <String>{};
    var items = <NhentaiTagSuggestion>[];
    for (var s in [...remoteSuggestions, ...localSuggestions]) {
      if (seen.add('${s.type}:${s.name.toLowerCase()}')) items.add(s);
    }
    if (items.isEmpty && !loadingRemote) return const SizedBox();
    return Column(
      children: [
        if (loadingRemote) const LinearProgressIndicator(minHeight: 2),
        for (var s in items.take(30)) buildSuggestion(s),
      ],
    );
  }

  Widget buildSuggestion(NhentaiTagSuggestion s) {
    var term = s.toTerm();
    var translation = nhentaiTermTranslation(s.type, s.name);
    var existing = query.find(term);
    var info = [
      nhentaiNamespaceLabel(s.type),
      if (translation.isNotEmpty) translation,
      if (s.count > 0) '${s.count}',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8),
      title: Text(s.name),
      subtitle: Text(info),
      onTap: () => addTerm(term),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '包含'.tl,
            icon: Icon(existing != null && !existing.exclude
                ? Icons.add_circle
                : Icons.add_circle_outline),
            onPressed: () => addTerm(term),
          ),
          IconButton(
            tooltip: '排除'.tl,
            icon: Icon(
              existing?.exclude == true
                  ? Icons.remove_circle
                  : Icons.remove_circle_outline,
              color: context.colorScheme.error,
            ),
            onPressed: () => addTerm(term.copyWith(exclude: true)),
          ),
        ],
      ),
    );
  }

  Widget buildFilters() {
    // Checked against nhentai on 2026-11-06: `uploaded:<1d` and
    // `uploaded:<1y` return nothing, while 24h / 365d work.
    const uploadedOptions = <(String, int?, String)>[
      ('不限', null, ''),
      ('24小时内', 24, 'h'),
      ('一周内', 7, 'd'),
      ('一个月内', 30, 'd'),
      ('一年内', 365, 'd'),
    ];
    var uploaded = query.filterOf(NhentaiNumericField.uploaded, '<');
    Widget pagesField(TextEditingController c, String label) => SizedBox(
          width: 110,
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('筛选'.tl, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('页数'.tl),
            const SizedBox(width: 12),
            pagesField(minPagesController, '最少'.tl),
            const Text('  ~  '),
            pagesField(maxPagesController, '最多'.tl),
          ],
        ),
        const SizedBox(height: 12),
        Text('上传时间'.tl),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var (label, value, unit) in uploadedOptions)
              OptionChip(
                text: label.tl,
                isSelected: value == null
                    ? uploaded == null
                    : uploaded?.value == value && uploaded?.unit == unit,
                onTap: () => query = query.setFilter(
                  NhentaiNumericField.uploaded,
                  '<',
                  value == null
                      ? null
                      : NhentaiNumericFilter(
                          NhentaiNumericField.uploaded, '<', value, unit),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: textController,
          decoration: InputDecoration(
            labelText: '其他关键词'.tl,
            hintText: '标题、ID 等, 会原样加到搜索里'.tl,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget buildDefaultExcludes() {
    return ValueListenableBuilder(
      valueListenable: NhentaiTagPresets.changes,
      builder: (context, _, __) {
        var defaults = NhentaiTagPresets.defaultExcludes.terms;
        var excludes = query.excludes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('默认排除'.tl, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '每次 nhentai 搜索和分类页都会自动排除这些标签; 在搜索里手动包含某个标签时, 以手动的为准。'.tl,
              style: TextStyle(fontSize: 12, color: context.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            if (defaults.isEmpty)
              Text('未设置'.tl, style: TextStyle(color: context.colorScheme.outline))
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var term in defaults)
                    NhentaiTermChip(
                      term: term,
                      onDeleted: () => NhentaiTagPresets.setDefaultExcludes(
                          defaults.where((t) => !t.sameTarget(term)).toList()),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.playlist_add),
                  label: Text('把当前排除的标签加入默认'.tl),
                  onPressed: excludes.isEmpty
                      ? null
                      : () {
                          var merged = NhentaiTagQuery(terms: defaults);
                          for (var t in excludes) {
                            merged = merged.add(t);
                          }
                          NhentaiTagPresets.setDefaultExcludes(merged.terms);
                          showToast(message: '已保存'.tl);
                        },
                ),
                if (defaults.isNotEmpty)
                  TextButton(
                    onPressed: () => NhentaiTagPresets.setDefaultExcludes([]),
                    child: Text('清空默认排除'.tl),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class NhentaiTermChip extends StatelessWidget {
  const NhentaiTermChip({
    super.key,
    required this.term,
    this.onPressed,
    this.onDeleted,
    this.dimmed = false,
  });

  final NhentaiTagTerm term;

  final VoidCallback? onPressed;

  final VoidCallback? onDeleted;

  /// Used for default exclusions that are applied implicitly.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    var colors = context.colorScheme;
    var background = term.exclude ? colors.errorContainer : colors.secondaryContainer;
    var foreground =
        term.exclude ? colors.onErrorContainer : colors.onSecondaryContainer;
    if (dimmed) {
      background = background.withValues(alpha: 0.4);
    }
    return InputChip(
      label: Text(nhentaiTermLabel(term)),
      labelStyle: TextStyle(color: foreground, fontSize: 13),
      backgroundColor: background,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      onDeleted: onDeleted,
      deleteIconColor: foreground,
    );
  }
}

/// Chip row shown under the search bar of nhentai search results.
class NhentaiQueryChipsBar extends StatelessWidget {
  const NhentaiQueryChipsBar({
    super.key,
    required this.keyword,
    required this.onChanged,
  });

  static const height = 44.0;

  final String keyword;

  final void Function(String keyword) onChanged;

  @override
  Widget build(BuildContext context) {
    var query = NhentaiTagQuery.parse(keyword);
    var defaults = query.missingTermsFrom(NhentaiTagPresets.defaultExcludes);
    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          ActionChip(
            avatar: const Icon(Icons.tune, size: 18),
            label: Text('组合'.tl),
            visualDensity: VisualDensity.compact,
            onPressed: () => openNhentaiTagSearch(
              context,
              initialQuery: keyword,
              onSearch: onChanged,
            ),
          ),
          for (var term in query.terms)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: NhentaiTermChip(
                term: term,
                onPressed: () => onChanged(query.toggle(term).toQuery()),
                onDeleted: () => onChanged(query.remove(term).toQuery()),
              ),
            ),
          for (var term in defaults)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: '默认排除'.tl,
                child: NhentaiTermChip(
                  term: term,
                  dimmed: true,
                  onPressed: () => openNhentaiTagSearch(
                    context,
                    initialQuery: keyword,
                    onSearch: onChanged,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
