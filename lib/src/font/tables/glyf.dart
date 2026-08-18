/// `glyf` + `loca` — TrueType outlines.
///
/// The encoding is from 1991 and shows it: coordinates are stored as deltas in
/// a flag-directed mix of 8- and 16-bit fields, on-curve points can be OMITTED
/// entirely when two off-curve points meet, and a glyph may be assembled out of
/// other glyphs with a 2×2 transform or by matching a point number against a
/// point number. Every one of those is a place a reimplementation quietly gets
/// a glyph slightly wrong, so each is handled explicitly below rather than in a
/// clever loop.
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';
import '../glyph_path.dart';
import '../variations/gvar.dart';

/// Simple-glyph point flags.
const int _flagOnCurve = 0x01;
const int _flagXShort = 0x02;
const int _flagYShort = 0x04;
const int _flagRepeat = 0x08;
const int _flagXSameOrPositive = 0x10;
const int _flagYSameOrPositive = 0x20;

/// Composite component flags.
/// Composite component flags.
///
/// Three of the spec's flags are read and deliberately not acted on, so they
/// have no constant here: `ROUND_XY_TO_GRID` (0x0004) and `WE_HAVE_INSTRUCTIONS`
/// (0x0100) only mean something to a hinted rasteriser, and `USE_MY_METRICS`
/// (0x0200) redirects `hmtx`, not geometry — it belongs to whoever asks for an
/// advance, not to outline extraction.
const int _compArgsAreWords = 0x0001;
const int _compArgsAreXy = 0x0002;
const int _compHaveScale = 0x0008;
const int _compMoreComponents = 0x0020;
const int _compHaveXAndYScale = 0x0040;
const int _compHaveTwoByTwo = 0x0080;
const int _compScaledOffset = 0x0800;

/// A composite that nests deeper than this is either malicious or broken; real
/// fonts stop at two or three (base letter → accented letter → small-cap form).
const int _maxCompositeDepth = 8;

/// A glyph's points, in final position, before they become curves.
///
/// Composites are resolved at the POINT level rather than by concatenating
/// child paths, because `ARGS_ARE_XY_VALUES`-clear components position
/// themselves by matching a point number in the composite so far against one in
/// the component — which a list of path commands can no longer answer.
class _Outline {
  _Outline(this.xs, this.ys, this.onCurve, this.endPoints);

  final List<double> xs;
  final List<double> ys;
  final List<bool> onCurve;

  /// Index of the last point of each contour.
  final List<int> endPoints;
}

class _Component {
  _Component({
    required this.flags,
    required this.glyphId,
    required this.arg1,
    required this.arg2,
    required this.xx,
    required this.xy,
    required this.yx,
    required this.yy,
  });

  final int flags;
  final int glyphId;
  final int arg1;
  final int arg2;
  final double xx;
  final double xy;
  final double yx;
  final double yy;

  /// `gvar` moves a composite by moving its components' offsets, so the delta
  /// lands here rather than on the child's points.
  double varDx = 0;
  double varDy = 0;

  bool get argsAreXy => flags & _compArgsAreXy != 0;
}

/// A parsed `glyf`/`loca` pair.
class GlyfTable {
  GlyfTable._({
    required ByteReader glyf,
    required ByteReader loca,
    required bool longLoca,
    required int numGlyphs,
    required int glyfEnd,
  }) : _r = glyf,
       _glyfAt = glyf.position,
       _loca = loca,
       _locaAt = loca.position,
       _longLoca = longLoca,
       _numGlyphs = numGlyphs,
       _glyfEnd = glyfEnd;

  static GlyfTable parse(
    ByteReader r, {
    required ByteReader loca,
    required int indexToLocFormat,
    required int numGlyphs,
  }) {
    if (indexToLocFormat != 0 && indexToLocFormat != 1) {
      throw FontFormatException(
        'head.indexToLocFormat is $indexToLocFormat, not 0 or 1',
      );
    }
    if (numGlyphs < 0) {
      throw FontFormatException('numGlyphs is $numGlyphs');
    }
    final longLoca = indexToLocFormat == 1;
    final entry = longLoca ? 4 : 2;
    // `loca` holds numGlyphs + 1 entries; the extra one bounds the last glyph.
    if (!loca.canRead(loca.position, (numGlyphs + 1) * entry)) {
      throw FontFormatException(
        'loca is too short for ${numGlyphs + 1} entries',
      );
    }
    final glyfEnd = longLoca
        ? loca.uint32At(loca.position + numGlyphs * 4)
        : loca.uint16At(loca.position + numGlyphs * 2) * 2;

    return GlyfTable._(
      glyf: r,
      loca: loca,
      longLoca: longLoca,
      numGlyphs: numGlyphs,
      glyfEnd: glyfEnd,
    );
  }

