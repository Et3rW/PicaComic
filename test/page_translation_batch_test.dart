import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/batch_translation.dart';

void main() {
  test('pages go from the one being read to the end, then the ones before', () {
    expect(BatchTranslation.orderFrom(5, 2), [2, 3, 4, 0, 1]);
    expect(BatchTranslation.orderFrom(3, 0), [0, 1, 2]);
    // The reader's index can be out of range while a chapter loads.
    expect(BatchTranslation.orderFrom(3, -1), [0, 1, 2]);
    expect(BatchTranslation.orderFrom(3, 9), [2, 0, 1]);
    expect(BatchTranslation.orderFrom(0, 0), isEmpty);
  });

  test('every page is translated, two at a time', () async {
    var active = 0, most = 0;
    var seen = <int>[];
    var batch = BatchTranslation(
      pages: BatchTranslation.orderFrom(6, 3),
      translatePage: (page) async {
        active++;
        most = active > most ? active : most;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        seen.add(page);
        active--;
        return null;
      },
    );
    await batch.run();
    expect(seen.toSet(), {0, 1, 2, 3, 4, 5});
    expect(seen.take(2).toSet(), {3, 4});
    expect(most, 2);
    expect(batch.finished, 6);
    expect(batch.failed, 0);
    expect(batch.stopReason, isNull);
    expect(batch.isRunning, isFalse);
  });

  test('a failing page is counted and the rest go on', () async {
    var batch = BatchTranslation(
      pages: [0, 1, 2, 3],
      parallel: 1,
      translatePage: (page) async => page == 1 ? 'no text service' : null,
    );
    await batch.run();
    expect(batch.finished, 4);
    expect(batch.failed, 1);
    expect(batch.stopReason, isNull);
  });

  test('it gives up after failures in a row, and says why', () async {
    var tried = <int>[];
    var batch = BatchTranslation(
      pages: List.generate(10, (i) => i),
      parallel: 1,
      translatePage: (page) async {
        tried.add(page);
        if (page == 0) return null;
        if (page == 1) throw Exception('connection reset');
        return 'wrong key';
      },
    );
    await batch.run();
    expect(tried, [0, 1, 2, 3]);
    expect(batch.failed, 3);
    expect(batch.stopReason, 'wrong key');
  });

  test('cancelling starts no more pages', () async {
    var started = <int>[];
    var gate = Completer<void>();
    late BatchTranslation batch;
    batch = BatchTranslation(
      pages: List.generate(10, (i) => i),
      translatePage: (page) async {
        started.add(page);
        await gate.future;
        return null;
      },
    );
    var running = batch.run();
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1]);
    batch.cancel();
    gate.complete();
    await running;
    expect(started, [0, 1]);
    expect(batch.isCancelled, isTrue);
    expect(batch.isRunning, isFalse);
  });
}
