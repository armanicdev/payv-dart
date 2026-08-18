/// `gvar` — glyph variations: how every outline point moves as the axes move.
///
/// This is the table that makes a variable font variable, and it is by far the
/// largest in Vazirmatn (101 KB of 236 KB). Its encoding is unusually dense
/// because it has to be: rather than storing a delta per point per master, it
/// stores deltas only for the points a designer actually moved and INFERS the
/// rest — the IUP pass at the bottom of this file. Getting IUP wrong does not
/// produce a broken font, it produces a subtly lumpy one, which is why it is
/// implemented here against FreeType's and HarfBuzz's semantics rather than
/// from the prose in the spec.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// A parsed `gvar` table.
class GvarTable {
  GvarTable._({
    required ByteReader reader,
    required int axisCount,
    required List<List<double>> sharedTuples,
    required int glyphCount,
    required bool longOffsets,
    required int offsetsAt,
    required int dataArrayAt,
  }) : _r = reader,
       _axisCount = axisCount,
       _sharedTuples = sharedTuples,
       _glyphCount = glyphCount,
       _longOffsets = longOffsets,
       _offsetsAt = offsetsAt,
       _dataArrayAt = dataArrayAt;

  static GvarTable parse(
    ByteReader r, {
    required int numGlyphs,
    required int axisCount,
  }) {
    final base = r.position;
    final major = r.uint16At(base);
    if (major != 1) throw FontFormatException('gvar version $major is not 1');

    final tableAxisCount = r.uint16At(base + 4);
    if (tableAxisCount != axisCount) {
      // Deltas are indexed positionally against `fvar`'s axis order. A
      // mismatch is not a degraded font, it is deltas applied to the wrong
      // axis, so it fails here rather than drawing something plausible.
      throw FontFormatException(
        'gvar declares $tableAxisCount axes but fvar declares $axisCount',
      );
    }
    final sharedTupleCount = r.uint16At(base + 6);
    final sharedTuplesOffset = r.uint32At(base + 8);
    final glyphCount = r.uint16At(base + 12);
    final flags = r.uint16At(base + 14);
    final dataArrayOffset = r.uint32At(base + 16);
    final longOffsets = flags & 0x0001 != 0;

    final offsetsAt = base + 20;
    final entry = longOffsets ? 4 : 2;
    if (!r.canRead(offsetsAt, (glyphCount + 1) * entry)) {
      throw const FontFormatException('gvar offset array overruns the font');
    }

    final sharedAt = base + sharedTuplesOffset;
    if (!r.canRead(sharedAt, sharedTupleCount * axisCount * 2)) {
      throw const FontFormatException('gvar shared tuples overrun the font');
    }
    final sharedTuples = List<List<double>>.generate(
      sharedTupleCount,
      (i) => List<double>.generate(
        axisCount,
        (a) => r.f2dot14At(sharedAt + (i * axisCount + a) * 2),
        growable: false,
      ),
      growable: false,
    );

    return GvarTable._(
      reader: r,
      axisCount: axisCount,
      sharedTuples: sharedTuples,
      // A `gvar` is allowed to cover fewer glyphs than `maxp` declares; the
      // tail simply does not vary.
      glyphCount: glyphCount < numGlyphs ? glyphCount : numGlyphs,
      longOffsets: longOffsets,
      offsetsAt: offsetsAt,
      dataArrayAt: base + dataArrayOffset,
    );
  }

  final ByteReader _r;
  final int _axisCount;
  final List<List<double>> _sharedTuples;
  final int _glyphCount;
  final bool _longOffsets;
  final int _offsetsAt;
  final int _dataArrayAt;

  int get axisCount => _axisCount;

  int get glyphCount => _glyphCount;

  /// Short offsets are stored halved, exactly like a short `loca`.
  int _offsetAt(int index) => _longOffsets
      ? _r.uint32At(_offsetsAt + index * 4)
      : _r.uint16At(_offsetsAt + index * 2) * 2;

