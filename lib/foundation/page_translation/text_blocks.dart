import 'dart:math' as math;

import 'ocr_types.dart';

/// Groups recognized lines into blocks (one speech bubble each), puts the
/// lines of a block in reading order and samples the colours around them.
List<TextBlock> groupLines(RgbaImage image, List<TextLine> lines) {
  var parent = List<int>.generate(lines.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      if (_belongTogether(lines[i].rect, lines[j].rect)) {
        parent[find(i)] = find(j);
      }
    }
  }

  var groups = <int, List<TextLine>>{};
  for (var i = 0; i < lines.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(lines[i]);
  }

  var blocks = <TextBlock>[];
  for (var group in groups.values) {
    var vertical = group.first.rect.isVertical;
    if (vertical) {
      // Columns are read from right to left.
      group.sort((a, b) => b.rect.right.compareTo(a.rect.right));
    } else {
      group.sort((a, b) => a.rect.top.compareTo(b.rect.top));
    }
    var rect = group.map((line) => line.rect).reduce((a, b) => a.union(b));
    var (background, foreground) = sampleColours(image, rect);
    blocks.add(TextBlock(
      rect: rect,
      lines: group,
      text: joinLines([for (var line in group) line.text]),
      vertical: vertical,
      background: background,
      foreground: foreground,
    ));
  }
  // Top to bottom; blocks starting at a similar height go right to left, the
  // usual order of bubbles on a manga page.
  blocks.sort((a, b) {
    var tolerance = math.min(a.rect.height, b.rect.height) / 2;
    if ((a.rect.top - b.rect.top).abs() > tolerance) {
      return a.rect.top.compareTo(b.rect.top);
    }
    return b.rect.right.compareTo(a.rect.right);
  });
  return blocks;
}

/// Whether two lines are neighbours in the same block: same direction, about
/// the same size, next to each other and overlapping along their length.
bool _belongTogether(PixelRect a, PixelRect b) {
  if (a.isVertical != b.isVertical) return false;
  if (a.isVertical) {
    return _neighbours(
      aStart: a.top,
      aEnd: a.bottom,
      bStart: b.top,
      bEnd: b.bottom,
      aNear: a.left,
      aFar: a.right,
      bNear: b.left,
      bFar: b.right,
    );
  }
  return _neighbours(
    aStart: a.left,
    aEnd: a.right,
    bStart: b.left,
    bEnd: b.right,
    aNear: a.top,
    aFar: a.bottom,
    bNear: b.top,
    bFar: b.bottom,
  );
}

/// [aStart]..[aEnd] is a line's extent along its length, [aNear]..[aFar] its
/// thickness; likewise for b.
bool _neighbours({
  required int aStart,
  required int aEnd,
  required int bStart,
  required int bEnd,
  required int aNear,
  required int aFar,
  required int bNear,
  required int bFar,
}) {
  var thicknessA = aFar - aNear, thicknessB = bFar - bNear;
  var thin = math.min(thicknessA, thicknessB);
  var thick = math.max(thicknessA, thicknessB);
  if (thin <= 0 || thick > thin * 1.8) return false;
  // Gap between the two lines across their thickness; negative when they
  // overlap, which the detector's grown boxes often do.
  var gap = math.max(aNear, bNear) - math.min(aFar, bFar);
  if (gap > thin * 0.9) return false;
  var overlap = math.min(aEnd, bEnd) - math.max(aStart, bStart);
  var shorter = math.min(aEnd - aStart, bEnd - bStart);
  return overlap >= shorter * 0.3;
}

/// Joins the lines of a block. Languages written with spaces get one between
/// lines; Chinese and Japanese do not.
String joinLines(List<String> lines) {
  var buffer = StringBuffer();
  for (var line in lines) {
    if (line.isEmpty) continue;
    if (buffer.isNotEmpty) {
      var previous = buffer.toString();
      if (previous.endsWith('-') && _isSpaced(line.runes.first)) {
        // A word broken across lines.
        buffer.clear();
        buffer.write(previous.substring(0, previous.length - 1));
      } else if (_isSpaced(previous.runes.last) || _isSpaced(line.runes.first)) {
        buffer.write(' ');
      }
    }
    buffer.write(line);
  }
  return buffer.toString();
}

/// A character of a script that separates words with spaces: anything below
/// the CJK ranges that is not itself a space, and Korean.
bool _isSpaced(int rune) =>
    (rune > 0x20 && rune < 0x2E80) ||
    (rune >= 0x3130 && rune <= 0x318F) ||
    (rune >= 0xAC00 && rune <= 0xD7AF);

/// The dominant colour inside [rect] and the colour of what stands out from
/// it, as 0xRRGGBB. With lettering on a plain bubble these are the bubble and
/// the ink.
(int background, int foreground) sampleColours(RgbaImage image, PixelRect rect) {
  rect = rect.clamp(image.width, image.height);
  if (rect.width <= 0 || rect.height <= 0) return (0xFFFFFF, 0x000000);
  // Luminance in 16 bins, with the colour sum of each bin.
  var counts = List<int>.filled(16, 0);
  var sums = List<int>.filled(16 * 3, 0);
  var step = math.max(1, math.max(rect.width, rect.height) ~/ 160);
  var pixels = image.pixels;
  for (var y = rect.top; y < rect.bottom; y += step) {
    for (var x = rect.left; x < rect.right; x += step) {
      var i = (y * image.width + x) * 4;
      var r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      var bin = ((r * 299 + g * 587 + b * 114) ~/ 1000) >> 4;
      counts[bin]++;
      sums[bin * 3] += r;
      sums[bin * 3 + 1] += g;
      sums[bin * 3 + 2] += b;
    }
  }
  var backgroundBin = 0;
  for (var bin = 1; bin < 16; bin++) {
    if (counts[bin] > counts[backgroundBin]) backgroundBin = bin;
  }
  int colourOf(Iterable<int> bins) {
    var n = 0, r = 0, g = 0, b = 0;
    for (var bin in bins) {
      n += counts[bin];
      r += sums[bin * 3];
      g += sums[bin * 3 + 1];
      b += sums[bin * 3 + 2];
    }
    if (n == 0) return -1;
    return ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
  }

  var background = colourOf([backgroundBin]);
  // The ink: everything at least six bins (about 96 levels) away.
  var foreground = colourOf([
    for (var bin = 0; bin < 16; bin++)
      if ((bin - backgroundBin).abs() >= 6) bin,
  ]);
  if (foreground < 0) {
    foreground = backgroundBin >= 8 ? 0x000000 : 0xFFFFFF;
  }
  return (background, foreground);
}
