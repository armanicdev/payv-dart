/// Resolved glyph outlines — the geometry half of a font, in design units.
///
/// `glyf` stores quadratic B-splines; PDF has no quadratic operator. So this
/// file owns both representations and the exact conversion between them, and
/// nothing else in `payv` is allowed to guess at curve maths. A [GlyphPath] is
/// a value: it knows nothing about a canvas, a page, or a transform. The PDF
/// writer is the only thing that turns one into bytes.
library;

import 'dart:math' as math;

/// An axis-aligned rectangle in font design units.
///
/// Deliberately not `dart:ui`'s `Rect`: `payv` compiles on a plain Dart VM with
/// no Flutter, and design-unit space is y-UP, so a `top`/`bottom` pair borrowed
/// from a y-down UI framework would read inverted at every call site. The four
/// names here are the ones the `glyf` header itself uses.
class Rect {
  const Rect(this.xMin, this.yMin, this.xMax, this.yMax);

  /// The degenerate rectangle an empty glyph reports.
  static const Rect zero = Rect(0, 0, 0, 0);

  final double xMin;
  final double yMin;
  final double xMax;
  final double yMax;

  double get width => xMax - xMin;

  double get height => yMax - yMin;

  /// True when the rectangle encloses no area — an empty glyph, or a glyph
  /// whose ink is a single horizontal or vertical hairline.
  bool get isEmpty => xMax <= xMin || yMax <= yMin;

  Rect union(Rect other) => Rect(
    math.min(xMin, other.xMin),
    math.min(yMin, other.yMin),
    math.max(xMax, other.xMax),
    math.max(yMax, other.yMax),
  );

  Rect scaled(double scale) =>
      Rect(xMin * scale, yMin * scale, xMax * scale, yMax * scale);

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.xMin == xMin &&
      other.yMin == yMin &&
      other.xMax == xMax &&
      other.yMax == yMax;

  @override
  int get hashCode => Object.hash(xMin, yMin, xMax, yMax);

  @override
  String toString() => 'Rect($xMin, $yMin, $xMax, $yMax)';
}

/// One segment of an outline.
///
/// Sealed so that a `switch` over the five cases is exhaustive: a sixth command
/// added later becomes a compile error in the PDF writer rather than a silently
/// dropped curve.
sealed class PathCommand {
  const PathCommand();
}

final class MoveTo extends PathCommand {
  const MoveTo(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => 'MoveTo($x, $y)';
}

final class LineTo extends PathCommand {
  const LineTo(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => 'LineTo($x, $y)';
}

/// A quadratic Bézier with a single control point — what `glyf` actually
/// stores.
final class QuadTo extends PathCommand {
  const QuadTo(this.cx, this.cy, this.x, this.y);

  final double cx;
  final double cy;
  final double x;
  final double y;

  @override
  String toString() => 'QuadTo($cx, $cy, $x, $y)';
}

final class CubicTo extends PathCommand {
  const CubicTo(this.c1x, this.c1y, this.c2x, this.c2y, this.x, this.y);

  final double c1x;
  final double c1y;
  final double c2x;
  final double c2y;
  final double x;
  final double y;

  @override
  String toString() => 'CubicTo($c1x, $c1y, $c2x, $c2y, $x, $y)';
}

final class ClosePath extends PathCommand {
  const ClosePath();

  @override
  String toString() => 'ClosePath()';
}

/// A resolved outline in font design units.
///
/// Built by [GlyfTable.outline] and consumed by the PDF writer. Curves are kept
/// as the quadratics the font stores; [cubicCommands] and [toPdfPath] convert.
class GlyphPath {
  GlyphPath();

  final List<PathCommand> _commands = <PathCommand>[];

  /// The raw command list. Exposed directly rather than copied — glyph paths
  /// are re-emitted once per drawn glyph and a defensive copy per call would
  /// dominate the cost of writing a page. Treat it as read-only.
  List<PathCommand> get commands => _commands;

  bool get isEmpty => _commands.isEmpty;

  bool get isNotEmpty => _commands.isNotEmpty;

  Rect? _bounds;

  // The builder deliberately keeps no current point. Every consumer — the
  // cubic promotion, the bounds walk, the PDF emitter — has to re-walk the
  // command list anyway, and each already tracks the pen itself; a second copy
  // on the object would be one more thing to keep in step for no reader.

