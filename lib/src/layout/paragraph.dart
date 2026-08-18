/// Lines: how many, how wide, how far apart, and what did not fit.
///
/// This file owns the *vertical* half of layout and the greedy line fill. It
/// deliberately knows nothing about glyphs — it asks a callback to measure a
/// range and takes the answer. That seam is what lets the line fill be tested
/// against arithmetic instead of against a font, and it is what stops the
/// measurement used for breaking from drifting away from the measurement used
/// for drawing: [TextEngine] passes its own shaping path in.
library;

import '../api/text_style.dart';
import '../font/open_type_font.dart';
import '../font/tables/hhea.dart';
import '../util/tag.dart';
import 'line_breaker.dart';

/// The vertical metrics of one style, in points.
class LineMetrics {
  const LineMetrics({
    required this.ascent,
    required this.descent,
    required this.lineHeight,
  });

  /// Baseline to the top of the text. Positive.
  final double ascent;

  /// Baseline downward. Positive, even though `hhea.descender` is negative —
  /// a caller doing `y - descent` should not have to know which sign
  /// convention the font table used.
  final double descent;

  /// Baseline to baseline.
  final double lineHeight;

  /// Resolves [style] against its font.
  ///
  /// `hhea` is the source, not `OS/2`, and the choice is not arbitrary: a font
  /// carries up to three metric families (`hhea`, `OS/2.sTypo*`,
  /// `OS/2.usWin*`) and they disagree — Vazirmatn's `hhea` ascent and its typo
  /// ascent differ by a fifth of an em. `hhea` is what a rasteriser uses and
  /// what every browser resolves `normal` line-height from, so it is the one
  /// that makes our line spacing look like everyone else's. The single
  /// exception is a font that sets `fsSelection` bit 7, USE_TYPO_METRICS,
  /// which is the foundry stating outright that the typo family is the correct
  /// one; honouring that bit is the whole reason it was defined.
  factory LineMetrics.forStyle(TextStyle style) {
    final font = style.font.raw;
    final hhea = _hheaOf(font);
    final os2 = font.os2;

    final int rawAscent;
    final int rawDescent;
    final int rawGap;
    if (os2 != null && os2.useTypoMetrics && os2.sTypoAscender != 0) {
      rawAscent = os2.sTypoAscender;
      rawDescent = os2.sTypoDescender;
      rawGap = os2.sTypoLineGap;
    } else {
      rawAscent = hhea.ascender;
      rawDescent = hhea.descender;
      rawGap = hhea.lineGap;
    }

    final scale = style.size / font.unitsPerEm;
    return LineMetrics(
      ascent: rawAscent * scale,
      descent: -rawDescent * scale,
      lineHeight: style.lineHeight ?? (rawAscent - rawDescent + rawGap) * scale,
    );
  }

  /// Parsed `hhea`, cached per font object.
  ///
  /// [OpenTypeFont] exposes `numberOfHMetrics` but not the table, and reaching
  /// through `sfnt` here is cheaper than widening that facade for one caller.
  /// The [Expando] keeps the cache from outliving the font.
  static HheaTable _hheaOf(OpenTypeFont font) {
    final cached = _hheaCache[font];
    if (cached != null) return cached;
    final parsed = HheaTable.parse(font.sfnt.requireTable(Tag.hhea));
    _hheaCache[font] = parsed;
    return parsed;
  }

  static final Expando<HheaTable> _hheaCache = Expando<HheaTable>('hhea');

  @override
  String toString() =>
      'LineMetrics(asc ${ascent.toStringAsFixed(2)}, '
      'desc ${descent.toStringAsFixed(2)}, '
      'leading ${lineHeight.toStringAsFixed(2)})';
}

/// One line of a broken paragraph, in the source string's own indices.
class LineBox {
  const LineBox({
    required this.start,
    required this.end,
    required this.nextStart,
    required this.width,
    required this.endsParagraph,
  });

  /// UTF-16 range of the text drawn on this line. [end] already has trailing
  /// spaces trimmed, so [width] and the range agree.
  final int start;
  final int end;

  /// Where the next line's text begins — past the hard break, or past the
  /// spaces this line ended on. What [TextEngine.drawBox] returns as leftover
  /// text is `text.substring(nextStart)` of the last line that fitted.
  final int nextStart;

  /// Measured width in points, trailing space excluded.
  final double width;

  /// True when this line ends at a hard break or at the end of the text —
  /// i.e. when justification must leave it alone.
  final bool endsParagraph;

  bool get isEmpty => end <= start;

  @override
  String toString() => 'LineBox($start..$end, ${width.toStringAsFixed(1)}pt)';
}

/// A line placed on the page: its text and the baseline to draw it on.
class PlacedLine {
  const PlacedLine(this.line, this.baseline);

  final LineBox line;

  /// PDF user-space y of the baseline.
  final double baseline;
}

