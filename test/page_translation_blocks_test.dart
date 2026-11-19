import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/page_translation/ocr_types.dart';
import 'package:pica_comic/foundation/page_translation/text_blocks.dart';

void main() {
  RgbaImage blank(int w, int h, [int grey = 255]) {
    final pixels = Uint8List(w * h * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = grey;
      pixels[i + 1] = grey;
      pixels[i + 2] = grey;
      pixels[i + 3] = 255;
    }
    return RgbaImage(w, h, pixels);
  }

  void fill(RgbaImage image, PixelRect rect, int r, int g, int b) {
    for (var y = rect.top; y < rect.bottom; y++) {
      for (var x = rect.left; x < rect.right; x++) {
        final i = (y * image.width + x) * 4;
        image.pixels[i] = r;
        image.pixels[i + 1] = g;
        image.pixels[i + 2] = b;
      }
    }
  }

  TextLine line(int l, int t, int r, int b, String text) =>
      TextLine(PixelRect(l, t, r, b), text, 0.9);

  group('grouping lines into blocks', () {
    final page = blank(800, 1100);

    // The boxes the detector gave for the sample page.
    final sample = [
      line(119, 130, 385, 161, 'WHAT ARE YOU'),
      line(120, 180, 358, 212, 'DOING HERE?'),
      line(442, 421, 668, 462, '今天天气真好'),
      line(441, 477, 669, 515, '我们去散步吧'),
      line(165, 699, 218, 929, '元気ですか'),
      line(237, 701, 284, 926, 'こんにちは'),
      line(490, 730, 730, 756, 'LATER THAT DAY'),
    ];

    test('the sample page gives four blocks in reading order', () {
      final blocks = groupLines(page, sample);
      expect(blocks.map((b) => b.text), [
        'WHAT ARE YOU DOING HERE?',
        '今天天气真好我们去散步吧',
        // Vertical columns are read right to left; it starts a little higher
        // than the caption next to it.
        'こんにちは元気ですか',
        'LATER THAT DAY',
      ]);
      expect(blocks.map((b) => b.vertical), [false, false, true, false]);
      expect(blocks[2].rect.toList(), [165, 699, 284, 929]);
      expect(blocks.first.lines, hasLength(2));
    });

    test('lines far apart or of very different size stay separate', () {
      final blocks = groupLines(page, [
        line(100, 100, 300, 130, 'first'),
        line(100, 200, 300, 230, 'far below'),
        line(100, 132, 300, 220, 'BIG'),
      ]);
      expect(blocks, hasLength(3));
    });

    test('lines side by side without overlap stay separate', () {
      final blocks = groupLines(page, [
        line(100, 100, 300, 130, 'left'),
        line(400, 100, 600, 130, 'right'),
      ]);
      expect(blocks, hasLength(2));
      // Same height: right to left.
      expect(blocks.map((b) => b.text), ['right', 'left']);
    });

    test('a column and a line next to it are not mixed', () {
      final blocks = groupLines(page, [
        line(100, 100, 140, 400, '縦'),
        line(150, 100, 400, 140, 'horizontal'),
      ]);
      expect(blocks, hasLength(2));
    });
  });

  group('joining lines', () {
    test('spaced scripts get a space, hyphenated words are rejoined', () {
      expect(joinLines(['WHAT ARE', 'YOU DOING']), 'WHAT ARE YOU DOING');
      expect(joinLines(['some-', 'thing else']), 'something else');
      expect(joinLines(['안녕', '하세요']), '안녕 하세요');
    });

    test('Chinese and Japanese are joined directly', () {
      expect(joinLines(['今天天气', '真好']), '今天天气真好');
      expect(joinLines(['こんにちは', '元気ですか']), 'こんにちは元気ですか');
    });

    test('mixed lines get a space on the Latin side, empty lines vanish', () {
      expect(joinLines(['OK', '走吧']), 'OK 走吧');
      expect(joinLines(['', 'only']), 'only');
    });
  });

  group('colours', () {
    test('dark ink on a light bubble', () {
      final page = blank(100, 100, 250);
      fill(page, const PixelRect(20, 40, 80, 50), 10, 10, 10);
      final (background, foreground) =
          sampleColours(page, const PixelRect(0, 0, 100, 100));
      expect(background, 0xFAFAFA);
      expect(foreground, 0x0A0A0A);
    });

    test('light ink on a dark box', () {
      final page = blank(100, 100, 30);
      fill(page, const PixelRect(20, 40, 80, 50), 240, 240, 240);
      final (background, foreground) =
          sampleColours(page, const PixelRect(0, 0, 100, 100));
      expect(background, 0x1E1E1E);
      expect(foreground, 0xF0F0F0);
    });

    test('a coloured bubble keeps its colour', () {
      final page = blank(60, 60);
      fill(page, const PixelRect(0, 0, 60, 60), 255, 220, 120);
      fill(page, const PixelRect(10, 25, 50, 32), 60, 20, 20);
      final (background, foreground) =
          sampleColours(page, const PixelRect(0, 0, 60, 60));
      expect(background, 0xFFDC78);
      expect(foreground, 0x3C1414);
    });

    test('nothing stands out: ink is chosen by contrast', () {
      expect(sampleColours(blank(20, 20, 250), const PixelRect(0, 0, 20, 20)),
          (0xFAFAFA, 0x000000));
      expect(sampleColours(blank(20, 20, 20), const PixelRect(0, 0, 20, 20)),
          (0x141414, 0xFFFFFF));
    });
  });
}
