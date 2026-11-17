import 'package:flutter/foundation.dart';

/// Translates every page of a chapter in the background, a few at a time,
/// starting from the page being read.
///
/// [translatePage] translates one page and returns null when it is done
/// (or has nothing to translate), or why it failed.
class BatchTranslation extends ChangeNotifier {
  BatchTranslation({
    required this.pages,
    required this.translatePage,
    this.parallel = 2,
    this.stopAfterFailures = 3,
  });

  /// Pages in the order they are translated.
  final List<int> pages;

  final Future<String?> Function(int page) translatePage;

  /// Pages worked on at the same time.
  final int parallel;

  /// Consecutive failures after which the rest is given up: a wrong key or
  /// an exhausted quota would fail every page the same way.
  final int stopAfterFailures;

  var _finished = 0;
  var _failed = 0;
  var _failuresInARow = 0;
  var _cancelled = false;
  var _running = false;
  String? _stopReason;

  /// Pages done or failed so far.
  int get finished => _finished;

  int get failed => _failed;

  int get total => pages.length;

  bool get isRunning => _running;

  bool get isCancelled => _cancelled;

  /// Why the batch gave up early, if it did.
  String? get stopReason => _stopReason;

  /// [count] pages in reading order from [start], then the ones before it.
  static List<int> orderFrom(int count, int start) {
    if (count <= 0) return const [];
    start = start.clamp(0, count - 1);
    return [
      for (var i = start; i < count; i++) i,
      for (var i = 0; i < start; i++) i,
    ];
  }

  /// Runs until every page is done, the batch is cancelled or it gives up.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled && _stopReason == null && next < pages.length) {
        var page = pages[next++];
        String? error;
        try {
          error = await translatePage(page);
        } catch (e) {
          error = '$e';
        }
        if (_cancelled) return;
        _finished++;
        if (error == null) {
          _failuresInARow = 0;
        } else {
          _failed++;
          if (++_failuresInARow >= stopAfterFailures) _stopReason = error;
        }
        notifyListeners();
      }
    }

    await Future.wait([
      for (var i = 0; i < parallel; i++) worker(),
    ]);
    _running = false;
    notifyListeners();
  }

  /// Stops starting new pages. Pages already being translated still finish
  /// and are kept.
  void cancel() {
    _cancelled = true;
  }
}
