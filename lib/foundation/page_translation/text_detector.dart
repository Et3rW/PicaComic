import 'dart:math' as math;
import 'dart:typed_data';

import 'ocr_types.dart';
import 'ort.dart';

/// Finds lines of text on a page with a DBNet model (PP-OCR detection).
///
/// The model answers with a probability map the size of its input; connected
/// areas above [_pixelThreshold] become boxes, which are then grown outwards
/// because the model marks only the core of each line.
class TextDetector {
  TextDetector(this._session);

  final OrtSession _session;

  /// Longest side fed to the model. Larger pages are scaled down.
  static const maxSide = 1280;

  static const _pixelThreshold = 0.3;
  static const _boxThreshold = 0.55;

  /// How far a box grows, as area * ratio / perimeter on each side.
  static const _unclipRatio = 1.6;

  List<PixelRect> detect(RgbaImage image) {
    var scale = math.min(1.0, maxSide / math.max(image.width, image.height));
    // The network needs both sides to be multiples of 32.
    var w = math.max(32, (image.width * scale / 32).round() * 32);
    var h = math.max(32, (image.height * scale / 32).round() * 32);
    var input = prepare(image, w, h);
    var output = _session.run(input, [1, 3, h, w]).data;
    return boxesFromMap(output, w, h, image.width, image.height);
  }

  /// Resizes to [w] x [h] and normalizes into planar B, G, R floats, the layout
  /// the model was trained with.
  static Float32List prepare(RgbaImage image, int w, int h) {
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    var out = Float32List(3 * w * h);
    var plane = w * h;
    var sx = image.width / w, sy = image.height / h;
    var src = image.pixels;
    for (var y = 0; y < h; y++) {
      var fy = (y + 0.5) * sy - 0.5;
      var y0 = fy.floor().clamp(0, image.height - 1);
      var y1 = math.min(y0 + 1, image.height - 1);
      var wy = (fy - y0).clamp(0.0, 1.0);
      for (var x = 0; x < w; x++) {
        var fx = (x + 0.5) * sx - 0.5;
        var x0 = fx.floor().clamp(0, image.width - 1);
        var x1 = math.min(x0 + 1, image.width - 1);
        var wx = (fx - x0).clamp(0.0, 1.0);
        var a = (y0 * image.width + x0) * 4;
        var b = (y0 * image.width + x1) * 4;
        var c = (y1 * image.width + x0) * 4;
        var d = (y1 * image.width + x1) * 4;
        var i = y * w + x;
        for (var ch = 0; ch < 3; ch++) {
          // Channel 0 of the model is blue: read R, G, B back to front.
          var o = 2 - ch;
          var top = src[a + o] * (1 - wx) + src[b + o] * wx;
          var bottom = src[c + o] * (1 - wx) + src[d + o] * wx;
          var value = (top * (1 - wy) + bottom * wy) / 255.0;
          out[ch * plane + i] = (value - mean[ch]) / std[ch];
        }
      }
    }
    return out;
  }

  /// Turns a [w] x [h] probability map into boxes in the coordinates of an
  /// image of [imageWidth] x [imageHeight].
  static List<PixelRect> boxesFromMap(
      Float32List map, int w, int h, int imageWidth, int imageHeight) {
    var scaleX = imageWidth / w, scaleY = imageHeight / h;
    var seen = Uint8List(w * h);
    var stack = <int>[];
    var boxes = <PixelRect>[];
    for (var start = 0; start < w * h; start++) {
      if (seen[start] != 0 || map[start] < _pixelThreshold) continue;
      seen[start] = 1;
      stack.add(start);
      var left = w, top = h, right = 0, bottom = 0;
      var sum = 0.0;
      var count = 0;
      while (stack.isNotEmpty) {
        var p = stack.removeLast();
        var px = p % w, py = p ~/ w;
        if (px < left) left = px;
        if (px > right) right = px;
        if (py < top) top = py;
        if (py > bottom) bottom = py;
        sum += map[p];
        count++;
        for (var dy = -1; dy <= 1; dy++) {
          var ny = py + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            var nx = px + dx;
            if (nx < 0 || nx >= w) continue;
            var n = ny * w + nx;
            if (seen[n] == 0 && map[n] >= _pixelThreshold) {
              seen[n] = 1;
              stack.add(n);
            }
          }
        }
      }
      var bw = right - left + 1, bh = bottom - top + 1;
      if (math.min(bw, bh) < 3 || sum / count < _boxThreshold) continue;
      var grow = bw * bh * _unclipRatio / (2 * (bw + bh));
      boxes.add(PixelRect(
        ((left - grow) * scaleX).floor(),
        ((top - grow) * scaleY).floor(),
        ((right + 1 + grow) * scaleX).ceil(),
        ((bottom + 1 + grow) * scaleY).ceil(),
      ).clamp(imageWidth, imageHeight));
    }
    return boxes;
  }
}