  final ByteReader _r;
  final int _glyfAt;
  final ByteReader _loca;
  final int _locaAt;
  final bool _longLoca;
  final int _numGlyphs;

  /// Offset of the end of the last glyph, relative to `glyf`. Every glyph range
  /// is validated against this rather than against the file, so a corrupt
  /// `loca` cannot walk a "glyph" out of the table and into `GSUB`.
  final int _glyfEnd;

  int get numGlyphs => _numGlyphs;

  /// `[start, end)` of [glyphId]'s data, relative to the start of `glyf`.
  ///
  /// `start == end` is not an error — it is how the format spells "this glyph
  /// has no outline", which is what `space` is.
  (int, int) locaRange(int glyphId) {
    if (glyphId < 0 || glyphId >= _numGlyphs) {
      throw RangeError.index(glyphId, this, 'glyphId', null, _numGlyphs);
    }
    final start = _locaEntry(glyphId);
    final end = _locaEntry(glyphId + 1);
    if (end < start || end > _glyfEnd) {
      throw FontFormatException(
        'loca entry for glyph $glyphId is $start..$end, outside 0..$_glyfEnd',
      );
    }
    return (start, end);
  }

  int _locaEntry(int index) => _longLoca
      ? _loca.uint32At(_locaAt + index * 4)
      // The short format stores every offset halved, which is why a short
      // `loca` caps `glyf` at 128 KB and why this multiply is not optional.
      : _loca.uint16At(_locaAt + index * 2) * 2;

  /// Raw bytes of one glyph, for the subsetter — which copies glyph data it has
  /// no reason to decode. Null for an empty glyph or an unknown id.
  Uint8List? glyphBytes(int glyphId) {
    if (glyphId < 0 || glyphId >= _numGlyphs) return null;
    final (start, end) = locaRange(glyphId);
    if (end <= start) return null;
    return _r.bytesAt(_glyfAt + start, end - start);
  }

  /// The glyph's own bounding box as the font records it, in design units.
  ///
  /// This is the STATIC box: it does not move with a variation instance, and
  /// some tooling writes it loosely. Use [GlyphPath.bounds] when the answer has
  /// to be exact.
  Rect? boundingBox(int glyphId) {
    if (glyphId < 0 || glyphId >= _numGlyphs) return null;
    final (start, end) = locaRange(glyphId);
    if (end - start < 10) return null;
    final at = _glyfAt + start;
    return Rect(
      _r.int16At(at + 2).toDouble(),
      _r.int16At(at + 4).toDouble(),
      _r.int16At(at + 6).toDouble(),
      _r.int16At(at + 8).toDouble(),
    );
  }

  /// The resolved outline of [glyphId], or null for an empty glyph.
  ///
  /// A null return is legal and common — `space` has no contours — and must not
  /// be treated as a failure. Pass [coords] (normalised) together with [gvar] to
  /// get the outline at a point in variation space.
  GlyphPath? outline(int glyphId, {List<double>? coords, GvarTable? gvar}) {
    final outline = _resolve(glyphId, coords, gvar, 0);
    if (outline == null || outline.endPoints.isEmpty) return null;
    return _toPath(outline);
  }

  // ── resolution ────────────────────────────────────────────────────────────

  _Outline? _resolve(
    int glyphId,
    List<double>? coords,
    GvarTable? gvar,
    int depth,
  ) {
    if (glyphId < 0 || glyphId >= _numGlyphs) return null;
    final (start, end) = locaRange(glyphId);
    if (end - start < 10) return null; // empty, or too short to hold a header

    final base = _glyfAt + start;
    final limit = _glyfAt + end;
    final numberOfContours = _r.int16At(base);
    return numberOfContours >= 0
        ? _parseSimple(glyphId, base, limit, numberOfContours, coords, gvar)
        : _parseComposite(glyphId, base, limit, coords, gvar, depth);
  }

