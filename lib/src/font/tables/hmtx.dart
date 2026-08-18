/// `hmtx` — horizontal metrics.
///
/// The table is two arrays welded together: `numberOfHMetrics` (advance, lsb)
/// pairs, then a bare sidebearing array for every remaining glyph. That shape
/// exists to compress monospaced and CJK fonts, where thousands of glyphs share
/// one advance — such a font can ship `numberOfHMetrics = 1`.
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// The parsed `hmtx` table.
class HmtxTable {
  HmtxTable._(this._advances, this._pairedLsbs, this._trailingLsbs);

  /// Parses `hmtx`. [numberOfHMetrics] comes from `hhea`, [numGlyphs] from
  /// `maxp` — this table carries neither, which is why it cannot be parsed on
  /// its own.
  ///
  /// [tableLength] is the record length from the table directory. It is
  /// optional because the reader `payv` is handed shares the whole file buffer
  /// and cannot tell where `hmtx` ends; without it a truncated `hmtx` followed
  /// by another table would read that table's bytes as sidebearings. Pass it
  /// when the length is known.
  static HmtxTable parse(
    ByteReader r, {
    required int numberOfHMetrics,
    required int numGlyphs,
    int? tableLength,
  }) {
    if (numGlyphs < 0) {
      throw FontFormatException('numGlyphs $numGlyphs is negative');
    }
    if (numberOfHMetrics < 1 && numGlyphs > 0) {
      throw const FontFormatException(
        'hhea.numberOfHMetrics is 0, leaving every glyph without an advance',
      );
    }

    // Fonts produced by old tooling routinely claim more metrics than glyphs.
    // That is recoverable — the extra pairs are simply unreachable — so clamp
    // instead of rejecting a font that every other rasteriser loads.
    final metrics = numberOfHMetrics > numGlyphs ? numGlyphs : numberOfHMetrics;

    final base = r.position;
    if (!r.canRead(base, metrics * 4)) {
      throw FontFormatException(
        'hmtx holds fewer than the $metrics metric pairs hhea promises',
      );
    }

    final advances = Uint16List(metrics);
    final pairedLsbs = Int16List(metrics);
    for (var i = 0; i < metrics; i++) {
      final at = base + i * 4;
      advances[i] = r.uint16At(at);
      pairedLsbs[i] = r.int16At(at + 2);
    }

    // The trailing sidebearing array is the part real fonts truncate: it is
    // pure hinting data for a rasteriser and several shippers drop it. Read as
    // many as are actually present and treat the rest as zero rather than
    // failing a font that draws correctly everywhere else.
    final trailingStart = base + metrics * 4;
    final wanted = numGlyphs - metrics;
    final end = tableLength == null
        ? r.length
        : (base + tableLength).clamp(0, r.length);
    final available = ((end - trailingStart) ~/ 2).clamp(0, wanted);
    final trailingLsbs = Int16List(wanted);
    for (var i = 0; i < available; i++) {
      trailingLsbs[i] = r.int16At(trailingStart + i * 2);
    }

    return HmtxTable._(advances, pairedLsbs, trailingLsbs);
  }

  final Uint16List _advances;
  final Int16List _pairedLsbs;
  final Int16List _trailingLsbs;

  /// Glyphs with an explicit (advance, lsb) pair.
  int get numberOfHMetrics => _advances.length;

  int get numGlyphs => _advances.length + _trailingLsbs.length;

  /// Advance width of [glyphId] in design units.
  ///
  /// Every glyph past [numberOfHMetrics] repeats the LAST pair's advance. That
  /// is the whole point of the split array, and it is also the classic bug:
  /// indexing the advance array directly by glyph id reads the sidebearing
  /// array as advances and gives a monospaced CJK font wildly wrong widths.
  int advanceWidth(int glyphId) {
    if (glyphId < 0 || glyphId >= numGlyphs || _advances.isEmpty) return 0;
    final i = glyphId < _advances.length ? glyphId : _advances.length - 1;
    return _advances[i];
  }

  /// Left sidebearing of [glyphId] in design units.
  ///
  /// Unlike the advance this does NOT repeat — glyphs past [numberOfHMetrics]
  /// each get their own entry from the trailing array.
  int leftSideBearing(int glyphId) {
    if (glyphId < 0 || glyphId >= numGlyphs) return 0;
    if (glyphId < _pairedLsbs.length) return _pairedLsbs[glyphId];
    return _trailingLsbs[glyphId - _pairedLsbs.length];
  }

  @override
  String toString() =>
      'HmtxTable($numGlyphs glyphs, $numberOfHMetrics metric pairs)';
}
