/// Coverage tables — "does this lookup apply to this glyph, and at what index".
///
/// Every GSUB/GPOS subtable starts by asking a Coverage table this question, so
/// [Coverage.index] runs once per glyph per subtable per lookup. On a Kurdish
/// line that is tens of thousands of calls, which is why both formats are held
/// as flat [Uint16List]s and searched binary rather than scanned or hashed: a
/// `Set<int>` would be O(1) but costs a boxed allocation per entry at parse
/// time, and the coverage index itself — which format 2 computes arithmetically
/// — cannot come out of a set at all.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';

/// A parsed Coverage table (OpenType Layout Common Table Formats, §Coverage).
sealed class Coverage {
  const Coverage();

  /// Parses the Coverage table at [r]'s current position.
  ///
  /// [r]'s cursor is not advanced; the table is addressed absolutely from
  /// `r.position`, because a Coverage offset in a real font routinely points
  /// backwards into a shared table its own subtable does not contain.
  static Coverage parse(ByteReader r) {
    final base = r.position;
    final format = r.uint16At(base);
    switch (format) {
      case 1:
        final count = r.uint16At(base + 2);
        return _CoverageFormat1(r.at(base + 4).readUint16List(count));
      case 2:
        // Three uint16s per RangeRecord: start, end, startCoverageIndex. Kept
        // interleaved in one list so a binary search touches one cache line.
        final count = r.uint16At(base + 2);
        return _CoverageFormat2(r.at(base + 4).readUint16List(count * 3));
      default:
        throw FontFormatException('unknown Coverage format $format');
    }
  }

  /// Coverage index of [glyphId], or -1 when the glyph is not covered.
  int index(int glyphId);

  bool covers(int glyphId) => index(glyphId) >= 0;

  /// Every covered glyph, in coverage-index order. For the subsetter, which has
  /// to know which glyphs a lookup can reach before it decides what to keep.
  Iterable<int> get glyphs;

  /// Number of covered glyphs. Equal to the highest coverage index plus one for
  /// a well-formed table.
  int get glyphCount;
}

final class _CoverageFormat1 extends Coverage {
  _CoverageFormat1(this._glyphs);

  final Uint16List _glyphs;

  @override
  int index(int glyphId) {
    // The spec requires the array to be sorted ascending, and this search
    // trusts that — as HarfBuzz does. A font that violates it gets a miss, not
    // a wrong glyph: `index` only ever returns a position it actually matched.
    var lo = 0;
    var hi = _glyphs.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final g = _glyphs[mid];
      if (glyphId < g) {
        hi = mid - 1;
      } else if (glyphId > g) {
        lo = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  @override
  Iterable<int> get glyphs => _glyphs;

  @override
  int get glyphCount => _glyphs.length;
}

final class _CoverageFormat2 extends Coverage {
  _CoverageFormat2(this._ranges);

  /// Flattened RangeRecords: `[start, end, startCoverageIndex] * rangeCount`.
  final Uint16List _ranges;

  int get _rangeCount => _ranges.length ~/ 3;

  @override
  int index(int glyphId) {
    var lo = 0;
    var hi = _rangeCount - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final i = mid * 3;
      if (glyphId < _ranges[i]) {
        hi = mid - 1;
      } else if (glyphId > _ranges[i + 1]) {
        lo = mid + 1;
      } else {
        return _ranges[i + 2] + (glyphId - _ranges[i]);
      }
    }
    return -1;
  }

  @override
  Iterable<int> get glyphs sync* {
    for (var i = 0; i < _ranges.length; i += 3) {
      for (var g = _ranges[i]; g <= _ranges[i + 1]; g++) {
        yield g;
      }
    }
  }

  @override
  int get glyphCount {
    var n = 0;
    for (var i = 0; i < _ranges.length; i += 3) {
      final start = _ranges[i];
      final end = _ranges[i + 1];
      if (end >= start) n += end - start + 1;
    }
    return n;
  }
}