  _Outline? _parseSimple(
    int glyphId,
    int base,
    int limit,
    int numberOfContours,
    List<double>? coords,
    GvarTable? gvar,
  ) {
    if (numberOfContours == 0) return null;

    var p = base + 10;
    final endPoints = List<int>.filled(numberOfContours, 0);
    for (var i = 0; i < numberOfContours; i++) {
      endPoints[i] = _r.uint16At(p);
      p += 2;
      if (i > 0 && endPoints[i] < endPoints[i - 1]) {
        throw FontFormatException(
          'glyph $glyphId has non-monotonic contour ends',
        );
      }
    }
    final numPoints = endPoints[numberOfContours - 1] + 1;

    final instructionLength = _r.uint16At(p);
    p += 2 + instructionLength; // hinting bytecode: never executed here

    // Flags, run-length encoded. The repeat count is CLAMPED rather than
    // trusted — a font that repeats past the last point is broken, but it must
    // not be able to make us write past the array.
    final flags = Uint8List(numPoints);
    var i = 0;
    while (i < numPoints) {
      final f = _r.uint8At(p);
      p += 1;
      flags[i] = f;
      i += 1;
      if (f & _flagRepeat != 0) {
        var repeat = _r.uint8At(p);
        p += 1;
        while (repeat > 0 && i < numPoints) {
          flags[i] = f;
          i += 1;
          repeat -= 1;
        }
      }
    }

    final xs = List<double>.filled(numPoints, 0);
    var x = 0;
    for (var k = 0; k < numPoints; k++) {
      final f = flags[k];
      if (f & _flagXShort != 0) {
        // One unsigned byte; the SAME bit doubles as the sign.
        final d = _r.uint8At(p);
        p += 1;
        x += f & _flagXSameOrPositive != 0 ? d : -d;
      } else if (f & _flagXSameOrPositive == 0) {
        x += _r.int16At(p);
        p += 2;
      }
      xs[k] = x.toDouble();
    }

    final ys = List<double>.filled(numPoints, 0);
    var y = 0;
    for (var k = 0; k < numPoints; k++) {
      final f = flags[k];
      if (f & _flagYShort != 0) {
        final d = _r.uint8At(p);
        p += 1;
        y += f & _flagYSameOrPositive != 0 ? d : -d;
      } else if (f & _flagYSameOrPositive == 0) {
        y += _r.int16At(p);
        p += 2;
      }
      ys[k] = y.toDouble();
    }

    if (p > limit) {
      throw FontFormatException(
        'glyph $glyphId reads ${p - limit} byte(s) past its loca range',
      );
    }

    final onCurve = List<bool>.generate(
      numPoints,
      (k) => flags[k] & _flagOnCurve != 0,
      growable: false,
    );

    if (coords != null && gvar != null && coords.isNotEmpty) {
      _applySimpleDeltas(glyphId, coords, gvar, xs, ys, endPoints);
    }
    return _Outline(xs, ys, onCurve, endPoints);
  }

  /// Moves a simple glyph's points to [coords].
  ///
  /// `gvar` indexes four PHANTOM points after the real ones — the two sidebearing
  /// origins and the two vertical ones — so the point count handed to it is
  /// `numPoints + 4`. Their deltas are read and discarded: advances come from
  /// `HVAR`, and the phantoms belong to no contour, so their coordinates can be
  /// left at zero without affecting the interpolation of any real point.
  void _applySimpleDeltas(
    int glyphId,
    List<double> coords,
    GvarTable gvar,
    List<double> xs,
    List<double> ys,
    List<int> endPoints,
  ) {
    final numPoints = xs.length;
    final total = numPoints + 4;
    final px = List<double>.filled(total, 0);
    final py = List<double>.filled(total, 0);
    for (var k = 0; k < numPoints; k++) {
      px[k] = xs[k];
      py[k] = ys[k];
    }
    final deltas = gvar.deltas(
      glyphId,
      coords,
      total,
      contourEnds: endPoints,
      xs: px,
      ys: py,
    );
    if (deltas == null) return;
    for (var k = 0; k < numPoints; k++) {
      xs[k] += deltas[k].$1;
      ys[k] += deltas[k].$2;
    }
  }