  /// Per-point deltas for [glyphId] at [coords], already IUP-interpolated.
  ///
  /// Returns null when the glyph does not vary at this location — the caller
  /// should then use the default outline untouched, not add zeros to it.
  ///
  /// [pointCount] is the point count `gvar` itself indexes, which for a simple
  /// glyph is the outline's points PLUS the four phantom points, and for a
  /// composite is the number of components plus four. The caller decides what
  /// to do with the tail.
  ///
  /// [contourEnds], [xs] and [ys] are what IUP needs and cannot derive: the
  /// interpolation is per contour and is parameterised by each point's ORIGINAL
  /// coordinate, not by its index. Omit them — as a composite glyph must, since
  /// its "points" are component offsets with no geometry and no contours — and
  /// the raw deltas are returned with unreferenced entries left at zero, which
  /// is the correct behaviour for that case.
  List<(double, double)>? deltas(
    int glyphId,
    List<double> coords,
    int pointCount, {
    List<int>? contourEnds,
    List<double>? xs,
    List<double>? ys,
  }) {
    if (glyphId < 0 || glyphId >= _glyphCount || pointCount <= 0) return null;

    final start = _offsetAt(glyphId);
    final end = _offsetAt(glyphId + 1);
    if (end <= start) return null; // this glyph has no variation data
    if (!_r.canRead(_dataArrayAt + start, end - start)) {
      throw FontFormatException(
        'gvar data for glyph $glyphId overruns the font',
      );
    }

    final gvBase = _dataArrayAt + start;
    final tupleVariationCount = _r.uint16At(gvBase);
    final dataOffset = _r.uint16At(gvBase + 2);
    final tupleCount = tupleVariationCount & 0x0FFF;
    if (tupleCount == 0) return null;

    final headers = _r.at(gvBase + 4);
    final data = _r.at(gvBase + dataOffset);

    // `SHARED_POINT_NUMBERS` — one point set at the head of the data block,
    // reused by every tuple that does not carry its own.
    var hasShared = false;
    List<int>? shared;
    if (tupleVariationCount & 0x8000 != 0) {
      hasShared = true;
      shared = _readPackedPoints(data);
    }

    final accX = Float64List(pointCount);
    final accY = Float64List(pointCount);
    var touchedAny = false;

    // Scratch reused across tuples: IUP runs per tuple, so each pass needs a
    // clean delta/reference pair, but the allocation should not repeat.
    final tupX = Float64List(pointCount);
    final tupY = Float64List(pointCount);
    final referenced = Uint8List(pointCount);

    var cursor = data.position;
    for (var t = 0; t < tupleCount; t++) {
      final variationDataSize = headers.readUint16();
      final tupleIndex = headers.readUint16();

      final List<double> peak;
      if (tupleIndex & 0x8000 != 0) {
        // EMBEDDED_PEAK_TUPLE — the peak follows the header inline.
        peak = List<double>.generate(
          _axisCount,
          (_) => headers.readF2Dot14(),
          growable: false,
        );
      } else {
        final idx = tupleIndex & 0x0FFF;
        if (idx >= _sharedTuples.length) {
          throw FontFormatException(
            'gvar shared tuple index $idx out of range',
          );
        }
        peak = _sharedTuples[idx];
      }

      List<double>? interStart;
      List<double>? interEnd;
      if (tupleIndex & 0x4000 != 0) {
        interStart = List<double>.generate(
          _axisCount,
          (_) => headers.readF2Dot14(),
          growable: false,
        );
        interEnd = List<double>.generate(
          _axisCount,
          (_) => headers.readF2Dot14(),
          growable: false,
        );
      }

      final tupleDataAt = cursor;
      cursor += variationDataSize;

      final scalar = _tupleScalar(peak, interStart, interEnd, coords);
      if (scalar == 0) continue; // this master contributes nothing here

      final body = _r.at(tupleDataAt);
      final List<int>? points;
      if (tupleIndex & 0x2000 != 0) {
        points = _readPackedPoints(body); // PRIVATE_POINT_NUMBERS
      } else if (hasShared) {
        points = shared;
      } else {
        // Neither shared nor private numbers: the tuple covers every point.
        points = null;
      }

      final n = points?.length ?? pointCount;
      if (n == 0) continue;
      final dx = _readPackedDeltas(body, n);
      final dy = _readPackedDeltas(body, n);

      tupX.fillRange(0, pointCount, 0);
      tupY.fillRange(0, pointCount, 0);
      referenced.fillRange(0, pointCount, 0);

      for (var j = 0; j < n; j++) {
        final p = points == null ? j : points[j];
        if (p < 0 || p >= pointCount) continue;
        tupX[p] = dx[j] * scalar;
        tupY[p] = dy[j] * scalar;
        referenced[p] = 1;
      }

      // A tuple that names every point leaves nothing to infer. Otherwise the
      // omitted points are dragged along by their neighbours.
      if (points != null && contourEnds != null && xs != null && ys != null) {
        _interpolate(tupX, tupY, referenced, contourEnds, xs, ys);
      }

      for (var p = 0; p < pointCount; p++) {
        accX[p] += tupX[p];
        accY[p] += tupY[p];
      }
      touchedAny = true;
    }

    if (!touchedAny) return null;
    return List<(double, double)>.generate(
      pointCount,
      (i) => (accX[i], accY[i]),
      growable: false,
    );
  }

