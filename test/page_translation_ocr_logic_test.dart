import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/ocr_types.dart';
import 'package:pica_comic/foundation/page_translation/text_detector.dart';
import 'package:pica_comic/foundation/page_translation/text_recognizer.dart';

// The parts of text detection and recognition that are plain arithmetic and
// need no model: turning the detector's probability map into boxes, cropping
// a line for the recognizer, and decoding the recognizer's output.
void main() {
  group('boxes from the detector map', () {
    Float32List mapWith(int w, int h, List<(PixelRect, double)> areas) {
      final map = Float32List(w * h);
      for (final (rect, value) in areas) {
        for (var y = rect.top; y < rect.bottom; y++) {
          for (var x = rect.left; x < rect.right; x++) {
            map[y * w + x] = value;
          }
        }
      }
      return map;
    }

    test('a confident area becomes one box, grown and scaled to the page', () {
      final map = mapWith(64, 32, [(const PixelRect(10, 8, 50, 16), 0.9)]);
      // The page is twice as large as the map in both directions.
      final boxes = TextDetector.boxesFromMap(map, 64, 32, 128, 64);
      expect(boxes, hasLength(1));
      final box = boxes.single;
      // 40 x 8 core: grows by 40 * 8 * 1.6 / (2 * 48) = 5.33 map pixels.
      expect(box.left, ((10 - 5.34) * 2).floor());
      expect(box.top, ((8 - 5.34) * 2).floor());
      expect(box.right, ((50 + 5.34) * 2).ceil());
      expect(box.bottom, ((16 + 5.34) * 2).ceil());
      expect(box.isVertical, isFalse);
    });

    test('separate areas stay separate, touching ones merge', () {
      final map = mapWith(64, 64, [
        (const PixelRect(4, 4, 30, 10), 0.9),
        (const PixelRect(4, 40, 30, 46), 0.9),
        // Touches the first area at its corner.
        (const PixelRect(30, 10, 40, 14), 0.9),
      ]);
      expect(TextDetector.boxesFromMap(map, 64, 64, 64, 64), hasLength(2));
    });

    test('faint and tiny areas are dropped', () {
      final map = mapWith(64, 64, [
        (const PixelRect(4, 4, 40, 12), 0.4), // above the pixel threshold only
        (const PixelRect(4, 30, 6, 60), 0.95), // two pixels wide
      ]);
      expect(TextDetector.boxesFromMap(map, 64, 64, 64, 64), isEmpty);
    });

    test('boxes never leave the page', () {
      final map = mapWith(32, 32, [(const PixelRect(0, 0, 32, 10), 0.9)]);
      final box = TextDetector.boxesFromMap(map, 32, 32, 32, 32).single;
      expect(box.left, 0);
      expect(box.top, 0);
      expect(box.right, 32);
    });

    test('a tall area is a vertical column', () {
      final map = mapWith(64, 64, [(const PixelRect(20, 4, 28, 60), 0.9)]);
      expect(
          TextDetector.boxesFromMap(map, 64, 64, 64, 64).single.isVertical,
          isTrue);
    });
  });

  group('cropping a line for the recognizer', () {
    // A page that is black in its top half and white below.
    RgbaImage page() {
      const w = 20, h = 40;
      final pixels = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final value = y < h ~/ 2 ? 0 : 255;
          final i = (y * w + x) * 4;
          pixels[i] = value;
          pixels[i + 1] = value;
          pixels[i + 2] = value;
          pixels[i + 3] = 255;
        }
      }
      return RgbaImage(w, h, pixels);
    }

    test('a horizontal line keeps its orientation', () {
      final crop = TextRecognizer.prepare(
          page(), const PixelRect(0, 0, 20, 40), false, 8, 8);
      // First channel plane: top rows dark (-1), bottom rows light (+1).
      expect(crop[0], closeTo(-1, 1e-6));
      expect(crop[7 * 8], closeTo(1, 1e-6));
      expect(crop[7], closeTo(-1, 1e-6));
    });

    test('a vertical column is laid on its side, top to the left', () {
      final crop = TextRecognizer.prepare(
          page(), const PixelRect(0, 0, 20, 40), true, 16, 8);
      // Left half dark, right half light, on every row.
      for (var row = 0; row < 8; row++) {
        expect(crop[row * 16], closeTo(-1, 1e-6));
        expect(crop[row * 16 + 15], closeTo(1, 1e-6));
      }
    });
  });

  group('decoding the recognizer output', () {
    final characters = TextRecognizer.charactersOf(['a', 'b', '你']);

    Float32List scores(List<int> best, {double value = 0.9}) {
      final data = Float32List(best.length * characters.length);
      for (var t = 0; t < best.length; t++) {
        data[t * characters.length + best[t]] = value;
      }
      return data;
    }

    test('repeats are merged and blanks dropped', () {
      // a a _ a b b _ 你
      final (text, confidence) = TextRecognizer.decode(
          scores([1, 1, 0, 1, 2, 2, 0, 3]), 8, characters.length, characters);
      expect(text, 'aab你');
      expect(confidence, closeTo(0.9, 1e-6));
    });

    test('the class after the dictionary is a space', () {
      final (text, _) = TextRecognizer.decode(
          scores([1, 0, 4, 0, 2]), 5, characters.length, characters);
      expect(text, 'a b');
    });

    test('nothing recognized gives an empty line', () {
      final (text, confidence) = TextRecognizer.decode(
          scores([0, 0, 0]), 3, characters.length, characters);
      expect(text, '');
      expect(confidence, 0);
    });
  });
}
