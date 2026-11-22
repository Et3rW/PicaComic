import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/translation_tasks.dart';

// A chapter's translation belongs to the app: it goes on after the reader is
// closed, and opening the chapter again follows it instead of starting over.
void main() {
  late TranslationTasks tasks;
  late Completer<void> gate;
  late List<String> translated;

  setUp(() {
    tasks = TranslationTasks();
    gate = Completer<void>();
    translated = [];
  });

  TranslationTask start(String comic, int ep,
          {int pages = 3,
          bool restart = false,
          void Function(TranslationTask)? onFinished}) =>
      tasks.start(
        comicKey: comic,
        ep: ep,
        title: 'Comic $comic',
        chapter: 'Chapter $ep',
        pages: List.generate(pages, (i) => i),
        translatePage: (page) async {
          await gate.future;
          translated.add('$comic/$ep/$page');
          return null;
        },
        restart: restart,
        onFinished: onFinished,
      );

  test('a running chapter is followed, not started again', () async {
    var first = start('a', 1);
    expect(start('a', 1), same(first));
    expect(tasks.find('a', 1), same(first));
    expect(tasks.isTranslating('a'), isTrue);
    expect(tasks.isTranslating('b'), isFalse);
    expect(tasks.runningCount, 1);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    while (first.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(translated, hasLength(3));
    expect(tasks.find('a', 1), isNull);
    // Finished ones stay on the list to show how they went.
    expect(tasks.tasks, [first]);
  });

  test('chapters of several comics go on at once and are told when done',
      () async {
    var done = <String>[];
    var a = start('a', 1, onFinished: (t) => done.add(t.title));
    var b = start('b', 2, onFinished: (t) => done.add(t.title));
    expect(tasks.tasks, [b, a]);
    gate.complete();
    while (a.isRunning || b.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(done.toSet(), {'Comic a', 'Comic b'});
    expect(tasks.runningCount, 0);
    tasks.clearFinished();
    expect(tasks.tasks, isEmpty);
  });

  test('restarting a chapter replaces its task', () async {
    var told = 0;
    var first = start('a', 1, onFinished: (_) => told++);
    var second = start('a', 1, restart: true, onFinished: (_) => told++);
    expect(second, isNot(same(first)));
    expect(first.batch.isCancelled, isTrue);
    expect(tasks.tasks, [second]);
    gate.complete();
    while (first.isRunning || second.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    // Only the task that ran to the end is told about.
    expect(told, 1);
    expect(tasks.tasks, [second]);
  });

  test('cancelling a comic stops all its chapters and nothing else', () async {
    var notified = 0;
    tasks.addListener(() => notified++);
    var a1 = start('a', 1);
    var a2 = start('a', 2);
    var b = start('b', 1);
    tasks.cancelComic('a');
    expect(a1.batch.isCancelled && a2.batch.isCancelled, isTrue);
    expect(b.batch.isCancelled, isFalse);
    expect(tasks.tasks, [b]);
    tasks.cancel(b);
    expect(tasks.tasks, isEmpty);
    expect(notified, greaterThan(0));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // Pages already started finish; no new ones begin.
    expect(translated.length, lessThanOrEqualTo(6));
  });

  test('only the last finished tasks are kept', () async {
    gate.complete();
    for (var i = 0; i < TranslationTasks.keptFinished + 5; i++) {
      var task = start('c$i', 1, pages: 1);
      while (task.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    expect(tasks.tasks, hasLength(TranslationTasks.keptFinished));
    expect(tasks.tasks.first.comicKey, 'c${TranslationTasks.keptFinished + 4}');
  });
}