  _Outline? _parseComposite(
    int glyphId,
    int base,
    int limit,
    List<double>? coords,
    GvarTable? gvar,
    int depth,
  ) {
    if (depth >= _maxCompositeDepth) {
      throw FontFormatException(
        'composite glyph $glyphId nests deeper than $_maxCompositeDepth',
      );
    }

    final components = <_Component>[];
    var p = base + 10;
    while (true) {
      final flags = _r.uint16At(p);
      final componentGlyph = _r.uint16At(p + 2);
      p += 4;

      final int arg1;
      final int arg2;
      if (flags & _compArgsAreWords != 0) {
        // Offsets are signed; point numbers are not. Reading a point number as
        // signed would silently break any composite with more than 32767
        // points in scope — rare, but the branch costs nothing.
        if (flags & _compArgsAreXy != 0) {
          arg1 = _r.int16At(p);
          arg2 = _r.int16At(p + 2);
        } else {
          arg1 = _r.uint16At(p);
          arg2 = _r.uint16At(p + 2);
        }
        p += 4;
      } else {
        if (flags & _compArgsAreXy != 0) {
          arg1 = _r.int8At(p);
          arg2 = _r.int8At(p + 1);
        } else {
          arg1 = _r.uint8At(p);
          arg2 = _r.uint8At(p + 1);
        }
        p += 2;
      }

      var xx = 1.0;
      var xy = 0.0;
      var yx = 0.0;
      var yy = 1.0;
      if (flags & _compHaveScale != 0) {
        xx = yy = _r.f2dot14At(p);
        p += 2;
      } else if (flags & _compHaveXAndYScale != 0) {
        xx = _r.f2dot14At(p);
        yy = _r.f2dot14At(p + 2);
        p += 4;
      } else if (flags & _compHaveTwoByTwo != 0) {
        xx = _r.f2dot14At(p);
        xy = _r.f2dot14At(p + 2);
        yx = _r.f2dot14At(p + 4);
        yy = _r.f2dot14At(p + 6);
        p += 8;
      }

      components.add(
        _Component(
          flags: flags,
          glyphId: componentGlyph,
          arg1: arg1,
          arg2: arg2,
          xx: xx,
          xy: xy,
          yx: yx,
          yy: yy,
        ),
      );

      if (flags & _compMoreComponents == 0) break;
      if (p >= limit) {
        throw FontFormatException(
          'composite glyph $glyphId runs past its loca range',
        );
      }
    }

    // `gvar` treats a composite as one "point" per component plus the same four
    // phantoms. No IUP: the points are offsets, not geometry, and a component
    // no master moved simply does not move.
    if (coords != null && gvar != null && coords.isNotEmpty) {
      final deltas = gvar.deltas(glyphId, coords, components.length + 4);
      if (deltas != null) {
        for (var i = 0; i < components.length; i++) {
          components[i].varDx = deltas[i].$1;
          components[i].varDy = deltas[i].$2;
        }
      }
    }

    final xs = <double>[];
    final ys = <double>[];
    final onCurve = <bool>[];
    final endPoints = <int>[];

    for (final c in components) {
      final child = _resolve(c.glyphId, coords, gvar, depth + 1);
      if (child == null) continue; // an empty component contributes no points

      final n = child.xs.length;
      final tx = List<double>.filled(n, 0);
      final ty = List<double>.filled(n, 0);
      for (var k = 0; k < n; k++) {
        // x' = a·x + c·y, y' = b·x + d·y — the spec's own ordering, where the
        // 2×2 is read as (xscale, scale01, scale10, yscale).
        tx[k] = c.xx * child.xs[k] + c.yx * child.ys[k];
        ty[k] = c.xy * child.xs[k] + c.yy * child.ys[k];
      }

      double ox;
      double oy;
      if (c.argsAreXy) {
        ox = c.arg1.toDouble();
        oy = c.arg2.toDouble();
        if (c.flags & _compScaledOffset != 0) {
          // Apple's reading of the offset: it moves with the component's own
          // scale. Microsoft's — the default, and what nearly every font
          // means — leaves it in the composite's units.
          final sx = c.xx * ox + c.yx * oy;
          final sy = c.xy * ox + c.yy * oy;
          ox = sx;
          oy = sy;
        }
        // ROUND_XY_TO_GRID is deliberately ignored: it rounds to the DEVICE
        // grid during hinted rasterisation, and we emit unhinted design-unit
        // outlines. Honouring it here would quantise away the fractional
        // component offsets `gvar` produces. HarfBuzz ignores it for the same
        // reason.
      } else {
        // Point matching: arg1 indexes the composite assembled SO FAR, arg2
        // indexes this component after its transform. The component is then
        // translated so the two coincide.
        if (c.arg1 >= xs.length || c.arg2 >= n) {
          throw FontFormatException(
            'composite glyph $glyphId matches points ${c.arg1}/${c.arg2} '
            'that do not exist',
          );
        }
        ox = xs[c.arg1] - tx[c.arg2];
        oy = ys[c.arg1] - ty[c.arg2];
      }
      if (c.argsAreXy) {
        // The `gvar` delta moves the component's OFFSET, and a point-matched
        // component has no offset to move — it is pinned to an anchor point in
        // the composite assembled so far, and that anchor has already moved on
        // its own. Adding the delta anyway slides the component off its anchor,
        // by more the further the instance is from the default: an accent
        // drifts away from the letter it is attached to as weight increases.
        // FreeType guards this with `if (flags & ARGS_ARE_XY_VALUES)`, fontTools
        // drops the delta, and HarfBuzz applies the translation before matching
        // so the anchor cancels it. All three arrive here.
        ox += c.varDx;
        oy += c.varDy;
      }

      final offset = xs.length;
      for (var k = 0; k < n; k++) {
        xs.add(tx[k] + ox);
        ys.add(ty[k] + oy);
        onCurve.add(child.onCurve[k]);
      }
      for (final e in child.endPoints) {
        endPoints.add(e + offset);
      }
    }

    if (endPoints.isEmpty) return null;
    return _Outline(xs, ys, onCurve, endPoints);
  }

