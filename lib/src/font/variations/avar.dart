/// `avar` — the axis variations table.
///
/// `fvar` says a weight axis runs 100…900 and normalises linearly; `avar` is
/// how a designer says "but 700 is three-quarters of the way to the top, not
/// six-tenths". Skipping it does not fail loudly — it silently draws the wrong
/// weight. Vazirmatn ships one, and its `wght` map bends 0.6 to 0.6776, so a
/// PDF exported without it would be visibly light against the app.
library;

import '../../util/byte_reader.dart';

/// One `(from, to)` knot of a segment map, in normalised F2Dot14 space.
class AxisValueMap {
  const AxisValueMap(this.fromCoordinate, this.toCoordinate);

  final double fromCoordinate;
  final double toCoordinate;

  @override
  String toString() => '$fromCoordinate→$toCoordinate';
}

/// A parsed `avar` table.
class AvarTable {
  AvarTable._(this.majorVersion, this._segments, this.hasVersion2Mapping);

  static AvarTable parse(ByteReader r) {
    final base = r.position;
    final major = r.uint16At(base);
    if (major != 1 && major != 2) {
      throw FontFormatException('avar version $major is not 1 or 2');
    }
    final axisCount = r.uint16At(base + 6);
    var p = base + 8;
    final segments = <List<AxisValueMap>>[];
    for (var a = 0; a < axisCount; a++) {
      final count = r.uint16At(p);
      p += 2;
      if (!r.canRead(p, count * 4)) {
        throw const FontFormatException('avar segment map overruns the font');
      }
      final maps = List<AxisValueMap>.generate(
        count,
        (i) => AxisValueMap(r.f2dot14At(p + i * 4), r.f2dot14At(p + i * 4 + 2)),
        growable: false,
      );
      p += count * 4;
      segments.add(maps);
    }

    // avar 2.0 appends an axis-index map plus an ItemVariationStore that lets
    // one axis's mapping depend on another's position. We parse the header far
    // enough to know it is there and to say so, but apply only the segment
    // maps: a wrong cross-axis correction on a single-axis face is impossible,
    // and every face we ship is single-axis. See [hasVersion2Mapping].
    var version2 = false;
    if (major == 2 && r.canRead(p, 8)) {
      version2 = r.uint32At(p) != 0 || r.uint32At(p + 4) != 0;
    }

    return AvarTable._(major, segments, version2);
  }

  final int majorVersion;
  final List<List<AxisValueMap>> _segments;

  /// True when this is an `avar` 2.0 table that carries a `VarStore`-based
  /// mapping this parser does NOT apply. A caller that must be exact on a
  /// multi-axis face should treat this as a hard stop, not a warning.
  final bool hasVersion2Mapping;

  int get axisCount => _segments.length;

  List<AxisValueMap> segmentMap(int axisIndex) =>
      axisIndex < 0 || axisIndex >= _segments.length
      ? const <AxisValueMap>[]
      : _segments[axisIndex];

  /// Maps one normalised coordinate through the segment map for [axisIndex].
  ///
  /// Fewer than two knots means "no adjustment"; the spec requires a valid map
  /// to pin −1, 0 and +1, and a one-knot map cannot define a segment at all.
  double map(int axisIndex, double normalized) {
    if (axisIndex < 0 || axisIndex >= _segments.length) return normalized;
    final maps = _segments[axisIndex];
    if (maps.length < 2) return normalized;

    if (normalized <= maps.first.fromCoordinate) return maps.first.toCoordinate;
    for (var i = 1; i < maps.length; i++) {
      final hi = maps[i];
      if (normalized > hi.fromCoordinate) continue;
      final lo = maps[i - 1];
      final span = hi.fromCoordinate - lo.fromCoordinate;
      if (span <= 0) return hi.toCoordinate;
      final t = (normalized - lo.fromCoordinate) / span;
      return lo.toCoordinate + t * (hi.toCoordinate - lo.toCoordinate);
    }
    return maps.last.toCoordinate;
  }
}
