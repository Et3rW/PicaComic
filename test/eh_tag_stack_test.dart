import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/tag_settings.dart';
import 'package:pica_comic/network/eh_network/tag_stack.dart';
import 'package:pica_comic/pages/ehentai/tag_stack_bar.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  List<String> keywords(List<EhTagTerm>? terms) =>
      [for (final term in terms ?? const <EhTagTerm>[]) term.toKeyword()];

  group('reading the tags of a search', () {
    test('plain, exact, quoted and excluded tags', () {
      final terms = ehTermsFromKeyword(
          r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi  artist:"some one"')!;
      expect(terms.map((t) => (t.namespace, t.value, t.exact, t.exclude)), [
        ('language', 'chinese', false, false),
        ('female', 'glasses', true, false),
        ('female', 'big breasts', true, false),
        ('male', 'yaoi', false, true),
        ('artist', 'some one', false, false),
      ]);
    });

    test('a search is written back the way it was typed', () {
      const keyword =
          r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi';
      expect(ehKeywordFromTerms(ehTermsFromKeyword(keyword)!), keyword);
    });

    test('translated alternatives from the suggestions keep the tag', () {
      expect(keywords(ehTermsFromKeyword('female:"big breasts | 巨乳"')),
          [r'female:"big breasts$"']);
    });

    test('anything that is not a tag means no stacking', () {
      expect(ehTermsFromKeyword(''), isNull);
      expect(ehTermsFromKeyword('   '), isNull);
      expect(ehTermsFromKeyword('touhou'), isNull);
      expect(ehTermsFromKeyword('female:glasses touhou'), isNull);
      expect(ehTermsFromKeyword('"some title"'), isNull);
      expect(ehTermsFromKeyword('female:'), isNull);
      expect(ehTermsFromKeyword(r'female:$'), isNull);
    });
  });

  group('adding a tag', () {
    final base = ehTermsFromKeyword('language:chinese female:glasses')!;

    test('appends to the search', () {
      final result = ehStackAdd(base, const EhTagTerm('artist', 'some one'));
      expect(result.outcome, EhStackOutcome.added);
      expect(ehKeywordFromTerms(result.terms),
          'language:chinese female:glasses artist:"some one"');
    });

    test('the same tag again is refused', () {
      final result = ehStackAdd(base, const EhTagTerm('female', 'Glasses'));
      expect(result.outcome, EhStackOutcome.duplicate);
      expect(result.terms, same(base));
    });

    test('the same name in another namespace is a different tag', () {
      final result = ehStackAdd(base, const EhTagTerm('male', 'glasses'));
      expect(result.outcome, EhStackOutcome.added);
    });

    test('a new language replaces the old one', () {
      final result = ehStackAdd(base, const EhTagTerm('language', 'english'));
      expect(keywords(result.terms), ['female:glasses', 'language:english']);
    });

    test('language flags stack with a language', () {
      final result =
          ehStackAdd(base, const EhTagTerm('language', 'translated'));
      expect(keywords(result.terms),
          ['language:chinese', 'female:glasses', 'language:translated']);
    });

    test('stops at the limit', () {
      var terms = <EhTagTerm>[];
      for (var i = 0; i < ehTagStackLimit; i++) {
        final result = ehStackAdd(terms, EhTagTerm('female', 'tag$i'));
        expect(result.outcome, EhStackOutcome.added);
        terms = result.terms;
      }
      final result = ehStackAdd(terms, const EhTagTerm('female', 'one more'));
      expect(result.outcome, EhStackOutcome.limit);
      expect(result.terms, hasLength(ehTagStackLimit));
      // Replacing a language does not count against the limit.
      final withLanguage = [...terms.skip(1), const EhTagTerm('language', 'chinese')];
      expect(
          ehStackAdd(withLanguage, const EhTagTerm('language', 'english')).outcome,
          EhStackOutcome.added);
    });
  });

  group('setting', () {
    late Map<String, dynamic> data;
    setUp(() {
      data = {};
      EhTagSettings.dataProvider = () => data;
      EhTagSettings.saver = () async {};
    });

    test('is on by default and can be turned off', () async {
      expect(EhTagSettings.stackEnabled, isTrue);
      var notified = 0;
      void listener() => notified++;
      EhTagSettings.changes.addListener(listener);
      await EhTagSettings.setStackEnabled(false);
      EhTagSettings.changes.removeListener(listener);
      expect(EhTagSettings.stackEnabled, isFalse);
      expect(data['tagStackEnabled'], isFalse);
      expect(notified, 1);
    });
  });

  testWidgets('chips show every tag and remove the one tapped',
      (tester) async {
    AppTranslation.translations = {};
    final removed = <String>[];
    final terms = ehTermsFromKeyword(r'language:chinese -female:"big breasts$"')!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EhTagStackBar(
          terms: terms,
          onRemove: (term) => removed.add(term.toKeyword()),
        ),
      ),
    ));
    expect(find.byType(InputChip), findsNWidgets(2));
    expect(find.text('chinese'), findsOneWidget);
    expect(find.text('−big breasts'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, '−big breasts'),
        matching: find.byTooltip('移除')));
    expect(removed, [r'-female:"big breasts$"']);
  });
}