  // ── points to curves ──────────────────────────────────────────────────────

  GlyphPath _toPath(_Outline o) {
    final path = GlyphPath();
    var first = 0;
    for (final last in o.endPoints) {
      if (last >= first && last < o.xs.length) {
        _emitContour(path, o, first, last);
      }
      first = last + 1;
    }
    return path;
  }

  /// Turns one contour's points into curves.
  ///
  /// The subtle part, and where most reimplementations break: two consecutive
  /// OFF-curve points have an on-curve point between them that the font does
  /// not store — it is implied at their midpoint. A contour may also begin
  /// off-curve, in which case the start point itself is implied, and a contour
  /// may consist ENTIRELY of off-curve points (a circle drawn as four control
  /// points), where the start is the midpoint of the last and first.
  void _emitContour(GlyphPath path, _Outline o, int first, int last) {
    final n = last - first + 1;
    if (n <= 0) return;

    var startOffset = -1;
    for (var k = 0; k < n; k++) {
      if (o.onCurve[first + k]) {
        startOffset = k;
        break;
      }
    }

    final double startX;
    final double startY;
    final int begin;
    final int count;
    if (startOffset < 0) {
      startX = (o.xs[first] + o.xs[last]) / 2;
      startY = (o.ys[first] + o.ys[last]) / 2;
      begin = 0;
      count = n; // every stored point is a control point
    } else {
      startX = o.xs[first + startOffset];
      startY = o.ys[first + startOffset];
      begin = startOffset + 1;
      count = n - 1;
    }

    path.moveTo(startX, startY);

    double? cx;
    double? cy;
    for (var k = 0; k < count; k++) {
      final index = first + (begin + k) % n;
      final x = o.xs[index];
      final y = o.ys[index];
      if (o.onCurve[index]) {
        if (cx == null) {
          path.lineTo(x, y);
        } else {
          path.quadraticTo(cx, cy!, x, y);
          cx = null;
          cy = null;
        }
      } else {
        if (cx != null) {
          path.quadraticTo(cx, cy!, (cx + x) / 2, (cy + y) / 2);
        }
        cx = x;
        cy = y;
      }
    }
    if (cx != null) path.quadraticTo(cx, cy!, startX, startY);
    // `close` is the straight line home when the contour ended on-curve, and a
    // zero-length no-op when the curve above already landed on the start.
    path.close();
  }
}
