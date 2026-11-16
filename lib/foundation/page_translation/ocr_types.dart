import 'dart:typed_data';

/// Decoded pixels, four bytes per pixel in R, G, B, A order.
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels)
      : assert(pixels.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// An axis-aligned rectangle in image pixels.
class PixelRect {
  const PixelRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  /// A column of vertical writing rather than a horizontal line.
  bool get isVertical => height >= width * 1.5;

  PixelRect union(PixelRect other) => PixelRect(
        left < other.left ? left : other.left,
        top < other.top ? top : other.top,
        right > other.right ? right : other.right,
        bottom > other.bottom ? bottom : other.bottom,
      );

  PixelRect clamp(int width, int height) => PixelRect(
        left.clamp(0, width),
        top.clamp(0, height),
        right.clamp(0, width),
        bottom.clamp(0, height),
      );

  /// This rectangle on a page stretched by [sx] and [sy].
  PixelRect scaled(double sx, double sy) => PixelRect(
        (left * sx).round(),
        (top * sy).round(),
        (right * sx).round(),
        (bottom * sy).round(),
      );

  List<int> toList() => [left, top, right, bottom];

  static PixelRect fromList(List<dynamic> values) => PixelRect(
        values[0] as int,
        values[1] as int,
        values[2] as int,
        values[3] as int,
      );

  @override
  String toString() => 'PixelRect($left, $top, $right, $bottom)';
}

/// One recognized line (or vertical column) of text.
class TextLine {
  TextLine(this.rect, this.text, this.confidence);

  final PixelRect rect;
  final String text;

  /// Mean probability of the recognized characters, 0 to 1.
  final double confidence;
}

/// Lines that belong together, usually one speech bubble.
class TextBlock {
  TextBlock({
    required this.rect,
    required this.lines,
    required this.text,
    required this.vertical,
    required this.background,
    required this.foreground,
  });

  /// Bounds of all [lines].
  final PixelRect rect;

  /// In reading order.
  final List<TextLine> lines;

  final String text;

  final bool vertical;

  /// Colour around the lettering and of the lettering itself, as 0xRRGGBB.
  final int background;
  final int foreground;
}
