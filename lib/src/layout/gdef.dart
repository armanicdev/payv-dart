/// `GDEF` — the table that tells the layout engine what each glyph *is*.
///
/// Small, and load-bearing out of all proportion to its size. Every lookup flag
/// that skips marks, every mark-attachment pass, and every ligature caret
/// depends on the classes here, so a font with a wrong GDEF misplaces marks
/// everywhere and a shaper that ignores GDEF cannot skip anything at all.
/// Vazirmatn ships version 1.3: GlyphClassDef, MarkGlyphSetsDef and an
/// ItemVariationStore for its GPOS device deltas.
library;

import '../font/variations/variation_store.dart';
import '../util/byte_reader.dart';
import 'class_def.dart';
import 'coverage.dart';

/// A parsed `GDEF` table.
class GdefTable {
  GdefTable._(
    this._reader, {
    required ClassDef glyphClasses,
    required ClassDef markAttachClasses,
    required int markSetsOffset,
    required int ligCaretOffset,
    required int varStoreOffset,
    required List<Coverage?>? markSets,
    required this.minorVersion,
  }) : _glyphClasses = glyphClasses,
       _markAttachClasses = markAttachClasses,
       _markSetsOffset = markSetsOffset,
       _ligCaretOffset = ligCaretOffset,
       _varStoreOffset = varStoreOffset,
       _markSets = markSets;

  /// Parses the `GDEF` table at [r]'s current position.
  ///
  /// The two ClassDefs are parsed eagerly — they are queried once per glyph per
  /// lookup, so paying for them up front is strictly cheaper than a null check
  /// in that loop. Everything else here is rare and stays lazy.
  static GdefTable parse(ByteReader r) {
    final base = r.position;
    final major = r.uint16At(base);
    final minor = r.uint16At(base + 2);
    if (major != 1) {
      throw FontFormatException('unsupported GDEF version $major.$minor');
    }

    final glyphClassOffset = r.uint16At(base + 4);
    // +6 is attachListOffset — hinting attach points, which nothing in a
    // shaping or PDF pipeline reads. Deliberately not parsed.
    final ligCaretOffset = r.uint16At(base + 8);
    final markAttachOffset = r.uint16At(base + 10);
    final markSetsOffset = minor >= 2 ? r.uint16At(base + 12) : 0;
    final varStoreOffset = minor >= 3 ? r.uint32At(base + 14) : 0;

    List<Coverage?>? markSets;
    if (markSetsOffset != 0) {
      final table = base + markSetsOffset;
      final format = r.uint16At(table);
      if (format != 1) {
        throw FontFormatException('unknown MarkGlyphSets format $format');
      }
      markSets = List<Coverage?>.filled(r.uint16At(table + 2), null);
    }

    return GdefTable._(
      r,
      glyphClasses: glyphClassOffset == 0
          ? ClassDef.empty
          : ClassDef.parse(r.at(base + glyphClassOffset)),
      markAttachClasses: markAttachOffset == 0
          ? ClassDef.empty
          : ClassDef.parse(r.at(base + markAttachOffset)),
      markSetsOffset: markSetsOffset == 0 ? 0 : base + markSetsOffset,
      ligCaretOffset: ligCaretOffset == 0 ? 0 : base + ligCaretOffset,
      varStoreOffset: varStoreOffset == 0 ? 0 : base + varStoreOffset,
      markSets: markSets,
      minorVersion: minor,
    );
  }

  final ByteReader _reader;
  final ClassDef _glyphClasses;
  final ClassDef _markAttachClasses;

  /// Absolute offsets; 0 means the font omitted the subtable.
  final int _markSetsOffset;
  final int _ligCaretOffset;
  final int _varStoreOffset;

  /// Lazily parsed MarkGlyphSets coverages, one slot per declared set.
  final List<Coverage?>? _markSets;

  final int minorVersion;

  Coverage? _ligCaretCoverage;
  ItemVariationStore? _varStore;
  bool _varStoreRead = false;

  /// True when the font actually classifies its glyphs. A GDEF without a
  /// GlyphClassDef cannot drive any `Ignore*` lookup flag, and a shaper may
  /// want to say so rather than silently skipping nothing.
  bool get hasGlyphClasses => _glyphClasses != ClassDef.empty;

  /// `GlyphClass` value for [glyphId] — base, ligature, mark or component.
  /// 0 (`GlyphClass.unclassified`) when the font does not say.
  int glyphClass(int glyphId) => _glyphClasses.classOf(glyphId);

  /// Mark attachment class for [glyphId], for
  /// `LookupFlag.markAttachmentType`. 0 when unclassified.
  int markAttachClass(int glyphId) => _markAttachClasses.classOf(glyphId);

  /// Whether [glyphId] is in MarkGlyphSets set [setIndex].
  ///
  /// False for an out-of-range index rather than a throw: the index comes from
  /// a lookup's flag word, and a font that names a set it did not ship should
  /// filter everything out, not abort the shaping of a document.
  bool isInMarkFilteringSet(int setIndex, int glyphId) {
    final sets = _markSets;
    if (sets == null || setIndex < 0 || setIndex >= sets.length) return false;

    var coverage = sets[setIndex];
    if (coverage == null) {
      // Offset32 here, not Offset16 — mark sets were added late enough that
      // the spec had stopped pretending 64 KB was enough.
      final offset = _reader.uint32At(_markSetsOffset + 4 + setIndex * 4);
      if (offset == 0) return false;
      coverage = Coverage.parse(_reader.at(_markSetsOffset + offset));
      sets[setIndex] = coverage;
    }
    return coverage.covers(glyphId);
  }

  /// Ligature caret positions for [glyphId] in design units, or null when the
  /// font declares none.
  ///
  /// Format 2 carets (an outline point index) come back as 0: resolving one
  /// needs the instanced `glyf` contour, which this table has no route to.
  /// Format 3's Device adjustment is likewise dropped — it is a ppem-space
  /// correction and everything here is unscaled.
  List<int>? ligatureCarets(int glyphId) {
    if (_ligCaretOffset == 0) return null;

    var coverage = _ligCaretCoverage;
    if (coverage == null) {
      final offset = _reader.uint16At(_ligCaretOffset);
      if (offset == 0) return null;
      coverage = _ligCaretCoverage = Coverage.parse(
        _reader.at(_ligCaretOffset + offset),
      );
    }

    final index = coverage.index(glyphId);
    if (index < 0 || index >= _reader.uint16At(_ligCaretOffset + 2)) {
      return null;
    }

    final ligGlyph =
        _ligCaretOffset + _reader.uint16At(_ligCaretOffset + 4 + index * 2);
    final count = _reader.uint16At(ligGlyph);
    return List<int>.generate(count, (i) {
      final caret = ligGlyph + _reader.uint16At(ligGlyph + 2 + i * 2);
      final format = _reader.uint16At(caret);
      switch (format) {
        case 1:
        case 3:
          return _reader.int16At(caret + 2);
        case 2:
          return 0;
        default:
          throw FontFormatException('unknown CaretValue format $format');
      }
    }, growable: false);
  }

  /// The `GDEF` ItemVariationStore (version 1.3), which resolves every
  /// VariationIndex a GPOS device offset points at. Null on a static font.
  ItemVariationStore? get varStore {
    if (_varStoreRead) return _varStore;
    _varStoreRead = true;
    if (_varStoreOffset == 0) return null;
    return _varStore = ItemVariationStore.parse(_reader.at(_varStoreOffset));
  }

  @override
  String toString() => 'GdefTable(1.$minorVersion)';
}
