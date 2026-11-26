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

  group('filters and retry', () {
    /// Pages of each chapter that fail, by '$comic/$ep'.
    late Map<String, Set<int>> failing;

    /// Pages asked for, as '$comic/$ep/$page', in order.
    late List<String> asked;

    /// Pages held back until it completes, by '$comic/$ep'.
    late Map<String, Completer<void>> holds;

    setUp(() {
      failing = {};
      asked = [];
      holds = {};
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 2000 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(done(), isTrue);
    }

    TranslationTask run(String comic, int ep,
            {int pages = 4, void Function(TranslationTask)? onFinished}) =>
        tasks.start(
          comicKey: comic,
          ep: ep,
          title: 'Comic $comic',
          pages: List.generate(pages, (i) => i),
          translatePage: (page) async {
            var id = '$comic/$ep';
            asked.add('$id/$page');
            await holds[id]?.future;
            return failing[id]?.contains(page) == true ? 'failed' : null;
          },
          onFinished: onFinished,
        );

    test('tasks are running, succeeded or failed', () async {
      failing['b/1'] = {2};
      // Three failures in a row: the rest is given up.
      failing['c/1'] = {0, 1, 2, 3, 4, 5};
      holds['d/1'] = Completer();
      var a = run('a', 1);
      var b = run('b', 1);
      var c = run('c', 1, pages: 6);
      var d = run('d', 1);
      await until(() => !a.isRunning && !b.isRunning && !c.isRunning);
      expect(d.isActive && !d.isSucceeded && !d.isFailed, isTrue);
      expect(a.isSucceeded && !a.isFailed, isTrue);
      expect(b.isFailed && !b.isSucceeded, isTrue);
      expect(b.batch.failedPages, {2});
      expect(c.isFailed, isTrue);
      expect(c.batch.stopReason, 'failed');
      expect(c.batch.untriedPages, isNotEmpty);
      holds['d/1']!.complete();
      await until(() => !d.isRunning);
      expect(d.isSucceeded, isTrue);
    });

    test('a retry asks only for the pages not translated, in place', () async {
      var told = <String>[];
      failing['a/1'] = {1, 2, 3, 4, 5};
      var a = run('a', 1,
          pages: 6,
          onFinished: (t) => told
              .add('${t.batch.succeeded}/${t.batch.total} ${t.batch.failed}'));
      var b = run('b', 1);
      await until(() => !a.isRunning && !b.isRunning);
      expect(told, ['1/6 4']);
      // Page 0 was translated, two pages at a time failed until it gave up,
      // and page 5 was never tried.
      expect(a.batch.failedPages, {1, 2, 3, 4});
      expect(a.batch.untriedPages, [5]);
      expect(tasks.tasks, [b, a]);
      asked.clear();
      failing['a/1'] = {};
      holds['a/1'] = Completer();
      tasks.retry(a);
      expect(a.isActive, isTrue);
      expect(a.isFailed, isFalse);
      // Retrying it again while it runs starts nothing more.
      tasks.retry(a);
      holds['a/1']!.complete();
      await until(() => !a.isRunning);
      expect(asked.toSet(), {'a/1/1', 'a/1/2', 'a/1/3', 'a/1/4', 'a/1/5'});
      expect(asked, hasLength(5));
      expect(a.isSucceeded, isTrue);
      expect(a.batch.succeeded, 6);
      expect(tasks.tasks, [b, a]);
      // The result is told again, counting the pages translated before.
      expect(told, ['1/6 4', '6/6 0']);
      // A task that did not fail is not retried.
      tasks.retry(b);
      expect(b.isRunning, isFalse);
    });

    test('retrying every failed task goes one chapter at a time', () async {
      for (var c in ['a', 'b', 'c']) {
        failing['$c/1'] = {0};
      }
      var done = <String>[];
      var a = run('a', 1, pages: 2, onFinished: (t) => done.add(t.comicKey));
      var b = run('b', 1, pages: 2, onFinished: (t) => done.add(t.comicKey));
      var ok = run('ok', 1, pages: 2);
      var c = run('c', 1, pages: 2, onFinished: (t) => done.add(t.comicKey));
      await until(() => tasks.runningCount == 0);
      expect([a, b, c].every((t) => t.isFailed), isTrue);
      done.clear();
      asked.clear();
      failing.clear();
      for (var t in ['a', 'b', 'c']) {
        holds['$t/1'] = Completer();
      }
      tasks.retryAllFailed();
      // Newest first, as the list shows them.
      expect(c.isRunning, isTrue);
      expect(b.isWaiting && a.isWaiting, isTrue);
      expect(b.isActive && !b.isFailed, isTrue);
      expect(ok.isActive, isFalse);
      expect(tasks.runningCount, 1);
      // Pressing it again does not queue or start any of them twice.
      tasks.retryAllFailed();
      holds['c/1']!.complete();
      await until(() => !c.isRunning && b.isRunning);
      expect(a.isWaiting, isTrue);
      expect(tasks.runningCount, 1);
      holds['b/1']!.complete();
      await until(() => !b.isRunning && a.isRunning);
      holds['a/1']!.complete();
      await until(() => tasks.runningCount == 0);
      expect(done, ['c', 'b', 'a']);
      expect(asked, ['c/1/0', 'b/1/0', 'a/1/0']);
      expect([a, b, c, ok].every((t) => t.isSucceeded), isTrue);
      expect(tasks.tasks, [c, ok, b, a]);
    });

    test('a waiting task can be cancelled, and clearing keeps it', () async {
      for (var c in ['a', 'b', 'c']) {
        failing['$c/1'] = {0};
      }
      var a = run('a', 1, pages: 1);
      var b = run('b', 1, pages: 1);
      var c = run('c', 1, pages: 1);
      var ok = run('ok', 1, pages: 1);
      await until(() => tasks.runningCount == 0);
      failing.clear();
      asked.clear();
      holds['c/1'] = Completer();
      tasks.retryAllFailed();
      expect(c.isRunning && b.isWaiting && a.isWaiting, isTrue);
      tasks.clearFinished();
      // Only the finished one goes; the running and waiting ones stay.
      expect(tasks.tasks, [c, b, a]);
      tasks.cancel(b);
      expect(b.isWaiting, isFalse);
      expect(tasks.tasks, [c, a]);
      holds['c/1']!.complete();
      await until(() => tasks.runningCount == 0 && !a.isWaiting);
      expect(asked, ['c/1/0', 'a/1/0']);
      expect(ok.isSucceeded, isTrue);
    });

    test('opening a waiting chapter starts it at once', () async {
      failing['a/1'] = {0};
      failing['b/1'] = {0};
      var a = run('a', 1, pages: 1);
      var b = run('b', 1, pages: 1);
      await until(() => tasks.runningCount == 0);
      failing.clear();
      holds['b/1'] = Completer();
      tasks.retryAllFailed();
      expect(b.isRunning && a.isWaiting, isTrue);
      expect(tasks.find('a', 1), same(a));
      expect(tasks.isTranslating('a'), isTrue);
      expect(run('a', 1, pages: 1), same(a));
      expect(a.isRunning && !a.isWaiting, isTrue);
      await until(() => !a.isRunning);
      holds['b/1']!.complete();
      await until(() => tasks.runningCount == 0);
      expect(a.isSucceeded && b.isSucceeded, isTrue);
    });

    test('waiting tasks do not count as finished ones to drop', () async {
      for (var i = 0; i < 3; i++) {
        failing['f$i/1'] = {0};
        var task = run('f$i', 1, pages: 1);
        await until(() => !task.isRunning);
      }
      failing.clear();
      holds['f2/1'] = Completer();
      tasks.retryAllFailed();
      for (var i = 0; i < TranslationTasks.keptFinished + 3; i++) {
        var task = run('s$i', 1, pages: 1);
        await until(() => !task.isRunning);
      }
      var keys = tasks.tasks.map((t) => t.comicKey).toList();
      expect(keys, containsAll(['f0', 'f1', 'f2']));
      expect(tasks.tasks.where((t) => !t.isActive),
          hasLength(TranslationTasks.keptFinished));
      holds['f2/1']!.complete();
      await until(() =>
          tasks.runningCount == 0 && !tasks.tasks.any((t) => t.isWaiting));
    });
  });
}
