/// `maxp` — maximum profile.
///
/// In practice this table exists to answer one question, [numGlyphs], which
/// bounds every other per-glyph array in the font. The version 1.0 fields are
/// hinting-engine budgets; `payv` does not execute hints, but the subsetter
/// has to copy them forward, so they are parsed rather than skipped.
library;

import '../../util/byte_reader.dart';

/// The parsed `maxp` table.
class MaxpTable {
  const MaxpTable._({
    required this.version,
    required this.numGlyphs,
    required this.maxPoints,
    required this.maxContours,
    required this.maxCompositePoints,
    required this.maxCompositeContours,
    required this.maxZones,
    required this.maxTwilightPoints,
    required this.maxStorage,
    required this.maxFunctionDefs,
    required this.maxInstructionDefs,
    required this.maxStackElements,
    required this.maxSizeOfInstructions,
    required this.maxComponentElements,
    required this.maxComponentDepth,
  });

  static MaxpTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 6)) {
      throw const FontFormatException('maxp is too short to hold numGlyphs');
    }
    final version = r.uint32At(base);
    final numGlyphs = r.uint16At(base + 4);

    // 0x00005000 is the CFF-only half-version: numGlyphs and nothing else. Any
    // other version is read as 1.0, because a font that invents a maxp version
    // still has to put numGlyphs at offset 4 for any rasteriser to load it.
    final isHalf = version == 0x00005000;
    if (isHalf || !r.canRead(base, 32)) {
      return MaxpTable._(
        version: version,
        numGlyphs: numGlyphs,
        maxPoints: 0,
        maxContours: 0,
        maxCompositePoints: 0,
        maxCompositeContours: 0,
        maxZones: 0,
        maxTwilightPoints: 0,
        maxStorage: 0,
        maxFunctionDefs: 0,
        maxInstructionDefs: 0,
        maxStackElements: 0,
        maxSizeOfInstructions: 0,
        maxComponentElements: 0,
        maxComponentDepth: 0,
      );
    }

    return MaxpTable._(
      version: version,
      numGlyphs: numGlyphs,
      maxPoints: r.uint16At(base + 6),
      maxContours: r.uint16At(base + 8),
      maxCompositePoints: r.uint16At(base + 10),
      maxCompositeContours: r.uint16At(base + 12),
      maxZones: r.uint16At(base + 14),
      maxTwilightPoints: r.uint16At(base + 16),
      maxStorage: r.uint16At(base + 18),
      maxFunctionDefs: r.uint16At(base + 20),
      maxInstructionDefs: r.uint16At(base + 22),
      maxStackElements: r.uint16At(base + 24),
      maxSizeOfInstructions: r.uint16At(base + 26),
      maxComponentElements: r.uint16At(base + 28),
      maxComponentDepth: r.uint16At(base + 30),
    );
  }

  /// Raw Fixed version: 0x00010000 for `glyf` fonts, 0x00005000 for CFF.
  final int version;

  /// Glyph count. Bounds `loca`, `hmtx`, every `Coverage` and every `ClassDef`.
  final int numGlyphs;

  final int maxPoints;
  final int maxContours;
  final int maxCompositePoints;
  final int maxCompositeContours;
  final int maxZones;
  final int maxTwilightPoints;
  final int maxStorage;
  final int maxFunctionDefs;
  final int maxInstructionDefs;
  final int maxStackElements;
  final int maxSizeOfInstructions;
  final int maxComponentElements;

  /// Nesting depth of composite glyphs. The outline loader uses it as the
  /// recursion ceiling, so a font that lies here cannot make it loop forever.
  final int maxComponentDepth;

  /// True for the 0x00005000 profile, i.e. outlines live in `CFF `/`CFF2`.
  bool get isCffProfile => version == 0x00005000;

  @override
  String toString() => 'MaxpTable(numGlyphs: $numGlyphs)';
}
