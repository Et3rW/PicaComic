import 'package:flutter/foundation.dart';

import 'batch_translation.dart';

/// A chapter being translated in the background. It belongs to the app, not
/// to the reader, so it goes on after the reader is closed.
class TranslationTask {
  TranslationTask._({
    required this.comicKey,
    required this.ep,
    required this.title,
    required this.chapter,
    required this.batch,
    required this.onFinished,
  });

  /// Identifies the comic: its source and id.
  final String comicKey;

  /// The chapter, from 1.
  final int ep;

  /// The comic's name, for the task list.
  final String title;

  /// The chapter's name, if the comic has chapters.
  final String? chapter;

  /// Holds the task's [BatchTranslation.translatePage], so a retry works
  /// after the reader is closed.
  final BatchTranslation batch;

  /// Called each time the task ends by itself, a retry included.
  final void Function(TranslationTask task)? onFinished;

  /// Whether a reader is showing this chapter. Its result is told differently
  /// when nobody is looking at it.
  bool inReader = false;

  bool _waiting = false;

  bool get isRunning => batch.isRunning;

  /// Waiting in the queue of [TranslationTasks.retryAllFailed].
  bool get isWaiting => _waiting;

  /// Running or waiting to run.
  bool get isActive => isRunning || _waiting;

  /// Ended with every page translated.
  bool get isSucceeded => !isActive && !batch.hasFailures;

  /// Ended with pages left untranslated: some failed, or it gave up early.
  bool get isFailed => !isActive && batch.hasFailures;
}

/// Every chapter translation of the app: the running ones and those that
/// finished since the list was last cleared.
class TranslationTasks extends ChangeNotifier {
  TranslationTasks();

  static TranslationTasks instance = TranslationTasks();

  /// Finished tasks are kept to show how they went, up to this many.
  static const keptFinished = 20;

  final _tasks = <TranslationTask>[];

  /// Failed tasks retried one after another, the next first.
  final _queue = <TranslationTask>[];

  /// The task of the queue that is running.
  TranslationTask? _queueCurrent;

  /// Newest first.
  List<TranslationTask> get tasks => List.unmodifiable(_tasks.reversed);

  int get runningCount => _tasks.where((task) => task.isRunning).length;

  /// The running or waiting task of chapter [ep] of [comicKey].
  TranslationTask? find(String comicKey, int ep) {
    for (var task in _tasks) {
      if (task.comicKey == comicKey && task.ep == ep && task.isActive) {
        return task;
      }
    }
    return null;
  }

  /// Whether any chapter of [comicKey] is being translated.
  bool isTranslating(String comicKey) =>
      _tasks.any((task) => task.comicKey == comicKey && task.isActive);

  /// Translates [pages] of chapter [ep], one by one with [translatePage].
  /// When that chapter is already being translated, its task is returned
  /// and nothing new starts, unless [restart] asks to begin again (after the
  /// settings changed, say). A task of that chapter waiting in the queue
  /// starts now. [onFinished] is called when it ends by itself, not when it
  /// is cancelled.
  TranslationTask start({
    required String comicKey,
    required int ep,
    required String title,
    String? chapter,
    required List<int> pages,
    required Future<String?> Function(int page) translatePage,
    bool restart = false,
    void Function(TranslationTask task)? onFinished,
  }) {
    var active = find(comicKey, ep);
    if (active != null) {
      if (!restart) {
        if (active.isWaiting) {
          // Someone is reading it: it does not wait for the others.
          _unqueue(active);
          _run(active);
          notifyListeners();
        }
        return active;
      }
      active.batch.cancel();
    }
    for (var task in List.of(_tasks)) {
      if (task.comicKey == comicKey && task.ep == ep) _remove(task);
    }
    var task = TranslationTask._(
      comicKey: comicKey,
      ep: ep,
      title: title,
      chapter: chapter,
      batch: BatchTranslation(pages: pages, translatePage: translatePage),
      onFinished: onFinished,
    );
    _tasks.add(task);
    task.batch.addListener(notifyListeners);
    _dropOldFinished();
    _run(task);
    notifyListeners();
    return task;
  }

  /// Translates again the pages of [task] that are not translated: the
  /// failed ones and those never tried. It keeps its place on the list.
  void retry(TranslationTask task) {
    if (!_canRetry(task)) return;
    _run(task);
    notifyListeners();
  }

  /// Retries every failed task, one chapter at a time, in the order of
  /// [tasks]. The others wait in a queue.
  void retryAllFailed() {
    for (var task in tasks) {
      if (_canRetry(task)) {
        task._waiting = true;
        _queue.add(task);
      }
    }
    _runNextQueued();
    notifyListeners();
  }

  /// Stops [task]; pages being translated still finish and are kept. It is
  /// taken off the list, and out of the queue if it was waiting.
  void cancel(TranslationTask task) {
    task.batch.cancel();
    _remove(task);
    notifyListeners();
  }

  /// Stops every chapter of [comicKey].
  void cancelComic(String comicKey) {
    for (var task in List.of(_tasks)) {
      if (task.comicKey == comicKey) {
        task.batch.cancel();
        _remove(task);
      }
    }
    notifyListeners();
  }

  /// Takes the finished tasks off the list; running and waiting ones stay.
  void clearFinished() {
    for (var task in List.of(_tasks)) {
      if (!task.isActive) _remove(task);
    }
    notifyListeners();
  }

  bool _canRetry(TranslationTask task) =>
      _tasks.contains(task) && task.isFailed && !task.batch.isCancelled;

  void _run(TranslationTask task, {void Function()? then}) {
    task.batch.run().then((_) {
      _dropOldFinished();
      notifyListeners();
      if (!task.batch.isCancelled) task.onFinished?.call(task);
      then?.call();
    });
  }

  /// Starts the next waiting task once the one before has ended.
  void _runNextQueued() {
    if (_queueCurrent != null) return;
    while (_queue.isNotEmpty) {
      var task = _queue.removeAt(0);
      task._waiting = false;
      if (task.isRunning || !_canRetry(task)) continue;
      _queueCurrent = task;
      _run(task, then: () {
        if (_queueCurrent == task) _queueCurrent = null;
        _runNextQueued();
        notifyListeners();
      });
      return;
    }
  }

  void _unqueue(TranslationTask task) {
    task._waiting = false;
    _queue.remove(task);
  }

  void _remove(TranslationTask task) {
    _unqueue(task);
    if (_tasks.remove(task)) task.batch.removeListener(notifyListeners);
  }

  void _dropOldFinished() {
    var finished = _tasks.where((task) => !task.isActive).toList();
    for (var i = 0; i < finished.length - keptFinished; i++) {
      _remove(finished[i]);
    }
  }
}
