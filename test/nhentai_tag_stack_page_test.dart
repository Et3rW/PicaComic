import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/pages/nhentai/tag_stack_page.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = NhentaiNetwork();
  late SingleInstanceCookieJar cookies;
  late List<Uri> requests;
  late Map<String, dynamic> data;
  late String language;

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cookies = SingleInstanceCookieJar(':memory:');
    network.cookieJar = cookies;
    requests = [];
    data = {};
    language = appdata.settings[69];
    appdata.settings[69] = '0';
    NhentaiTagSettings.dataProvider = () => data;
    NhentaiTagSettings.saver = () async {};
    network.dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options.uri);
        // No galleries: keeps the test away from image loading.
        handler.resolve(Response<String>(
          requestOptions: options,
          statusCode: 200,
          data: '<html></html>',
        ));
      }));
  });

  tearDown(() {
    network.dio.close();
    network.cookieJar = null;
    cookies.dispose();
    SingleInstanceCookieJar.instance = null;
    appdata.settings[69] = language;
  });

  const chinese = NhentaiTagTerm('language', 'chinese');
  const glasses = NhentaiTagTerm('tag', 'glasses');

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  Finder deleteButtonOf(String label) => find.descendant(
        of: find.widgetWithText(InputChip, label),
        matching: find.byTooltip('移除'),
      );

  testWidgets('shows stacked tags as chips and removes them', (tester) async {
    await pumpPage(tester,
        const NhentaiTagStackPage(terms: [chinese, glasses]));
    expect(find.widgetWithText(InputChip, 'chinese'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'glasses'), findsOneWidget);
    expect(requests.last.queryParameters['q'], 'language:chinese tag:"glasses"');

    await tester.tap(deleteButtonOf('chinese'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'chinese'), findsNothing);
    // One tag left: back to the classic category route, no delete button.
    expect(requests.last.path, '/tag/glasses/');
    expect(deleteButtonOf('glasses'), findsNothing);
  });

  testWidgets('sort options reload with the same tags', (tester) async {
    await pumpPage(tester,
        const NhentaiTagStackPage(terms: [chinese, glasses]));
    await tester.tap(find.text('热门 | 一周'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters,
        {'q': 'language:chinese tag:"glasses"', 'page': '1', 'sort': 'popular-week'});
  });

  testWidgets('records the top tag page as context for opened comics',
      (tester) async {
    await pumpPage(tester,
        const NhentaiTagStackPage(terms: [chinese, glasses]));
    NhentaiTagStackContext.onComicOpened('1');
    expect(NhentaiTagStackContext.termsForComic('1'), const [chinese, glasses]);

    // A page pushed on top (e.g. the comic page) is not a tag page.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    NhentaiTagStackContext.onComicOpened('2');
    expect(NhentaiTagStackContext.termsForComic('2'), isEmpty);
    // Reopening comic 1 from elsewhere forgets its old context.
    NhentaiTagStackContext.onComicOpened('1');
    expect(NhentaiTagStackContext.termsForComic('1'), isEmpty);
  });

  testWidgets('closing a nested tag page restores the outer context',
      (tester) async {
    await pumpPage(tester, const NhentaiTagStackPage(terms: [chinese]));
    NhentaiTagStackContext.onComicOpened('4');
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(
        builder: (_) => const NhentaiTagStackPage(terms: [chinese, glasses])));
    await tester.pumpAndSettle();
    NhentaiTagStackContext.onComicOpened('4');
    expect(NhentaiTagStackContext.termsForComic('4'), const [chinese, glasses]);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(NhentaiTagStackContext.termsForComic('4'), const [chinese]);
  });

  testWidgets('closing the tag page clears its context', (tester) async {
    await pumpPage(tester, const NhentaiTagStackPage(terms: [chinese]));
    NhentaiTagStackContext.onComicOpened('3');
    expect(NhentaiTagStackContext.termsForComic('3'), const [chinese]);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(NhentaiTagStackContext.termsForComic('3'), isEmpty);
  });

  testWidgets('nhentai category pages become tag pages when enabled',
      (tester) async {
    await pumpPage(
        tester,
        const CategoryComicsPage(
            category: '中文', param: '/language/chinese', categoryKey: 'nhentai'));
    expect(find.byType(NhentaiTagStackPage), findsOneWidget);
    expect(requests.last.path, '/language/chinese/');
  });

  testWidgets('stacking opens a page or explains why not', (tester) async {
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            TextButton(
              onPressed: () => openNhentaiTagStack(context, const [chinese],
                  const NhentaiTagTerm('tag', 'glasses')),
              child: const Text('add'),
            ),
            TextButton(
              onPressed: () => openNhentaiTagStack(
                  context, const [chinese, glasses], glasses),
              child: const Text('dup'),
            ),
          ]),
        ),
      ),
    );
    await tester.tap(find.text('dup'));
    await tester.pump();
    expect(find.byType(NhentaiTagStackPage), findsNothing);
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byType(NhentaiTagStackPage), findsOneWidget);
    expect(requests.last.queryParameters['q'], 'language:chinese tag:"glasses"');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('default exclusions page adds and removes tags', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester, const NhentaiDefaultExcludesPage());
    expect(find.text('未设置'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'g');
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'glasses'));
    await tester.pumpAndSettle();
    expect(NhentaiTagSettings.defaultExcludes.toQuery(), '-tag:"glasses"');
    await tester.enterText(find.byType(TextField), 'artist:"some one"');
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    expect(NhentaiTagSettings.defaultExcludes.toQuery(),
        '-tag:"glasses" -artist:"some one"');
    await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, '−glasses'),
        matching: find.byTooltip('移除')));
    await tester.pumpAndSettle();
    expect(NhentaiTagSettings.defaultExcludes.toQuery(), '-artist:"some one"');
    await tester.enterText(find.byType(TextField), 'female:big breasts');
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    expect(NhentaiTagSettings.defaultExcludes.toQuery(),
        '-artist:"some one" -tag:"big breasts"');
  });
}