/// The result of fitting broken lines into a box.
class BoxFit {
  const BoxFit(this.placed, this.overflowFrom);

  final List<PlacedLine> placed;

  /// UTF-16 index where the text that did NOT fit begins, or null when it all
  /// did. Callers turn this into a substring and flow it onto the next page,
  /// which is why it is an index into the ORIGINAL string and not a copy.
  final int? overflowFrom;
}

abstract final class Paragraph {
  /// Greedily fills lines of at most [maxWidth] points.
  ///
  /// Greedy, not Knuth–Plass. Optimal paragraph breaking buys visibly better
  /// rag in a book; on a bill — short label/value lines, one or two wrapped
  /// sentences — it buys nothing and costs a dynamic program whose cost model
  /// nobody here would be able to justify a value in.
  ///
  /// [measure] is given a UTF-16 range and returns its width in points. It is
  /// called on candidate ranges repeatedly, so an implementation should cache;
  /// what it must NOT do is approximate, because a width that disagrees with
  /// the drawing path produces lines that overflow the box they were measured
  /// against.
  static List<LineBox> breakLines({
    required String text,
    required double maxWidth,
    required double Function(int start, int end) measure,
  }) {
    final lines = <LineBox>[];
    if (text.isEmpty) return lines;

    final opportunities = LineBreaker.opportunities(text);
    var start = 0;
    var next = 0; // index into opportunities

    while (start < text.length) {
      // Skip opportunities that no longer lie ahead of the cursor — they were
      // consumed by the previous line.
      while (next < opportunities.length &&
          opportunities[next].contentEnd <= start) {
        next++;
      }
      if (next >= opportunities.length) break;

      var chosen = -1;
      var chosenWidth = 0.0;
      var i = next;
      for (; i < opportunities.length; i++) {
        final o = opportunities[i];
        final end = LineBreaker.trimTrailing(text, start, o.contentEnd);
        final width = end <= start ? 0.0 : measure(start, end);
        if (width > maxWidth && chosen >= 0) break;
        chosen = i;
        chosenWidth = width;
        // A mandatory break ends the line whether or not it overflows: the
        // author asked for it, and honouring the width instead would silently
        // lose their paragraph structure.
        if (o.mandatory) break;
        if (width > maxWidth) break;
      }

      if (chosen < 0) break;
      final o = opportunities[chosen];
      var end = LineBreaker.trimTrailing(text, start, o.contentEnd);
      var nextStart = o.nextStart;
      var endsParagraph = o.mandatory;

      // Emergency break: one unbreakable chunk is wider than the box. Split it
      // at a grapheme boundary rather than let it run off the edge, where
      // nothing in the output would say it had.
      if (chosenWidth > maxWidth && chosen == next) {
        final split = _emergencySplit(
          text: text,
          start: start,
          end: end,
          maxWidth: maxWidth,
          measure: measure,
        );
        if (split != null) {
          end = split;
          nextStart = split;
          endsParagraph = false;
        }
      }

      lines.add(
        LineBox(
          start: start,
          end: end,
          nextStart: nextStart,
          width: end <= start ? 0.0 : measure(start, end),
          endsParagraph: endsParagraph,
        ),
      );

      // A hard break at the cursor produces an empty line, which is correct —
      // a blank line in the source is a blank line on the page — but the
      // cursor must still advance or this loops forever.
      start = nextStart > start ? nextStart : start + 1;
    }

    return lines;
  }

  /// The largest grapheme boundary in `(start, end)` that still fits, or null
  /// when not even one cluster does.
  static int? _emergencySplit({
    required String text,
    required int start,
    required int end,
    required double maxWidth,
    required double Function(int start, int end) measure,
  }) {
    final starts = LineBreaker.graphemeStarts(text, start, end);
    int? best;
    for (final at in starts) {
      if (at <= start) continue;
      if (measure(start, at) > maxWidth) break;
      best = at;
    }
    return best;
  }

  /// Stacks [lines] downward from the top of [rect].
  ///
  /// A line is placed only if its whole extent — baseline plus descent — is
  /// still inside the box. Placing a line whose descenders are clipped is how
  /// a "fits" answer turns into a page with a row of severed tails on it.
  static BoxFit fitInBox({
    required List<LineBox> lines,
    required PdfRect rect,
    required LineMetrics metrics,
  }) {
    final placed = <PlacedLine>[];
    var baseline = rect.top - metrics.ascent;

    for (var i = 0; i < lines.length; i++) {
      if (baseline - metrics.descent < rect.bottom - _epsilon) {
        return BoxFit(placed, lines[i].start);
      }
      placed.add(PlacedLine(lines[i], baseline));
      baseline -= metrics.lineHeight;
    }
    return BoxFit(placed, null);
  }

  /// A tenth of a micrometre at 72 dpi. Slack for the accumulated rounding of
  /// a page of line heights, not for a real overflow.
  static const double _epsilon = 1e-6;
}
