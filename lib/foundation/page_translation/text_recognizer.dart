import 'dart:math' as math;
import 'dart:typed_data';

import 'ocr_types.dart';
import 'ort.dart';

/// Reads one line of text with a PP-OCR recognition model (CTC output).
class TextRecognizer {
  /// [dictionary] lists the model's characters, one per line, in the order of
  /// its output classes after the blank.
  TextRecognizer(this._session, List<String> dictionary, {this.height = 48})
      : _characters = charactersOf(dictionary);

  final OrtSession _session;

  final List<String> _characters;

  /// Input height the model expects: 48 for PP-OCRv3 and later.
  final int height;

  /// Widest input, in pixels at [height]. Longer lines are squeezed.
  static const _maxWidth = 1600;

  /// Class 0 is the CTC blank; a space is appended after the dictionary.
  static List<String> charactersOf(List<String> dictionary) =>
      ['', ...dictionary, ' '];

  /// Reads the text inside [rect]. A vertical column is turned on its side
  /// first, which is how these models are trained to see vertical writing.
  TextLine read(RgbaImage image, PixelRect rect) {
    var vertical = rect.isVertical;
    var srcW = vertical ? rect.height : rect.width;
    var srcH = vertical ? rect.width : rect.height;
    if (srcW < 2 || srcH < 2) return TextLine(rect, '', 0);
    var w = (height * srcW / srcH).ceil().clamp(8, _maxWidth);
    var input = prepare(image, rect, vertical, w, height);
    var output = _session.run(input, [1, 3, height, w]);
    var (text, confidence) =
        decode(output.data, output.shape[1], output.shape[2], _characters);
    return TextLine(rect, text, confidence);
  }

  /// Crops [rect] into a [w] x [h] line as planar B, G, R floats in -1..1.
  static Float32List prepare(
      RgbaImage image, PixelRect rect, bool vertical, int w, int h) {
    var out = Float32List(3 * w * h);
    var plane = w * h;
    var src = image.pixels;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // Position inside the crop, 0..1 along the reading direction (u) and
        // across it (v).
        var u = (x + 0.5) / w, v = (y + 0.5) / h;
        double fx, fy;
        if (vertical) {
          // Rotated a quarter turn counter-clockwise: the top of the column
          // becomes the left of the line.
          fx = rect.right - v * rect.width - 0.5;
          fy = rect.top + u * rect.height - 0.5;
        } else {
          fx = rect.left + u * rect.width - 0.5;
          fy = rect.top + v * rect.height - 0.5;
        }
        var x0 = fx.floor().clamp(0, image.width - 1);
        var y0 = fy.floor().clamp(0, image.height - 1);
        var x1 = math.min(x0 + 1, image.width - 1);
        var y1 = math.min(y0 + 1, image.height - 1);
        var wx = (fx - x0).clamp(0.0, 1.0), wy = (fy - y0).clamp(0.0, 1.0);
        var a = (y0 * image.width + x0) * 4;
        var b = (y0 * image.width + x1) * 4;
        var c = (y1 * image.width + x0) * 4;
        var d = (y1 * image.width + x1) * 4;
        var i = y * w + x;
        for (var ch = 0; ch < 3; ch++) {
          var o = 2 - ch; // blue first
          var top = src[a + o] * (1 - wx) + src[b + o] * wx;
          var bottom = src[c + o] * (1 - wx) + src[d + o] * wx;
          var value = (top * (1 - wy) + bottom * wy) / 255.0;
          out[ch * plane + i] = (value - 0.5) / 0.5;
        }
      }
    }
    return out;
  }

  /// Greedy CTC decoding of [steps] x [classes] scores: the best class per
  /// step, repeats merged, blanks dropped. Returns the text and the mean
  /// score of its characters.
  static (String, double) decode(
      Float32List data, int steps, int classes, List<String> characters) {
    var text = StringBuffer();
    var previous = 0;
    var total = 0.0;
    var count = 0;
    for (var t = 0; t < steps; t++) {
      var offset = t * classes;
      var best = 0;
      var bestValue = data[offset];
      for (var c = 1; c < classes; c++) {
        var value = data[offset + c];
        if (value > bestValue) {
          bestValue = value;
          best = c;
        }
      }
      if (best != 0 && best != previous && best < characters.length) {
        text.write(characters[best]);
        total += bestValue;
        count++;
      }
      previous = best;
    }
    return (text.toString().trim(), count == 0 ? 0.0 : total / count);
  }
}
