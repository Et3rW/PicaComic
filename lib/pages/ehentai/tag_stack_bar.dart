import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/eh_network/tag_stack.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

/// Chip label: the Chinese name when known, otherwise the tag itself.
String ehTermShortLabel(EhTagTerm term) {
  String? translated;
  if (App.locale.languageCode == 'zh') {
    var value = term.value.toLowerCase();
    translated = switch (term.namespace) {
      'female' => TagsTranslation.femaleTags[value],
      'male' => TagsTranslation.maleTags[value],
      'mixed' => TagsTranslation.mixedTags[value],
      'other' => TagsTranslation.otherTags[value],
      'artist' => TagsTranslation.artistTags[value],
      'parody' => TagsTranslation.parodyTags[value],
      'character' => TagsTranslation.characterTranslations[value],
      'group' => TagsTranslation.groupTags[value],
      'cosplayer' => TagsTranslation.cosplayerTags[value],
      'language' => TagsTranslation.languageTranslations[value],
      _ => null,
    };
  }
  return '${term.exclude ? '−' : ''}${translated ?? term.value}';
}

/// The tags of a stacked e-hentai search as chips; each can be removed.
class EhTagStackBar extends StatelessWidget {
  const EhTagStackBar({super.key, required this.terms, required this.onRemove});

  final List<EhTagTerm> terms;

  final void Function(EhTagTerm term) onRemove;

  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (var term in terms)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: Tooltip(
                  message: '${term.namespace}:${term.value}',
                  child: InputChip(
                    label: Text(ehTermShortLabel(term)),
                    labelStyle: const TextStyle(fontSize: 14),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () => onRemove(term),
                    deleteButtonTooltipMessage: '移除'.tl,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