  void moveTo(double x, double y) {
    _commands.add(MoveTo(x, y));
    _bounds = null;
  }

  void lineTo(double x, double y) {
    _commands.add(LineTo(x, y));
    _bounds = null;
  }

  void quadraticTo(double cx, double cy, double x, double y) {
    _commands.add(QuadTo(cx, cy, x, y));
    _bounds = null;
  }

  void cubicTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y,
  ) {
    _commands.add(CubicTo(c1x, c1y, c2x, c2y, x, y));
    _bounds = null;
  }

  void close() {
    _commands.add(const ClosePath());
    _bounds = null;
  }

  /// The same outline with every quadratic promoted to a cubic.
  ///
  /// The promotion is exact, not an approximation: a quadratic is a cubic whose
  /// control points sit two-thirds of the way from each endpoint to the single
  /// quadratic control point. Nothing is resampled and no tolerance is chosen,
  /// which is why a PDF drawn from this is identical to what a rasteriser using
  /// the quadratics would produce.
  List<PathCommand> get cubicCommands {
    final out = <PathCommand>[];
    var px = 0.0;
    var py = 0.0;
    var sx = 0.0;
    var sy = 0.0;
    for (final c in _commands) {
      switch (c) {
        case MoveTo():
          out.add(c);
          px = sx = c.x;
          py = sy = c.y;
        case LineTo():
          out.add(c);
          px = c.x;
          py = c.y;
        case QuadTo():
          out.add(_quadToCubic(px, py, c));
          px = c.x;
          py = c.y;
        case CubicTo():
          out.add(c);
          px = c.x;
          py = c.y;
        case ClosePath():
          out.add(c);
          px = sx;
          py = sy;
      }
    }
    return out;
  }

  /// Tight ink bounds, in the same units as the path.
  ///
  /// "Tight" matters: the control-point hull of a curve can overshoot the real
  /// ink by a large fraction of an em on a font with long extrema handles, and
  /// a PDF `/BBox` or a layout box built from the hull would be visibly wrong.
  /// So the curve extrema are solved rather than bounded.
  Rect get bounds => _bounds ??= _computeBounds();

  Rect _computeBounds() {
    if (_commands.isEmpty) return Rect.zero;

    var xMin = double.infinity;
    var yMin = double.infinity;
    var xMax = double.negativeInfinity;
    var yMax = double.negativeInfinity;

    void include(double x, double y) {
      if (x < xMin) xMin = x;
      if (x > xMax) xMax = x;
      if (y < yMin) yMin = y;
      if (y > yMax) yMax = y;
    }

    var px = 0.0;
    var py = 0.0;
    var sx = 0.0;
    var sy = 0.0;
    for (final c in _commands) {
      switch (c) {
        case MoveTo():
          include(c.x, c.y);
          px = sx = c.x;
          py = sy = c.y;
        case LineTo():
          include(c.x, c.y);
          px = c.x;
          py = c.y;
        case QuadTo():
          include(c.x, c.y);
          _quadExtrema(
            px,
            c.cx,
            c.x,
            (t) =>
                include(_quadAt(px, c.cx, c.x, t), _quadAt(py, c.cy, c.y, t)),
          );
          _quadExtrema(
            py,
            c.cy,
            c.y,
            (t) =>
                include(_quadAt(px, c.cx, c.x, t), _quadAt(py, c.cy, c.y, t)),
          );
          px = c.x;
          py = c.y;
        case CubicTo():
          include(c.x, c.y);
          void sample(double t) => include(
            _cubicAt(px, c.c1x, c.c2x, c.x, t),
            _cubicAt(py, c.c1y, c.c2y, c.y, t),
          );
          _cubicExtrema(px, c.c1x, c.c2x, c.x, sample);
          _cubicExtrema(py, c.c1y, c.c2y, c.y, sample);
          px = c.x;
          py = c.y;
        case ClosePath():
          px = sx;
          py = sy;
      }
    }

    if (xMin > xMax) return Rect.zero;
    return Rect(xMin, yMin, xMax, yMax);
  }

