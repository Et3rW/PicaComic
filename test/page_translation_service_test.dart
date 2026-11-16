import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/page_translation/model_store.dart';
import 'package:pica_comic/foundation/page_translation/ocr_engine.dart';
import 'package:pica_comic/foundation/page_translation/ocr_types.dart';
import 'package:pica_comic/foundation/page_translation/page_renderer.dart';
import 'package:pica_comic/foundation/page_translation/page_translation_service.dart';
import 'package:pica_comic/foundation/page_translation/translation_settings.dart';
import 'package:pica_comic/foundation/page_translation/translation_store.dart';
import 'package:pica_comic/foundation/page_translation/translator.dart';

import 'support/fake_http.dart';

class _InstalledModels extends ModelStore {
  _InstalledModels(super.directory);

  bool installed = true;

  @override
  bool get isInstalled => installed;
}

// The whole path of one page except the models: the recognized text is
// supplied by the test, the translation service is faked, decoding and
// drawing are real.
void main() {
  final http = useFakeHttp();
  late Directory root;
  late TranslationSettings settings;
  late _InstalledModels models;
  late PageTranslationService service;
  late List<OcrBlock> recognized;
  var ocrRuns = 0;
  final page = File('test/fixtures/page_translation/sample_page.png')
      .readAsBytesSync();

  OcrBlock block(List<int> rect, String text, {bool vertical = false}) =>
      OcrBlock(
        rect: PixelRect.fromList(rect),
        lineRects: [PixelRect.fromList(rect)],
        text: text,
        vertical: vertical,
        background: 0xFFFFFF,
        foreground: 0x0A0A0A,
      );

  void answerWith(List<String> translations) {
    http.text('llm.example/v1/chat/completions', jsonEncode({
      'choices': [
        {
          'message': {
            'content': jsonEncode({'translations': translations}),
          },
        },
      ],
    }));
  }

  int requests() =>
      http.urls.where((url) => url.contains('llm.example')).length;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pica_translation_test');
    settings = TranslationSettings(File('${root.path}/settings.json'))
      ..saveProvider(const TranslatorProvider(
        id: 'p1',
        name: 'test',
        kind: TranslatorKind.openai,
        url: 'https://llm.example/v1',
        key: 'k',
        model: 'm',
      ));
    models = _InstalledModels('${root.path}/models');
    recognized = [
      block([119, 130, 385, 212], 'WHAT ARE YOU DOING HERE?'),
      block([441, 421, 669, 515], '今天天气真好我们去散步吧'),
      block([490, 730, 730, 756], 'LATER THAT DAY'),
    ];
    ocrRuns = 0;
    PageTranslationService.isSupported = true;
    service = PageTranslationService(
      settings: settings,
      models: models,
      store: TranslationStore('${root.path}/store.db'),
      readText: (page, paths) async {
        ocrRuns++;
        return recognized;
      },
    );
  });

  tearDown(() {
    service.store.close();
    root.deleteSync(recursive: true);
  });

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    return (await codec.getNextFrame()).image;
  }

  test('a page is recognized, translated, drawn and kept', () async {
    answerWith(['你在这里做什么？', '当天晚些时候']);
    final before = requests();
    final result = await service.translate(page, 'comic/1/0');

    // Only the text that is not Chinese already was sent.
    final sent = jsonDecode(
        (http.requests.last.data as Map)['messages'][1]['content'] as String);
    expect(sent, {
      'lines': ['WHAT ARE YOU DOING HERE?', 'LATER THAT DAY'],
    });
    expect(requests() - before, 1);

    // A different image of the same size.
    expect(result, isNot(page));
    final image = await decode(result);
    expect([image.width, image.height], [800, 1100]);

    expect(service.statusOf('comic/1/0')!.state, PageTranslationState.done);
    final stored = service.store.get(service.keyFor('comic/1/0'))!;
    expect(stored.blocks.map((b) => b.translation), ['你在这里做什么？', '当天晚些时候']);
    expect(stored.blocks.first.original, 'WHAT ARE YOU DOING HERE?');

    // Showing the page again costs nothing.
    final again = await service.translate(page, 'comic/1/0');
    expect(again, result);
    expect(requests() - before, 1);
    expect(ocrRuns, 1);
  });

  test('the drawn page is rebuilt from the kept text when the image is gone',
      () async {
    answerWith(['甲', '乙']);
    final first = await service.translate(page, 'comic/1/1');
    final before = requests();
    await CacheManager().delete(service.keyFor('comic/1/1'));
    final second = await service.translate(page, 'comic/1/1');
    expect(second, first);
    expect(requests(), before);
    expect(ocrRuns, 1);
  });

  test('a page with nothing to translate is shown as it is, and remembered',
      () async {
    recognized = [block([441, 421, 669, 515], '今天天气真好我们去散步吧')];
    final before = requests();
    expect(await service.translate(page, 'comic/1/2'), page);
    expect(service.statusOf('comic/1/2')!.state, PageTranslationState.noText);
    expect(await service.translate(page, 'comic/1/2'), page);
    expect(requests(), before);
    expect(ocrRuns, 1);
  });

  test('another target language is another translation', () async {
    answerWith(['甲', '乙']);
    await service.translate(page, 'comic/1/3');
    settings.setTarget('ja');
    // For Japanese the Chinese bubble is translated too.
    answerWith(['一', '二', '三']);
    await service.translate(page, 'comic/1/3');
    expect(ocrRuns, 2);
    expect(service.store.get(service.keyFor('comic/1/3'))!.blocks, hasLength(3));
    expect(service.store.count, 2);
  });

  group('in the reader', () {
    Stream<DownloadProgress> source() async* {
      yield const DownloadProgress(0, 100, 'u', '');
      yield const DownloadProgress(500, 1000, 'u', '');
      yield DownloadProgress(page.length, page.length, 'u', '', page, 'png');
    }

    test('loading progress passes through, then the translated page', () async {
      answerWith(['甲', '乙']);
      final events = await service.wrap(source(), 'comic/2/0').toList();
      expect(events.where((e) => e.finished), hasLength(1));
      expect(events.first.currentBytes, 0);
      expect(events.last.finished, isTrue);
      expect(events.last.data, isNot(page));
      expect(service.hasFailures, isFalse);
    });

    test('a failed translation shows the original and says why', () async {
      http.on('llm.example/v1/chat/completions', (_) => FakeResponse(
          '{"error":{"message":"Incorrect API key"}}', status: 401));
      final events = await service.wrap(source(), 'comic/2/1').toList();
      expect(events.last.finished, isTrue);
      expect(events.last.data, page);
      final status = service.statusOf('comic/2/1')!;
      expect(status.state, PageTranslationState.failed);
      expect(status.message, 'HTTP 401: Incorrect API key');
      expect(service.hasFailures, isTrue);

      // Nothing was kept, so fixing the key is enough to try again.
      expect(service.store.get(service.keyFor('comic/2/1')), isNull);
      answerWith(['甲', '乙']);
      final retry = await service.wrap(source(), 'comic/2/1').toList();
      expect(retry.last.data, isNot(page));
      expect(service.statusOf('comic/2/1')!.state, PageTranslationState.done);
    });

    test('a refusal is a failure of that page only', () async {
      http.text('llm.example/v1/chat/completions', jsonEncode({
        'choices': [
          {'finish_reason': 'content_filter', 'message': {'content': ''}},
        ],
      }));
      final events = await service.wrap(source(), 'comic/2/2').toList();
      expect(events.last.data, page);
      expect(service.statusOf('comic/2/2')!.state, PageTranslationState.failed);
    });

    test('forgetting a page translates it again', () async {
      answerWith(['甲', '乙']);
      await service.translate(page, 'comic/2/3');
      await service.forget('comic/2/3');
      expect(service.statusOf('comic/2/3'), isNull);
      answerWith(['丙', '丁']);
      await service.translate(page, 'comic/2/3');
      expect(ocrRuns, 2);
      expect(
          service.store
              .get(service.keyFor('comic/2/3'))!
              .blocks
              .map((b) => b.translation),
          ['丙', '丁']);
    });
  });

  group('what stands in the way', () {
    test('in order: platform, models, service', () {
      expect(service.problem, isNull);
      settings.removeProvider('p1');
      expect(service.problem, TranslationProblem.noProvider);
      models.installed = false;
      expect(service.problem, TranslationProblem.modelsMissing);
      PageTranslationService.isSupported = false;
      expect(service.problem, TranslationProblem.unsupported);
    });

    test('a service that is not filled in does not count', () {
      settings.saveProvider(const TranslatorProvider(
          id: 'p1', name: 'x', kind: TranslatorKind.anthropic, model: 'm'));
      expect(service.problem, TranslationProblem.noProvider);
    });
  });

  group('skipping text already in the target language', () {
    test('scripts', () {
      expect(scriptOf('今天天气真好'), TextScript.chinese);
      expect(scriptOf('元気ですか'), TextScript.japanese);
      expect(scriptOf('カタカナ'), TextScript.japanese);
      expect(scriptOf('안녕하세요'), TextScript.korean);
      expect(scriptOf('Hello there'), TextScript.latin);
      expect(scriptOf('OK 走吧'), TextScript.chinese);
      expect(scriptOf('?!…'), TextScript.other);
    });

    test('by target', () {
      final zh = TargetLanguage.of('zh'), en = TargetLanguage.of('en');
      expect(alreadyIn('今天天气真好', zh), isTrue);
      expect(alreadyIn('今天天气真好', TargetLanguage.of('zh-TW')), isTrue);
      expect(alreadyIn('元気ですか', zh), isFalse);
      expect(alreadyIn('元気ですか', TargetLanguage.of('ja')), isTrue);
      // Latin script may be any language, so it is always sent.
      expect(alreadyIn('Bonjour', en), isFalse);
    });
  });

  group('fitting a translation into its bubble', () {
    TranslatedBlock translated(List<int> rect, String text) => TranslatedBlock(
          rect: PixelRect.fromList(rect),
          lineRects: [
            PixelRect(rect[0], rect[1], rect[2], rect[1] + 40),
            PixelRect(rect[0], rect[1] + 45, rect[2], rect[1] + 85),
          ],
          original: 'x',
          translation: text,
          vertical: false,
          background: 0xFFFFFF,
          foreground: 0,
        );
    const pageSize = ui.Size(800, 1100);

    test('short text stays inside and is no larger than the lettering', () {
      final layout =
          layoutBlock(translated([100, 100, 500, 300], '你好'), pageSize);
      expect(layout.painter.height, lessThanOrEqualTo(layout.plate.height));
      expect(layout.painter.width, lessThanOrEqualTo(layout.plate.width));
      final size = layout.painter.text!.style!.fontSize!;
      expect(size, lessThanOrEqualTo(40 * 0.85 + 0.01));
      expect(size, greaterThan(20));
      // The plate covers the original lettering.
      expect(layout.plate.left, lessThanOrEqualTo(100));
      expect(layout.plate.bottom, greaterThanOrEqualTo(300));
    });

    test('long text gets smaller type', () {
      final short = layoutBlock(translated([100, 100, 400, 190], '好'), pageSize);
      final long = layoutBlock(
          translated([100, 100, 400, 190], '这是一段比较长的译文' * 4), pageSize);
      expect(long.painter.text!.style!.fontSize!,
          lessThan(short.painter.text!.style!.fontSize!));
      expect(long.painter.height, lessThanOrEqualTo(long.plate.height));
    });

    test('text that cannot fit grows the plate but stays on the page', () {
      final layout = layoutBlock(
          translated([100, 1000, 300, 1090], '很长很长的译文' * 30), pageSize);
      expect(layout.plate.height, greaterThan(100));
      expect(layout.plate.top, greaterThanOrEqualTo(0));
      expect(layout.plate.bottom, lessThanOrEqualTo(1100));
      expect(layout.painter.text!.style!.fontSize, 9);
    });
  });
}
