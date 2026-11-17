import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';

import 'model_store.dart';
import 'ocr_engine.dart';
import 'ocr_types.dart';
import 'ort.dart';
import 'page_renderer.dart';
import 'translation_settings.dart';
import 'translation_store.dart';
import 'translator.dart';

/// What happened to a page that was asked to be translated.
enum PageTranslationState {
  working,

  /// The translated page is shown.
  done,

  /// Nothing to translate: no text, or it is already in the target language.
  noText,

  /// The original is shown; [PageTranslationStatus.message] says why.
  failed,
}

class PageTranslationStatus {
  const PageTranslationStatus(this.state, [this.message]);

  final PageTranslationState state;
  final String? message;
}

/// Why page translation cannot run at all right now.
enum TranslationProblem {
  /// No model runtime on this platform.
  unsupported,
  modelsMissing,
  noProvider,
}

/// Text read by OCR is in this script. Used to skip text that is already in
/// the target language.
enum TextScript { chinese, japanese, korean, latin, other }

/// The script [text] is written in: kana makes it Japanese even among kanji,
/// Hangul makes it Korean, Han characters alone are Chinese.
TextScript scriptOf(String text) {
  var han = 0, kana = 0, hangul = 0, latin = 0;
  for (var rune in text.runes) {
    if ((rune >= 0x3040 && rune <= 0x30FF) || (rune >= 0x31F0 && rune <= 0x31FF)) {
      kana++;
    } else if ((rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x3130 && rune <= 0x318F)) {
      hangul++;
    } else if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF)) {
      han++;
    } else if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    }
  }
  if (kana > 0) return TextScript.japanese;
  if (hangul > 0) return TextScript.korean;
  if (han > 0) return TextScript.chinese;
  if (latin > 0) return TextScript.latin;
  return TextScript.other;
}

/// Whether [text] is already in [target] as far as its script tells. Latin
/// text counts as English only; other Latin-script languages are translated.
bool alreadyIn(String text, TargetLanguage target) {
  var script = scriptOf(text);
  return switch (target.code) {
    'zh' || 'zh-TW' => script == TextScript.chinese,
    'ja' => script == TextScript.japanese,
    'ko' => script == TextScript.korean,
    _ => false,
  };
}

/// Translates reader pages: OCR on the device, the text through the chosen
/// service, the result drawn over the page. Results are kept, so a page is
/// recognized and translated once per target language.
class PageTranslationService extends ChangeNotifier {
  PageTranslationService({
    required this.settings,
    required this.models,
    required this.store,
    this.readText = _readWithWorker,
  });

  static PageTranslationService? _instance;

  static PageTranslationService get instance =>
      _instance ??= PageTranslationService(
        settings: TranslationSettings.instance,
        models: ModelStore.instance,
        store: TranslationStore('${App.dataPath}/page_translation.db'),
      );

  @visibleForTesting
  static set instance(PageTranslationService value) => _instance = value;

  final TranslationSettings settings;
  final ModelStore models;
  final TranslationStore store;

  /// Reads the text blocks of a decoded page. Replaced in tests, where no
  /// model runtime is available.
  final Future<List<OcrBlock>> Function(DecodedPage page, OcrModelPaths paths)
      readText;

  static Future<List<OcrBlock>> _readWithWorker(
          DecodedPage page, OcrModelPaths paths) =>
      OcrWorker.instance.read(page.rgba, paths);

  /// Rendered pages are a cache of what [store] holds.
  static const _renderedLifetime = 30 * 24 * 60 * 60 * 1000;

  final _statuses = <String, PageTranslationStatus>{};
  final _running = <String, Future<Uint8List>>{};

  static bool? _supported;

  /// Whether a model runtime can be loaded on this device.
  static bool get isSupported => _supported ??= OrtRuntime.isAvailable;

  /// Tests have no runtime and supply the recognized text themselves.
  @visibleForTesting
  static set isSupported(bool value) => _supported = value;

  /// What has to be set up before pages can be translated, if anything.
  TranslationProblem? get problem {
    if (!isSupported) return TranslationProblem.unsupported;
    if (!models.isInstalled) return TranslationProblem.modelsMissing;
    var provider = settings.activeProvider;
    if (provider == null || !provider.isUsable) {
      return TranslationProblem.noProvider;
    }
    return null;
  }

  /// Key of a page's translation, in [store] and in the image cache. The
  /// target language is part of it: another language is another translation.
  String keyFor(String pageKey) =>
      'pageTranslation@1@${settings.target.code}@$pageKey';

  PageTranslationStatus? statusOf(String pageKey) => _statuses[keyFor(pageKey)];

  /// Pages of the current reading session that failed, by page key.
  bool get hasFailures => _statuses.values
      .any((status) => status.state == PageTranslationState.failed);

  void _setStatus(String key, PageTranslationStatus status) {
    _statuses[key] = status;
    notifyListeners();
  }

  /// Forgets the statuses of a finished reading session.
  void clearStatuses() {
    _statuses.clear();
  }