  /// Emits a PDF content-stream path (`m` / `l` / `c` / `h`) scaled by [scale].
  ///
  /// [scale] is normally `1 / unitsPerEm` (into text space) or a point size over
  /// the em; either way the multiply happens here, once, so that everything
  /// upstream — shaping, variation, positioning — stays in integer-exact design
  /// units and remains comparable with HarfBuzz's unscaled output.
  String toPdfPath({double scale = 1.0}) {
    final b = StringBuffer();
    var px = 0.0;
    var py = 0.0;
    var sx = 0.0;
    var sy = 0.0;
    var first = true;

    void op(String name, List<double> args) {
      if (!first) b.write('\n');
      first = false;
      for (final a in args) {
        b
          ..write(_fmt(a * scale))
          ..write(' ');
      }
      b.write(name);
    }

    for (final c in _commands) {
      switch (c) {
        case MoveTo():
          op('m', <double>[c.x, c.y]);
          px = sx = c.x;
          py = sy = c.y;
        case LineTo():
          op('l', <double>[c.x, c.y]);
          px = c.x;
          py = c.y;
        case QuadTo():
          final k = _quadToCubic(px, py, c);
          op('c', <double>[k.c1x, k.c1y, k.c2x, k.c2y, k.x, k.y]);
          px = c.x;
          py = c.y;
        case CubicTo():
          op('c', <double>[c.c1x, c.c1y, c.c2x, c.c2y, c.x, c.y]);
          px = c.x;
          py = c.y;
        case ClosePath():
          op('h', const <double>[]);
          px = sx;
          py = sy;
      }
    }
    return b.toString();
  }

  @override
  String toString() => 'GlyphPath(${_commands.length} commands, $bounds)';
}

/// The exact quadratic-to-cubic promotion: `c1 = p0 + 2/3·(q − p0)`,
/// `c2 = p2 + 2/3·(q − p2)`.
CubicTo _quadToCubic(double px, double py, QuadTo q) => CubicTo(
  px + 2.0 / 3.0 * (q.cx - px),
  py + 2.0 / 3.0 * (q.cy - py),
  q.x + 2.0 / 3.0 * (q.cx - q.x),
  q.y + 2.0 / 3.0 * (q.cy - q.y),
  q.x,
  q.y,
);

double _quadAt(double p0, double p1, double p2, double t) {
  final u = 1.0 - t;
  return u * u * p0 + 2 * u * t * p1 + t * t * p2;
}

double _cubicAt(double p0, double p1, double p2, double p3, double t) {
  final u = 1.0 - t;
  return u * u * u * p0 +
      3 * u * u * t * p1 +
      3 * u * t * t * p2 +
      t * t * t * p3;
}

/// Calls [onT] for the single interior stationary point of a quadratic, if any.
void _quadExtrema(double p0, double p1, double p2, void Function(double) onT) {
  final denom = p0 - 2 * p1 + p2;
  if (denom == 0) return;
  final t = (p0 - p1) / denom;
  if (t > 0 && t < 1) onT(t);
}

/// Calls [onT] for each interior stationary point of a cubic. The derivative is
/// a quadratic, so there are at most two.
void _cubicExtrema(
  double p0,
  double p1,
  double p2,
  double p3,
  void Function(double) onT,
) {
  final d1 = p1 - p0;
  final d2 = p2 - p1;
  final d3 = p3 - p2;
  final a = d1 - 2 * d2 + d3;
  final b = 2 * (d2 - d1);
  final c = d1;

  if (a == 0) {
    if (b == 0) return;
    final t = -c / b;
    if (t > 0 && t < 1) onT(t);
    return;
  }
  final disc = b * b - 4 * a * c;
  if (disc < 0) return;
  final root = math.sqrt(disc);
  for (final t in <double>[(-b + root) / (2 * a), (-b - root) / (2 * a)]) {
    if (t > 0 && t < 1) onT(t);
  }
}

/// Formats a PDF real.
///
/// PDF has no exponent syntax, so `toString()` is unusable the moment a
/// coordinate is scaled into text space and lands on `4.8828125e-4`.
/// `toStringAsFixed` never produces an exponent; the trailing zeros it does
/// produce are trimmed by hand rather than by a `RegExp`, because this runs
/// once per coordinate of every glyph on every page.
String _fmt(double v) {
  if (!v.isFinite) return '0';
  if (v == 0) return '0'; // also collapses -0.0, which some viewers reject
  final s = v.toStringAsFixed(6);
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && s.codeUnitAt(end - 1) == 0x2E) end--;
  final trimmed = s.substring(0, end);
  return trimmed == '-0' || trimmed.isEmpty ? '0' : trimmed;
}
