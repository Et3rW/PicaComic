import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/translation_tasks.dart';
import 'package:pica_comic/pages/settings/translation_tasks_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  late TranslationTasks saved;
  late TranslationTasks tasks;
  late Completer<void> hold;

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    saved = TranslationTasks.instance;
    tasks = TranslationTasks.instance = TranslationTasks();
    hold = Completer();
  });

  tearDown(() {
    if (!hold.isCompleted) hold.complete();
    TranslationTasks.instance = saved;
  });

  /// Comics whose pages wait for [hold].
  late Set<String> held;

  /// Pages that fail, by comic.
  late Map<String, Set<int>> failing;

  setUp(() {
    held = {};
    failing = {};
  });

  /// A chapter of [pages] pages.
  TranslationTask add(String comic, {int pages = 3}) => tasks.start(
        comicKey: comic,
        ep: 1,
        title: 'Comic $comic',
        pages: List.generate(pages, (i) => i),
        translatePage: (page) async {
          if (held.contains(comic)) await hold.future;
          return failing[comic]?.contains(page) == true ? 'failed' : null;
        },
      );

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  testWidgets('filters count the tasks and failed ones can be retried',
      (tester) async {
    failing['bad'] = {1};
    failing['stopped'] = {0, 1, 2, 3, 4};
    held.add('busy');
    add('ok');
    add('bad');
    add('stopped', pages: 5);
    add('busy');
    await tester.pumpWidget(const MaterialApp(home: TranslationTasksPage()));
    await tester.pump();

    expect(chip('全部 (4)'), findsOneWidget);
    expect(chip('进行中 (1)'), findsOneWidget);
    expect(chip('成功 (1)'), findsOneWidget);
    expect(chip('失败 (2)'), findsOneWidget);
    expect(find.text('已完成  成功 3/3'), findsOneWidget);
    expect(find.text('正在翻译  成功 0/3'), findsOneWidget);
    expect(find.textContaining('成功 2/3, 失败: 1'), findsOneWidget);
    expect(find.textContaining('翻译连续失败, 已停止: failed'), findsOneWidget);
    // Only the failed tasks have a retry button; the page has retry-all.
    expect(find.byTooltip('重试'), findsNWidgets(2));
    expect(find.byTooltip('重试所有失败'), findsOneWidget);

    await tester.tap(chip('失败 (2)'));
    await tester.pump();
    expect(find.text('Comic bad'), findsOneWidget);
    expect(find.text('Comic stopped'), findsOneWidget);
    expect(find.text('Comic ok'), findsNothing);
    expect(find.text('Comic busy'), findsNothing);

    await tester.tap(chip('进行中 (1)'));
    await tester.pump();
    expect(find.text('Comic busy'), findsOneWidget);
    expect(find.text('Comic ok'), findsNothing);

    await tester.tap(chip('成功 (1)'));
    await tester.pump();
    expect(find.text('Comic ok'), findsOneWidget);
    expect(find.text('Comic bad'), findsNothing);
  });

  testWidgets('retrying all failed tasks shows them in progress',
      (tester) async {
    failing['a'] = {0};
    failing['b'] = {0};
    add('a');
    add('b');
    await tester.pumpWidget(const MaterialApp(home: TranslationTasksPage()));
    await tester.pump();
    expect(chip('失败 (2)'), findsOneWidget);

    failing.clear();
    held.addAll(['a', 'b']);
    // Made in the test's zone, so that pumping runs what waits for it.
    hold = Completer();
    await tester.tap(find.byTooltip('重试所有失败'));
    await tester.pump();
    expect(chip('进行中 (2)'), findsOneWidget);
    expect(chip('失败 (0)'), findsOneWidget);
    expect(find.byTooltip('重试所有失败'), findsNothing);
    expect(find.byTooltip('重试'), findsNothing);
    // The newest goes first; the other waits.
    expect(find.text('正在翻译  成功 2/3'), findsOneWidget);
    expect(find.text('等待中  成功 2/3, 失败: 1'), findsOneWidget);
    // Clearing finished tasks keeps them both.
    expect(find.byTooltip('清除已完成'), findsNothing);

    hold.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(chip('成功 (2)'), findsOneWidget);
    expect(find.text('已完成  成功 3/3'), findsNWidgets(2));
  });

  testWidgets('a filter with no task says so, and retry-all is hidden',
      (tester) async {
    add('ok');
    await tester.pumpWidget(const MaterialApp(home: TranslationTasksPage()));
    await tester.pump();
    expect(chip('全部 (1)'), findsOneWidget);
    expect(chip('失败 (0)'), findsOneWidget);
    expect(find.byTooltip('重试'), findsNothing);
    expect(find.byTooltip('重试所有失败'), findsNothing);

    await tester.tap(chip('失败 (0)'));
    await tester.pump();
    expect(find.text('没有失败的任务'), findsOneWidget);
    await tester.tap(chip('进行中 (0)'));
    await tester.pump();
    expect(find.text('没有进行中的任务'), findsOneWidget);
    await tester.tap(chip('成功 (1)'));
    await tester.pump();
    expect(find.text('Comic ok'), findsOneWidget);
  });
}