  /// The tuple's weight at [coords].
  ///
  /// Follows HarfBuzz's `TupleVariationHeader::calculate_scalar` branch for
  /// branch. The non-intermediate case is the one worth reading twice: the
  /// implied region is `[min(peak, 0), max(peak, 0)]`, so a tuple peaking at
  /// 0.5 contributes NOTHING at 1.0. That looks like a bug and is not — it is
  /// why a font with a mid-axis master also ships intermediate regions.
  double _tupleScalar(
    List<double> peak,
    List<double>? interStart,
    List<double>? interEnd,
    List<double> coords,
  ) {
    var scalar = 1.0;
    for (var i = 0; i < peak.length; i++) {
      final p = peak[i];
      if (p == 0) continue;
      final v = i < coords.length ? coords[i] : 0.0;
      if (v == p) continue;

      if (interStart != null && interEnd != null) {
        final s = interStart[i];
        final e = interEnd[i];
        if (s > p || p > e || (s < 0 && e > 0)) continue; // malformed: ignore
        if (v < s || v > e) return 0.0;
        if (v < p) {
          if (p != s) scalar *= (v - s) / (p - s);
        } else {
          if (p != e) scalar *= (e - v) / (e - p);
        }
      } else {
        if (v == 0 || v < math.min(0.0, p) || v > math.max(0.0, p)) return 0.0;
        scalar *= v / p;
      }
    }
    return scalar;
  }
}

// ── packed encodings ─────────────────────────────────────────────────────────

/// Reads a packed point-number set, advancing [r].
///
/// Returns null for the spec's "all points" special case — a leading zero byte.
/// Note that this is NOT the same as an empty set, and conflating the two makes
/// every fully-varying glyph stop varying.
List<int>? _readPackedPoints(ByteReader r) {
  final first = r.readUint8();
  if (first == 0) return null;
  final count = first & 0x80 != 0
      ? ((first & 0x7F) << 8) | r.readUint8()
      : first;

  final out = <int>[];
  var value = 0;
  while (out.length < count) {
    final control = r.readUint8();
    final run = (control & 0x7F) + 1;
    final words = control & 0x80 != 0;
    for (var i = 0; i < run; i++) {
      // Point numbers are stored as deltas from the previous one, so a run that
      // overruns `count` must still be consumed in full or the delta stream for
      // the coordinates that follow starts mid-integer.
      value += words ? r.readUint16() : r.readUint8();
      if (out.length < count) out.add(value);
    }
  }
  return out;
}

