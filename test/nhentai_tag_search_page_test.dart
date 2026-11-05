import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/nhentai_network/tag_presets.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/pages/nhentai/tag_search_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  late Map<String, dynamic> data;

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    data = {};
    NhentaiTagPresets.dataProvider = () => data;
    NhentaiTagPresets.saver = () async {};
    NhentaiTagDraft.clear();
  });

  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<List<String>> openEditor(WidgetTester tester,
      {String? initialQuery}) async {
    useTallScreen(tester);
    final searches = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => openNhentaiTagSearch(
              context,
              initialQuery: initialQuery,
              onSearch: searches.add,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(NhentaiTagSearchPage), findsOneWidget);
    return searches;
  }

  testWidgets('local suggestion adds a tag; chip toggles exclusion',
      (tester) async {
    final searches = await openEditor(tester);
    // One character: local suggestions only, no network request.
    await tester.enterText(find.byType(TextField).first, 'g');
    await tester.pump();
    await tester.tap(find.text('glasses'));
    await tester.pump();
    expect(NhentaiTagDraft.value.toQuery(), 'tag:"glasses"');
    await tester.tap(find.text('glasses'));
    await tester.pump();
    expect(NhentaiTagDraft.value.toQuery(), '-tag:"glasses"');
    expect(find.text('−glasses'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(searches, ['-tag:"glasses"']);
    expect(find.byType(NhentaiTagSearchPage), findsNothing);
  });

  testWidgets('initial query, page bounds and uploaded filter', (tester) async {
    final searches =
        await openEditor(tester, initialQuery: 'tag:"a" pages:>20 foo');
    expect(find.text('a'), findsOneWidget);
    // Unchanged lower bound keeps its original comparison.
    final pageFields = find.byWidgetPredicate((w) =>
        w is TextField && w.keyboardType == TextInputType.number);
    expect(pageFields, findsNWidgets(2));
    await tester.enterText(pageFields.last, '200');
    await tester.tap(find.text('一周内'));
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    // Filter order does not matter to nhentai.
    expect(searches, ['foo tag:"a" uploaded:<7d pages:>20 pages:<=200']);
  });

  testWidgets('typed text can be added as an exclusion', (tester) async {
    await openEditor(tester);
    await tester.enterText(find.byType(TextField).first, 'artist:"some one"');
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pump();
    expect(NhentaiTagDraft.value.toQuery(), '-artist:"some one"');
  });

  testWidgets('excluded tags can become default exclusions', (tester) async {
    await openEditor(tester, initialQuery: 'tag:"a" -tag:"b"');
    await tester.tap(find.text('把当前排除的标签加入默认'));
    await tester.pump();
    expect(NhentaiTagPresets.defaultExcludes.toQuery(), '-tag:"b"');
    // Let the toast timer finish.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('result chips edit the keyword and show default exclusions',
      (tester) async {
    await NhentaiTagPresets.setDefaultExcludes(
        const [NhentaiTagTerm('tag', 'yaoi')]);
    final changes = <String>[];
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NhentaiQueryChipsBar(
          keyword: 'tag:"a" -tag:"b" language:chinese',
          onChanged: changes.add,
        ),
      ),
    ));
    expect(find.text('−yaoi'), findsOneWidget);
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(changes.last, '-tag:"a" -tag:"b" language:chinese');
    final deleteB = find.descendant(
      of: find.widgetWithText(InputChip, '−b'),
      matching: find.byTooltip('Delete'),
    );
    await tester.tap(deleteB);
    await tester.pump();
    expect(changes.last, 'tag:"a" language:chinese');
  });
}