  /// Passes [source] through and replaces its final image with the translated
  /// page. A page that cannot be translated is shown as it is.
  Stream<DownloadProgress> wrap(
      Stream<DownloadProgress> source, String pageKey) async* {
    DownloadProgress? last;
    await for (var progress in source) {
      if (progress.finished) {
        last = progress;
      } else {
        yield progress;
      }
    }
    if (last == null) return;
    var original = last.data ?? await last.getFile().readAsBytes();
    // The image is here; what remains is the translation.
    yield DownloadProgress(
        original.length, original.length + 1, last.url, last.savePath);
    Uint8List shown;
    try {
      shown = await translate(original, pageKey);
    } catch (e, s) {
      var message = e is TranslationException ? e.message : '$e';
      Log.error('Page Translation', '$e\n$s');
      _setStatus(keyFor(pageKey),
          PageTranslationStatus(PageTranslationState.failed, message));
      shown = original;
    }
    yield DownloadProgress(
        shown.length, shown.length, last.url, last.savePath, shown, last.ext);
  }

  /// Loads a page from [source] and translates it without showing it, so it
  /// is ready when the reader gets there. Returns null when the page is done
  /// or has nothing to translate, otherwise why it failed.
  Future<String?> translateInBackground(
      Stream<DownloadProgress> source, String pageKey) async {
    // Already drawn: nothing to load or pay for.
    if (await CacheManager().findCache(keyFor(pageKey)) != null) return null;
    try {
      await for (var _ in wrap(source, pageKey)) {}
    } catch (e) {
      // The image itself could not be loaded.
      return '$e';
    }
    var status = statusOf(pageKey);
    return switch (status?.state) {
      PageTranslationState.done || PageTranslationState.noText => null,
      PageTranslationState.failed => status!.message ?? '',
      _ => 'The image did not finish loading',
    };
  }

  /// The translated version of the page image [original], or [original]
  /// itself when there is nothing to translate.
  Future<Uint8List> translate(Uint8List original, String pageKey) {
    var key = keyFor(pageKey);
    return _running[key] ??= _translate(original, key).whenComplete(() {
      _running.remove(key);
    });
  }

  Future<Uint8List> _translate(Uint8List original, String key) async {
    var rendered = await CacheManager().findCache(key);
    if (rendered != null) {
      _setStatus(key, const PageTranslationStatus(PageTranslationState.done));
      return File(rendered).readAsBytes();
    }
    _setStatus(key, const PageTranslationStatus(PageTranslationState.working));

    var page = await decodePage(original);
    try {
      var stored = store.get(key);
      if (stored == null) {
        stored = await _recognizeAndTranslate(page);
        store.put(key, stored);
      }
      if (stored.blocks.isEmpty) {
        _setStatus(
            key, const PageTranslationStatus(PageTranslationState.noText));
        return original;
      }
      var bytes = await renderTranslatedPage(
          page.image, _scaled(stored, page.image.width, page.image.height));
      await CacheManager().writeCache(key, bytes, _renderedLifetime);
      _setStatus(key, const PageTranslationStatus(PageTranslationState.done));
      return bytes;
    } finally {
      page.dispose();
    }
  }

  Future<StoredPage> _recognizeAndTranslate(DecodedPage page) async {
    var problem = this.problem;
    if (problem != null) {
      throw TranslationException(TranslationFailure.other, problem.name);
    }
    var width = page.image.width, height = page.image.height;
    var target = settings.target;
    var blocks = [
      for (var block in await readText(page, models.paths))
        if (!alreadyIn(block.text, target)) block,
    ];
    if (blocks.isEmpty) return StoredPage(width, height, const []);

    var translations = await _limit(() =>
        Translator(settings.activeProvider!, systemPrompt: settings.prompt)
            .translate([for (var block in blocks) block.text], target));
    return StoredPage(width, height, [
      for (var i = 0; i < blocks.length; i++)
        // A model may hand a line back unchanged; that needs no plate.
        if (translations[i].isNotEmpty && translations[i] != blocks[i].text)
          TranslatedBlock(
            rect: blocks[i].rect,
            lineRects: blocks[i].lineRects,
            original: blocks[i].text,
            translation: translations[i],
            vertical: blocks[i].vertical,
            background: blocks[i].background,
            foreground: blocks[i].foreground,
          ),
    ]);
  }

  /// [stored]'s blocks in the coordinates of a [width] x [height] page, in
  /// case the page was decoded at another size than when it was recognized.
  static List<TranslatedBlock> _scaled(StoredPage stored, int width, int height) {
    if (stored.width == width && stored.height == height) return stored.blocks;
    var sx = width / stored.width, sy = height / stored.height;
    PixelRect scale(PixelRect rect) => rect.scaled(sx, sy);
    return [
      for (var block in stored.blocks)
        TranslatedBlock(
          rect: scale(block.rect),
          lineRects: [for (var line in block.lineRects) scale(line)],
          original: block.original,
          translation: block.translation,
          vertical: block.vertical,
          background: block.background,
          foreground: block.foreground,
        ),
    ];
  }

  // At most two translation requests at a time, so flipping quickly through
  // a chapter does not trip a service's rate limit.
  var _active = 0;
  final _waiting = <Completer<void>>[];

  Future<T> _limit<T>(Future<T> Function() request) async {
    while (_active >= 2) {
      var turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _active++;
    try {
      return await request();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  /// Drops a page's translation so that it is recognized and translated again
  /// the next time it is shown.
  Future<void> forget(String pageKey) async {
    var key = keyFor(pageKey);
    store.remove(key);
    await CacheManager().delete(key);
    _statuses.remove(key);
    notifyListeners();
  }

  /// Drops every stored translation. Rendered pages still in the image cache
  /// expire on their own.
  void clearAll() {
    store.clear();
    _statuses.clear();
    notifyListeners();
  }
}
