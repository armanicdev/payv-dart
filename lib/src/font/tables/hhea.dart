/// `hhea` — horizontal header.
///
/// Carries the line metrics and, critically, `numberOfHMetrics`: the split
/// point that tells `hmtx` where its packed metric pairs stop and its trailing
/// sidebearing array begins.
library;

import '../../util/byte_reader.dart';

/// The parsed `hhea` table. 36 bytes.
class HheaTable {
  const HheaTable._({
    required this.majorVersion,
    required this.minorVersion,
    required this.ascender,
    required this.descender,
    required this.lineGap,
    required this.advanceWidthMax,
    required this.minLeftSideBearing,
    required this.minRightSideBearing,
    required this.xMaxExtent,
    required this.caretSlopeRise,
    required this.caretSlopeRun,
    required this.caretOffset,
    required this.metricDataFormat,
    required this.numberOfHMetrics,
  });

  static HheaTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 36)) {
      throw const FontFormatException('hhea is shorter than its 36 bytes');
    }
    return HheaTable._(
      majorVersion: r.uint16At(base),
      minorVersion: r.uint16At(base + 2),
      ascender: r.int16At(base + 4),
      descender: r.int16At(base + 6),
      lineGap: r.int16At(base + 8),
      advanceWidthMax: r.uint16At(base + 10),
      minLeftSideBearing: r.int16At(base + 12),
      minRightSideBearing: r.int16At(base + 14),
      xMaxExtent: r.int16At(base + 16),
      caretSlopeRise: r.int16At(base + 18),
      caretSlopeRun: r.int16At(base + 20),
      caretOffset: r.int16At(base + 22),
      // Bytes 24…31 are four reserved int16s. They are reserved, not padding —
      // the spec forbids reusing them, so they are simply skipped.
      metricDataFormat: r.int16At(base + 32),
      numberOfHMetrics: r.uint16At(base + 34),
    );
  }

  final int majorVersion;
  final int minorVersion;

  /// Typographic ascent/descent/gap in design units. `descender` is negative.
  ///
  /// These are the Apple-lineage metrics; Windows rasterisers use
  /// `OS/2.usWinAscent`/`usWinDescent` and typographers usually mean
  /// `OS/2.sTypoAscender`. A layout engine that mixes the three families gets
  /// line heights that differ per platform, so `payv` reads all three and lets
  /// the caller choose.
  final int ascender;
  final int descender;
  final int lineGap;

  final int advanceWidthMax;
  final int minLeftSideBearing;
  final int minRightSideBearing;
  final int xMaxExtent;

  final int caretSlopeRise;
  final int caretSlopeRun;
  final int caretOffset;

  /// 0 for every font in existence; the spec keeps the field for future formats.
  final int metricDataFormat;

  /// How many `longHorMetric` pairs `hmtx` opens with.
  final int numberOfHMetrics;

  @override
  String toString() =>
      'HheaTable(asc: $ascender, desc: $descender, gap: $lineGap, '
      'numberOfHMetrics: $numberOfHMetrics)';
}
