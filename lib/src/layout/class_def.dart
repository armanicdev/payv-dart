/// ClassDef tables — the glyph→class map GPOS pair kerning and every
/// class-based context rule are built on.
///
/// Class 0 is not "absent", it is a real class meaning "everything not listed",
/// and rules do match on it. So [ClassDef.classOf] returns 0 for an unlisted
/// glyph rather than -1, and a missing ClassDef table is modelled as
/// [ClassDef.empty] (everything is class 0) instead of as null — that removes a
/// null check from the innermost loop of PairPos format 2.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';

/// A parsed ClassDef table (OpenType Layout Common Table Formats, §Class
/// Definition Table).
sealed class ClassDef {
  const ClassDef();

  /// Parses the ClassDef table at [r]'s current position. The cursor is not
  /// advanced; the table is addressed absolutely from `r.position`.
  static ClassDef parse(ByteReader r) {
    final base = r.position;
    final format = r.uint16At(base);
    switch (format) {
      case 1:
        final start = r.uint16At(base + 2);
        final count = r.uint16At(base + 4);
        return _ClassDefFormat1(start, r.at(base + 6).readUint16List(count));
      case 2:
        final count = r.uint16At(base + 2);
        // Three uint16s per ClassRangeRecord: start, end, class.
        return _ClassDefFormat2(r.at(base + 4).readUint16List(count * 3));
      default:
        throw FontFormatException('unknown ClassDef format $format');
    }
  }

  /// Class of [glyphId], or 0 when the glyph is not listed.
  int classOf(int glyphId);

  /// A ClassDef that puts every glyph in class 0 — what a font means when it
  /// omits a ClassDef offset entirely.
  static final ClassDef empty = const _ClassDefEmpty();
}

final class _ClassDefEmpty extends ClassDef {
  const _ClassDefEmpty();

  @override
  int classOf(int glyphId) => 0;
}

final class _ClassDefFormat1 extends ClassDef {
  _ClassDefFormat1(this._startGlyph, this._classes);

  final int _startGlyph;
  final Uint16List _classes;

  @override
  int classOf(int glyphId) {
    final i = glyphId - _startGlyph;
    return i >= 0 && i < _classes.length ? _classes[i] : 0;
  }
}

final class _ClassDefFormat2 extends ClassDef {
  _ClassDefFormat2(this._ranges);

  /// Flattened ClassRangeRecords: `[start, end, class] * rangeCount`.
  final Uint16List _ranges;

  @override
  int classOf(int glyphId) {
    var lo = 0;
    var hi = _ranges.length ~/ 3 - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final i = mid * 3;
      if (glyphId < _ranges[i]) {
        hi = mid - 1;
      } else if (glyphId > _ranges[i + 1]) {
        lo = mid + 1;
      } else {
        return _ranges[i + 2];
      }
    }
    return 0;
  }
}
