import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/nhentai_network/tag_presets.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';

void main() {
  group('NhentaiTagQuery.toQuery', () {
    test('quotes values and marks exclusions', () {
      const query = NhentaiTagQuery(terms: [
        NhentaiTagTerm('tag', 'big breasts'),
        NhentaiTagTerm('tag', 'glasses'),
        NhentaiTagTerm('tag', 'yaoi', exclude: true),
        NhentaiTagTerm('artist', 'Some  Artist'),
      ]);
      expect(query.toQuery(),
          'tag:"big breasts" tag:"glasses" -tag:"yaoi" artist:"some artist"');
    });

    test('keeps simple language terms unquoted', () {
      expect(const NhentaiTagTerm('language', 'Chinese').toQuery(),
          'language:chinese');
      expect(const NhentaiTagTerm('language', 'chinese', exclude: true).toQuery(),
          '-language:chinese');
    });

    test('escapes quotes and backslashes', () {
      expect(const NhentaiTagTerm('parody', 'a "b" \\ c').toQuery(),
          r'parody:"a \"b\" \\ c"');
    });

    test('puts free text first and numeric filters last', () {
      const query = NhentaiTagQuery(
        text: 'touhou',
        terms: [NhentaiTagTerm('tag', 'full color')],
        filters: [
          NhentaiNumericFilter(NhentaiNumericField.pages, '>', 20),
          NhentaiNumericFilter(NhentaiNumericField.uploaded, '<', 30, 'd'),
        ],
      );
      expect(query.toQuery(), 'touhou tag:"full color" pages:>20 uploaded:<30d');
    });

    test('empty query is empty string', () {
      expect(NhentaiTagQuery.empty.toQuery(), '');
      expect(NhentaiTagQuery.empty.isEmpty, isTrue);
    });
  });

  group('NhentaiTagQuery.parse', () {
    test('parses quoted, unquoted and excluded terms', () {
      final q = NhentaiTagQuery.parse(
          'tag:"big breasts" -tag:"yaoi" artist:someone language:chinese');
      expect(q.terms, const [
        NhentaiTagTerm('tag', 'big breasts'),
        NhentaiTagTerm('tag', 'yaoi', exclude: true),
        NhentaiTagTerm('artist', 'someone'),
        NhentaiTagTerm('language', 'chinese'),
      ]);
      expect(q.text, '');
    });

    test('keeps unknown tokens as text in order', () {
      final q = NhentaiTagQuery.parse(
          '"exact title" female:glasses foo -bar tag:"x-ray"');
      expect(q.text, '"exact title" female:glasses foo -bar');
      expect(q.terms, const [NhentaiTagTerm('tag', 'x-ray')]);
    });

    test('parses numeric filters and rejects bad ones', () {
      final q = NhentaiTagQuery.parse(
          'pages:>20 pages:<=200 uploaded:<7d favorites:>=100 pages:>2d uploaded:abc');
      expect(q.filters, const [
        NhentaiNumericFilter(NhentaiNumericField.pages, '>', 20),
        NhentaiNumericFilter(NhentaiNumericField.pages, '<=', 200),
        NhentaiNumericFilter(NhentaiNumericField.uploaded, '<', 7, 'd'),
        NhentaiNumericFilter(NhentaiNumericField.favorites, '>=', 100),
      ]);
      expect(q.text, 'pages:>2d uploaded:abc');
    });

    test('unescapes quoted values', () {
      final q = NhentaiTagQuery.parse(r'parody:"a \"b\" \\ c"');
      expect(q.terms.single.value, r'a "b" \ c');
    });

    test('later duplicate target wins', () {
      final q = NhentaiTagQuery.parse('tag:"Glasses" -tag:"glasses"');
      expect(q.terms, const [NhentaiTagTerm('tag', 'glasses', exclude: true)]);
    });

    test('round trips canonical queries', () {
      const canonical =
          'touhou tag:"big breasts" -tag:"yaoi" artist:"a b" language:chinese pages:>20 uploaded:<30d';
      expect(NhentaiTagQuery.parse(canonical).toQuery(), canonical);
    });

    test('treats empty values and lone dashes as text', () {
      final q = NhentaiTagQuery.parse('tag:"" - tag:');
      expect(q.terms, isEmpty);
      expect(q.text, 'tag:"" - tag:');
    });
  });

  group('editing', () {
    test('add replaces same target in place, toggle flips', () {
      var q = const NhentaiTagQuery(terms: [
        NhentaiTagTerm('tag', 'a'),
        NhentaiTagTerm('tag', 'b'),
      ]);
      q = q.add(const NhentaiTagTerm('tag', 'A', exclude: true));
      expect(q.toQuery(), '-tag:"a" tag:"b"');
      q = q.toggle(const NhentaiTagTerm('tag', 'b'));
      expect(q.toQuery(), '-tag:"a" -tag:"b"');
      q = q.toggle(const NhentaiTagTerm('artist', 'c'));
      expect(q.toQuery(), '-tag:"a" -tag:"b" artist:"c"');
      q = q.remove(const NhentaiTagTerm('tag', 'a'));
      expect(q.toQuery(), '-tag:"b" artist:"c"');
    });

    test('same value in different namespaces are different targets', () {
      var q = const NhentaiTagQuery(terms: [NhentaiTagTerm('tag', 'x')]);
      q = q.add(const NhentaiTagTerm('artist', 'x'));
      expect(q.terms.length, 2);
    });

    test('setFilter keeps lower and upper bounds separately', () {
      var q = NhentaiTagQuery.empty
          .setFilter(NhentaiNumericField.pages, '>',
              const NhentaiNumericFilter(NhentaiNumericField.pages, '>', 20))
          .setFilter(NhentaiNumericField.pages, '<',
              const NhentaiNumericFilter(NhentaiNumericField.pages, '<', 100));
      expect(q.toQuery(), 'pages:>20 pages:<100');
      q = q.setFilter(NhentaiNumericField.pages, '>=',
          const NhentaiNumericFilter(NhentaiNumericField.pages, '>=', 30));
      expect(q.toQuery(), 'pages:<100 pages:>=30');
      q = q.setFilter(NhentaiNumericField.pages, '<', null);
      expect(q.toQuery(), 'pages:>=30');
    });
  });

  test('nhentaiNamespaceOfField maps detail page fields', () {
    expect(nhentaiNamespaceOfField('Tags'), 'tag');
    expect(nhentaiNamespaceOfField('Characters'), 'character');
    expect(nhentaiNamespaceOfField('Character'), 'character');
    expect(nhentaiNamespaceOfField('Parodies'), 'parody');
    expect(nhentaiNamespaceOfField('Pages'), isNull);
  });

  test('parseNhentaiTagSuggestions keeps valid entries', () {
    final result = parseNhentaiTagSuggestions([
      {'id': 2937, 'type': 'tag', 'name': 'big breasts', 'count': 240332},
      {'type': 'artist', 'name': 'x', 'count': '12'},
      {'type': 'unknown', 'name': 'y'},
      {'type': 'tag', 'name': ''},
      'garbage',
    ]);
    expect(result.map((e) => '${e.type}:${e.name}:${e.count}'),
        ['tag:big breasts:240332', 'artist:x:12']);
    expect(parseNhentaiTagSuggestions({'result': []}), isEmpty);
    expect(parseNhentaiTagSuggestions(null), isEmpty);
  });

  group('NhentaiTagPresets', () {
    late Map<String, dynamic> data;
    late int saves;

    setUp(() {
      data = {};
      saves = 0;
      NhentaiTagPresets.dataProvider = () => data;
      NhentaiTagPresets.saver = () async => saves++;
    });

    test('saves, replaces and removes presets by name', () async {
      await NhentaiTagPresets.savePreset(
          const NhentaiTagPreset('a', 'tag:"x"'));
      await NhentaiTagPresets.savePreset(
          const NhentaiTagPreset('b', 'tag:"y"'));
      await NhentaiTagPresets.savePreset(
          const NhentaiTagPreset('a', 'tag:"z"'));
      expect(NhentaiTagPresets.presets.map((p) => '${p.name}=${p.query}'),
          ['b=tag:"y"', 'a=tag:"z"']);
      await NhentaiTagPresets.removePreset('b');
      expect(NhentaiTagPresets.presets.map((p) => p.name), ['a']);
      expect(saves, 4);
    });

    test('ignores corrupted preset data', () {
      data['multiTagPresets'] = [
        {'name': 'ok', 'query': 'tag:"x"'},
        {'name': '', 'query': 'tag:"x"'},
        {'name': 1},
        'bad',
      ];
      expect(NhentaiTagPresets.presets.map((p) => p.name), ['ok']);
      data['multiTagPresets'] = 'bad';
      expect(NhentaiTagPresets.presets, isEmpty);
    });

    test('default excludes are always exclusions', () async {
      await NhentaiTagPresets.setDefaultExcludes(const [
        NhentaiTagTerm('tag', 'yaoi'),
        NhentaiTagTerm('tag', 'guro', exclude: true),
      ]);
      expect(NhentaiTagPresets.defaultExcludes.toQuery(),
          '-tag:"yaoi" -tag:"guro"');
      await NhentaiTagPresets.setDefaultExcludes(const []);
      expect(data.containsKey('multiTagDefaultExcludes'), isFalse);
    });

    test('applyDefaultExcludes appends only unmentioned tags', () async {
      expect(NhentaiTagPresets.applyDefaultExcludes('tag:"a"'), 'tag:"a"');
      await NhentaiTagPresets.setDefaultExcludes(const [
        NhentaiTagTerm('tag', 'yaoi'),
        NhentaiTagTerm('tag', 'guro'),
      ]);
      expect(NhentaiTagPresets.applyDefaultExcludes('tag:"a"'),
          'tag:"a" -tag:"yaoi" -tag:"guro"');
      // Explicitly including a default-excluded tag overrides the default.
      expect(NhentaiTagPresets.applyDefaultExcludes('tag:"yaoi" foo'),
          'tag:"yaoi" foo -tag:"guro"');
      expect(NhentaiTagPresets.applyDefaultExcludes(''),
          '-tag:"yaoi" -tag:"guro"');
      expect(
          NhentaiTagPresets.applyDefaultExcludes(
              '-tag:"yaoi" -tag:"guro"'),
          '-tag:"yaoi" -tag:"guro"');
    });
  });

  test('NhentaiTagDraft accumulates terms', () {
    NhentaiTagDraft.clear();
    NhentaiTagDraft.add(const NhentaiTagTerm('tag', 'a'));
    NhentaiTagDraft.add(const NhentaiTagTerm('tag', 'a', exclude: true));
    NhentaiTagDraft.add(const NhentaiTagTerm('artist', 'b'));
    expect(NhentaiTagDraft.value.toQuery(), '-tag:"a" artist:"b"');
    NhentaiTagDraft.clear();
    expect(NhentaiTagDraft.value.isEmpty, isTrue);
  });
}
