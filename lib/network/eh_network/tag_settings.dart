import 'package:flutter/foundation.dart';
import 'package:pica_comic/comic_source/comic_source.dart';

/// e-hentai tag settings, stored in the e-hentai comic source data file.
class EhTagSettings {
  EhTagSettings._();

  static const _stackEnabledKey = 'tagStackEnabled';

  /// Overridable for tests.
  @visibleForTesting
  static Map<String, dynamic>? Function() dataProvider =
      () => ComicSource.find('ehentai')?.data;

  /// Overridable for tests.
  @visibleForTesting
  static Future<void> Function() saver =
      () async => await ComicSource.find('ehentai')?.saveData();

  /// Bumped after every change, so widgets can listen.
  static final changes = ValueNotifier<int>(0);

  /// Whether tapping a tag stacks it onto the tag search the gallery was
  /// opened from. On by default.
  static bool get stackEnabled => dataProvider()?[_stackEnabledKey] != false;

  static Future<void> setStackEnabled(bool value) async {
    var data = dataProvider();
    if (data == null) return;
    data[_stackEnabledKey] = value;
    changes.value++;
    await saver();
  }
}
