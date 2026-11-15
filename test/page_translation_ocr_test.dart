import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pica_comic/foundation/page_translation/ocr_types.dart';
import 'package:pica_comic/foundation/page_translation/ort.dart';
import 'package:pica_comic/foundation/page_translation/text_detector.dart';
import 'package:pica_comic/foundation/page_translation/text_recognizer.dart';

// Runs the real models on the sample page. Needs a desktop build of ONNX
// Runtime and the model files, neither of which is in the repository:
//
//   PICA_ORT_LIB=/path/to/libonnxruntime.dylib \
//   PICA_OCR_MODELS=/path/to/models \
//   flutter test test/page_translation_ocr_test.dart
//
// The models directory holds det.onnx, rec_zh.onnx and dict_zh.txt. Without
// the two variables the test is skipped.
void main() {
  final lib = Platform.environment['PICA_ORT_LIB'];
  final models = Platform.environment['PICA_OCR_MODELS'];
  final skip = lib == null || models == null
      ? 'set PICA_ORT_LIB and PICA_OCR_MODELS to run'
      : null;

  RgbaImage load(String path) {
    final decoded = img.decodePng(File(path).readAsBytesSync())!;
    final rgba = decoded.convert(numChannels: 4);
    return RgbaImage(
        rgba.width, rgba.height, rgba.getBytes(order: img.ChannelOrder.rgba));
  }

  test('reads the sample page', () {
    OrtRuntime.libraryPath = lib;
    final runtime = OrtRuntime.open();
    final detector = TextDetector(runtime.openSession('$models/det.onnx'));
    final recognizer = TextRecognizer(
        runtime.openSession('$models/rec_zh.onnx'),
        File('$models/dict_zh.txt').readAsLinesSync());
    final page = load('test/fixtures/page_translation/sample_page.png');

    final watch = Stopwatch()..start();
    final boxes = detector.detect(page);
    final lines = [for (final box in boxes) recognizer.read(page, box)];
    // Shown so a failure can be read without re-running.
    // ignore: avoid_print
    print('${boxes.length} boxes in ${watch.elapsedMilliseconds} ms');
    for (final line in lines) {
      // ignore: avoid_print
      print('${line.rect} vertical=${line.rect.isVertical} '
          '"${line.text}" ${line.confidence.toStringAsFixed(2)}');
    }

    final text = lines.map((line) => line.text.toUpperCase()).join('\n');
    expect(text, contains('WHAT ARE YOU'));
    expect(text, contains('DOING HERE'));
    expect(text, contains('今天天气真好'));
    expect(text, contains('我们去散步吧'));
    expect(text, contains('LATER THAT DAY'));
    // Vertical Japanese columns.
    expect(text, contains('こんにちは'));
    expect(text, contains('元気ですか'));
  }, skip: skip);
}
