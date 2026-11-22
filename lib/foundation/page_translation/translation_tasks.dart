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
  });

  /// Identifies the comic: its source and id.
  final String comicKey;

  /// The chapter, from 1.
  final int ep;

  /// The comic's name, for the task list.
  final String title;

  /// The chapter's name, if the comic has chapters.
  final String? chapter;

  final BatchTranslation batch;

  /// Whether a reader is showing this chapter. Its result is told differently
  /// when nobody is looking at it.
  bool inReader = false;

  bool get isRunning => batch.isRunning;
}

/// Every chapter translation of the app: the running ones and those that
/// finished since the list was last cleared.
class TranslationTasks extends ChangeNotifier {
  TranslationTasks();

  static TranslationTasks instance = TranslationTasks();

  /// Finished tasks are kept to show how they went, up to this many.
  static const keptFinished = 20;

  final _tasks = <TranslationTask>[];

  /// Newest first.
  List<TranslationTask> get tasks => List.unmodifiable(_tasks.reversed);

  int get runningCount => _tasks.where((task) => task.isRunning).length;

  /// The running task of chapter [ep] of [comicKey].
  TranslationTask? find(String comicKey, int ep) {
    for (var task in _tasks) {
      if (task.comicKey == comicKey && task.ep == ep && task.isRunning) {
        return task;
      }
    }
    return null;
  }

  /// Whether any chapter of [comicKey] is being translated.
  bool isTranslating(String comicKey) =>
      _tasks.any((task) => task.comicKey == comicKey && task.isRunning);

  /// Translates [pages] of chapter [ep], one by one with [translatePage].
  /// When that chapter is already being translated, its task is returned
  /// and nothing new starts, unless [restart] asks to begin again (after the
  /// settings changed, say). [onFinished] is called when it ends by itself,
  /// not when it is cancelled.
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
    var running = find(comicKey, ep);
    if (running != null) {
      if (!restart) return running;
      running.batch.cancel();
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
    );
    _tasks.add(task);
    task.batch.addListener(notifyListeners);
    _dropOldFinished();
    task.batch.run().then((_) {
      _dropOldFinished();
      notifyListeners();
      if (!task.batch.isCancelled) onFinished?.call(task);
    });
    notifyListeners();
    return task;
  }

  /// Stops [task]; pages being translated still finish and are kept. It is
  /// taken off the list.
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

  /// Takes the finished tasks off the list.
  void clearFinished() {
    for (var task in List.of(_tasks)) {
      if (!task.isRunning) _remove(task);
    }
    notifyListeners();
  }

  void _remove(TranslationTask task) {
    if (_tasks.remove(task)) task.batch.removeListener(notifyListeners);
  }

  void _dropOldFinished() {
    var finished = _tasks.where((task) => !task.isRunning).toList();
    for (var i = 0; i < finished.length - keptFinished; i++) {
      _remove(finished[i]);
    }
  }
}
