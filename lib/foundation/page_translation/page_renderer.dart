import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'ocr_types.dart';

/// One block of a page with its translation: everything needed to draw the
/// translated page again without running OCR or a translation request.
class TranslatedBlock {
  TranslatedBlock({
    required this.rect,
    required this.lineRects,
    required this.original,
    required this.translation,
    required this.vertical,
    required this.background,
    required this.foreground,
  });

  final PixelRect rect;
  final List<PixelRect> lineRects;
  final String original;
  final String translation;
  final bool vertical;

  /// 0xRRGGBB.
  final int background;
  final int foreground;

  Map<String, dynamic> toJson() => {
        'rect': rect.toList(),
        'lines': [for (var line in lineRects) line.toList()],
        'original': original,
        'translation': translation,
        'vertical': vertical,
        'background': background,
        'foreground': foreground,
      };

  static TranslatedBlock fromJson(Map<dynamic, dynamic> json) =>
      TranslatedBlock(
        rect: PixelRect.fromList(json['rect'] as List),
        lineRects: [
          for (var line in json['lines'] as List)
            PixelRect.fromList(line as List),
        ],
        original: json['original'] as String,
        translation: json['translation'] as String,
        vertical: json['vertical'] as bool,
        background: json['background'] as int,
        foreground: json['foreground'] as int,
      );
}

/// A page decoded for OCR and drawing. Call [dispose] when done.
class DecodedPage {
  DecodedPage(this.image, this.rgba);

  final ui.Image image;
  final RgbaImage rgba;

  void dispose() => image.dispose();
}

/// Largest page worked on, in pixels. Bigger ones (long strips) are scaled
/// down first: OCR and drawing both hold the whole page in memory.
const _maxPixels = 10 * 1000 * 1000;
const _maxSide = 6000;

/// Size [width] x [height] is worked on at.
(int, int) workingSize(int width, int height) {
  var scale = 1.0;
  if (width * height > _maxPixels) {
    scale = math.sqrt(_maxPixels / (width * height));
  }
  if (math.max(width, height) * scale > _maxSide) {
    scale = _maxSide / math.max(width, height);
  }
  if (scale >= 1.0) return (width, height);
  return (
    math.max(1, (width * scale).round()),
    math.max(1, (height * scale).round()),
  );
}

Future<DecodedPage> decodePage(Uint8List bytes) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  ui.Codec? codec;
  try {
    var (w, h) = workingSize(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(targetWidth: w, targetHeight: h);
    var image = (await codec.getNextFrame()).image;
    var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      image.dispose();
      throw Exception('cannot read the pixels of this image');
    }
    return DecodedPage(
        image, RgbaImage(image.width, image.height, data.buffer.asUint8List()));
  } finally {
    codec?.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Where and how large one block's translation is drawn.
class BlockLayout {
  BlockLayout(this.plate, this.painter);

  /// The area covered with the bubble colour.
  final ui.Rect plate;

  /// Laid out, to be painted centred in [plate].
  final TextPainter painter;
}

/// Fits [block]'s translation into its area on a page of [pageSize]: the
/// largest type that fits, never larger than the original lettering. When
/// even the smallest size overflows, the plate grows downwards and upwards
/// around the block.
BlockLayout layoutBlock(TranslatedBlock block, ui.Size pageSize) {
  var rect = ui.Rect.fromLTRB(
      block.rect.left.toDouble(),
      block.rect.top.toDouble(),
      block.rect.right.toDouble(),
      block.rect.bottom.toDouble());
  var margin = math.max(2.0, rect.shortestSide * 0.04);
  var page = ui.Offset.zero & pageSize;
  var plate = rect.inflate(margin).intersect(page);
  var padding = math.max(2.0, plate.shortestSide * 0.05);
  var maxWidth = math.max(8.0, plate.width - padding * 2);

  // The original lettering's size: the thickness of its lines.
  var thickness = block.lineRects.isEmpty
      ? rect.shortestSide
      : block.lineRects
              .map((line) => block.vertical ? line.width : line.height)
              .reduce((a, b) => a + b) /
          block.lineRects.length;
  var largest = (thickness * 0.85).clamp(10.0, 72.0);
  const smallest = 9.0;

  TextPainter paint(double size) {
    return TextPainter(
      text: TextSpan(
        text: block.translation,
        style: TextStyle(
          color: ui.Color(0xFF000000 | block.foreground),
          fontSize: size,
          height: 1.2,
          fontWeight: FontWeight.w500,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
  }

  bool fits(TextPainter painter) =>
      painter.height <= plate.height - padding * 2 &&
      painter.width <= maxWidth + 0.5;

  var low = smallest, high = largest;
  var best = paint(low);
  if (fits(best)) {
    for (var i = 0; i < 7 && high - low > 0.5; i++) {
      var mid = (low + high) / 2;
      var candidate = paint(mid);
      if (fits(candidate)) {
        best = candidate;
        low = mid;
      } else {
        high = mid;
      }
    }
    var top = paint(largest);
    if (fits(top)) best = top;
  } else {
    // Too much text for the bubble: let the plate grow.
    var needed = best.height + padding * 2;
    plate = ui.Rect.fromCenter(
            center: plate.center, width: plate.width, height: needed)
        .intersect(page);
    if (plate.height < needed) {
      // Against the page edge: slide instead of clipping.
      var topEdge = (plate.top + plate.height - needed).clamp(0.0, plate.top);
      plate = ui.Rect.fromLTWH(plate.left, topEdge, plate.width,
          math.min(needed, pageSize.height));
    }
  }
  return BlockLayout(plate, best);
}

/// Draws [blocks] over [base] and returns the result as PNG bytes. Each block
/// is covered with a plate in the bubble's colour and the translation is set
/// on it in the ink's colour.
Future<Uint8List> renderTranslatedPage(
    ui.Image base, List<TranslatedBlock> blocks) async {
  var size = ui.Size(base.width.toDouble(), base.height.toDouble());
  var recorder = ui.PictureRecorder();
  var canvas = ui.Canvas(recorder, ui.Offset.zero & size);
  canvas.drawImage(base, ui.Offset.zero, ui.Paint());
  for (var block in blocks) {
    if (block.translation.trim().isEmpty) continue;
    var layout = layoutBlock(block, size);
    var plate = layout.plate;
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
          plate, ui.Radius.circular(plate.shortestSide * 0.12)),
      ui.Paint()..color = ui.Color(0xFF000000 | block.background),
    );
    layout.painter.paint(
      canvas,
      ui.Offset(
        plate.left + (plate.width - layout.painter.width) / 2,
        plate.top + (plate.height - layout.painter.height) / 2,
      ),
    );
    layout.painter.dispose();
  }
  var picture = recorder.endRecording();
  var image = await picture.toImage(base.width, base.height);
  try {
    var data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw Exception('cannot encode the translated page');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