/// Reads [count] packed delta values, advancing [r].
Int32List _readPackedDeltas(ByteReader r, int count) {
  final out = Int32List(count);
  var i = 0;
  while (i < count) {
    final control = r.readUint8();
    final run = (control & 0x3F) + 1;
    if (control & 0x80 != 0) {
      // DELTAS_ARE_ZERO — a run with no bytes at all. This is the reason gvar
      // is affordable: most points do not move for most masters.
      i += run;
    } else if (control & 0x40 != 0) {
      for (var n = 0; n < run; n++) {
        final v = r.readInt16();
        if (i < count) out[i] = v;
        i++;
      }
    } else {
      for (var n = 0; n < run; n++) {
        final v = r.readInt8();
        if (i < count) out[i] = v;
        i++;
      }
    }
  }
  return out;
}

// ── IUP ──────────────────────────────────────────────────────────────────────

/// Infers deltas for the points a tuple omitted (Inferred Unreferenced Points).
///
/// Per contour, per axis. Each unreferenced point is dragged by the nearest
/// referenced point on each side, interpolated by its ORIGINAL coordinate —
/// which is what keeps a curve's shape instead of merely shifting it.
void _interpolate(
  Float64List dx,
  Float64List dy,
  Uint8List referenced,
  List<int> contourEnds,
  List<double> xs,
  List<double> ys,
) {
  var first = 0;
  for (final last in contourEnds) {
    if (last >= first && last < dx.length && last < xs.length) {
      _interpolateContour(first, last, dx, dy, referenced, xs, ys);
    }
    first = last + 1;
  }
}

void _interpolateContour(
  int start,
  int end,
  Float64List dx,
  Float64List dy,
  Uint8List referenced,
  List<double> xs,
  List<double> ys,
) {
  var unreferenced = 0;
  for (var i = start; i <= end; i++) {
    if (referenced[i] == 0) unreferenced++;
  }
  // Nothing to infer, or nothing to infer FROM. The second case matters: a
  // contour no master touched must stay exactly where it is.
  if (unreferenced == 0 || unreferenced > end - start) return;

  var j = start;
  while (true) {
    // Walk to the last referenced point before a gap, then to the first
    // referenced point after it. Both walks wrap around the end of the contour,
    // which is the whole reason the search is written as two cyclic scans
    // rather than a linear one: a gap may straddle the contour's seam, with its
    // left neighbour near the end of the point list and its right neighbour at
    // the start.
    int i;
    do {
      i = j;
      j = _nextIndex(i, start, end);
    } while (!(referenced[i] != 0 && referenced[j] == 0));
    final prev = i;

    j = prev;
    do {
      i = j;
      j = _nextIndex(i, start, end);
    } while (!(referenced[i] == 0 && referenced[j] != 0));
    final next = j;

    i = prev;
    while (true) {
      i = _nextIndex(i, start, end);
      if (i == next) break;
      dx[i] = _inferDelta(xs[i], xs[prev], xs[next], dx[prev], dx[next]);
      dy[i] = _inferDelta(ys[i], ys[prev], ys[next], dy[prev], dy[next]);
      if (--unreferenced == 0) return;
    }
  }
}

int _nextIndex(int i, int start, int end) => i >= end ? start : i + 1;

/// One axis of one inferred point.
///
/// When the two anchors sit at the same coordinate there is no interval to
/// interpolate across, so the point moves only if both anchors agree — anything
/// else would be an arbitrary choice between two answers. Outside the anchors'
/// span the point is translated by the nearer anchor rather than extrapolated,
/// which is what stops a serif from shearing off the end of a stem.
double _inferDelta(
  double target,
  double prevValue,
  double nextValue,
  double prevDelta,
  double nextDelta,
) {
  if (prevValue == nextValue) {
    return prevDelta == nextDelta ? prevDelta : 0.0;
  }
  if (target <= math.min(prevValue, nextValue)) {
    return prevValue < nextValue ? prevDelta : nextDelta;
  }
  if (target >= math.max(prevValue, nextValue)) {
    return prevValue > nextValue ? prevDelta : nextDelta;
  }
  final r = (target - prevValue) / (nextValue - prevValue);
  return prevDelta + r * (nextDelta - prevDelta);
}
