import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'ocr_types.dart';
import 'ort.dart';
import 'text_blocks.dart';
import 'text_detector.dart';
import 'text_recognizer.dart';

/// The model files one OCR run needs.
class OcrModelPaths {
  const OcrModelPaths({
    required this.detector,
    required this.recognizer,
    required this.dictionary,
  });

  final String detector;
  final String recognizer;
  final String dictionary;

  List<String> toList() => [detector, recognizer, dictionary];

  static OcrModelPaths fromList(List<dynamic> list) => OcrModelPaths(
        detector: list[0] as String,
        recognizer: list[1] as String,
        dictionary: list[2] as String,
      );
}

/// Detection, recognition and grouping for one page. Blocking: runs inside
/// [OcrWorker]'s isolate (or directly in a test).
class OcrEngine {
  OcrEngine(OcrModelPaths paths, {int threads = 2})
      : _detector = TextDetector(
            OrtRuntime.open().openSession(paths.detector, threads: threads)),
        _recognizer = TextRecognizer(
            OrtRuntime.open().openSession(paths.recognizer, threads: threads),
            File(paths.dictionary).readAsLinesSync());

  final TextDetector _detector;
  final TextRecognizer _recognizer;

  /// Lines the recognizer is less sure of than this are noise more often than
  /// text: screentone, hair, speed lines.
  static const minConfidence = 0.6;

  List<TextBlock> read(RgbaImage image) {
    var lines = <TextLine>[];
    for (var box in _detector.detect(image)) {
      var line = _recognizer.read(image, box);
      if (line.text.isNotEmpty && line.confidence >= minConfidence) {
        lines.add(line);
      }
    }
    return [
      for (var block in groupLines(image, lines))
        if (isWorthTranslating(block.text)) block,
    ];
  }
}

/// Page numbers, lone letters and runs of punctuation are not dialogue.
bool isWorthTranslating(String text) {
  var letters = 0;
  for (var rune in text.runes) {
    var isCjk = rune >= 0x2E80;
    var isLatinLetter = (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0xC0 && rune < 0x2E80 && rune != 0xD7 && rune != 0xF7);
    if (isCjk) return true;
    if (isLatinLetter) letters++;
  }
  return letters >= 2;
}

Map<String, dynamic> _blockToMap(TextBlock block) => {
      'rect': block.rect.toList(),
      'lines': [for (var line in block.lines) line.rect.toList()],
      'text': block.text,
      'vertical': block.vertical,
      'background': block.background,
      'foreground': block.foreground,
    };

/// What the worker returns for one block: a [TextBlock] without the
/// per-line text, which nothing needs after grouping.
class OcrBlock {
  OcrBlock({
    required this.rect,
    required this.lineRects,
    required this.text,
    required this.vertical,
    required this.background,
    required this.foreground,
  });

  final PixelRect rect;
  final List<PixelRect> lineRects;
  final String text;
  final bool vertical;
  final int background;
  final int foreground;

  static OcrBlock fromMap(Map<dynamic, dynamic> map) => OcrBlock(
        rect: PixelRect.fromList(map['rect'] as List),
        lineRects: [
          for (var rect in map['lines'] as List)
            PixelRect.fromList(rect as List),
        ],
        text: map['text'] as String,
        vertical: map['vertical'] as bool,
        background: map['background'] as int,
        foreground: map['foreground'] as int,
      );
}

/// Runs [OcrEngine] on its own isolate so the reader stays responsive, one
/// page at a time. The models stay loaded between pages and are dropped by
/// [release].
class OcrWorker {
  OcrWorker._();

  static final instance = OcrWorker._();

  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  final _pending = <int, Completer<List<OcrBlock>>>{};
  var _nextId = 0;

  Future<void> _start() {
    return _starting ??= () async {
      var replies = ReceivePort();
      var ready = Completer<SendPort>();
      replies.listen((message) {
        if (message is SendPort) {
          ready.complete(message);
          return;
        }
        var reply = message as List;
        var completer = _pending.remove(reply[0] as int);
        if (completer == null) return;
        if (reply[1] != null) {
          completer.completeError(OcrException(reply[1] as String));
        } else {
          completer.complete(
              [for (var map in reply[2] as List) OcrBlock.fromMap(map as Map)]);
        }
      });
      _isolate = await Isolate.spawn(
          _main, [replies.sendPort, OrtRuntime.libraryPath],
          debugName: 'PageTranslationOcr');
      _commands = await ready.future;
    }();
  }

  /// Reads the text on [image]. The pixel buffer is handed over to the
  /// worker, so [image] must not be used afterwards.
  Future<List<OcrBlock>> read(RgbaImage image, OcrModelPaths paths) async {
    await _start();
    var id = _nextId++;
    var completer = Completer<List<OcrBlock>>();
    _pending[id] = completer;
    _commands!.send([
      id,
      paths.toList(),
      image.width,
      image.height,
      TransferableTypedData.fromList([image.pixels]),
    ]);
    return completer.future;
  }

  /// Stops the isolate and frees the models. A page in progress fails.
  void release() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _starting = null;
    for (var completer in _pending.values) {
      completer.completeError(OcrException('the OCR worker was stopped'));
    }
    _pending.clear();
  }

  static void _main(List<dynamic> args) {
    var replies = args[0] as SendPort;
    OrtRuntime.libraryPath = args[1] as String?;
    var commands = ReceivePort();
    replies.send(commands.sendPort);
    OcrEngine? engine;
    String? loaded;
    commands.listen((message) {
      var command = message as List;
      var id = command[0] as int;
      try {
        var paths = OcrModelPaths.fromList(command[1] as List);
        var signature = paths.toList().join('\n');
        if (engine == null || loaded != signature) {
          engine = OcrEngine(paths);
          loaded = signature;
        }
        var image = RgbaImage(
          command[2] as int,
          command[3] as int,
          (command[4] as TransferableTypedData).materialize().asUint8List(),
        );
        replies.send([
          id,
          null,
          [for (var block in engine!.read(image)) _blockToMap(block)],
        ]);
      } catch (e) {
        replies.send([id, '$e', null]);
      }
    });
  }
}

class OcrException implements Exception {
  OcrException(this.message);

  final String message;

  @override
  String toString() => 'OcrException: $message';
}
