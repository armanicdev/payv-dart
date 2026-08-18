/// The shaping buffer — the single mutable structure every layout pass edits.
///
/// This deliberately mirrors HarfBuzz's `hb_glyph_info_t` / `hb_glyph_position_t`
/// split, including the fields that look redundant ([GlyphInfo.ligatureId],
/// [GlyphPosition.attachChain]). They are not redundant: they are how mark
/// attachment survives a ligature substitution, and matching HarfBuzz's model
/// field-for-field is what lets `test/shaping/harfbuzz_parity_test.dart` demand
/// byte-exact agreement instead of "looks about right".
library;

/// One glyph in flight through the shaping pipeline.
///
/// Before GSUB runs, [glyphId] holds the glyph the `cmap` resolved for
/// [codepoint]. Substitutions rewrite [glyphId] and may insert or delete
/// entries; [codepoint] and [cluster] are preserved so the PDF's `ToUnicode`
/// CMap can map the final glyphs back to the text a reader copies out.
class GlyphInfo {
  GlyphInfo({
    required this.glyphId,
    required this.codepoint,
    required this.cluster,
    this.joiningType = JoiningType.nonJoining,
    this.generalCategory = 0,
    this.glyphClass = GlyphClass.unclassified,
    this.markAttachClass = 0,
    this.ligatureId = 0,
    this.ligatureComponent = 0,
    this.mask = 0,
    this.multipliedAdvance = false,
  });

  /// Current glyph index in the font. Rewritten by GSUB.
  int glyphId;

  /// The original Unicode scalar this glyph came from, or -1 for a glyph with
  /// no single source (a ligature keeps the *first* component's codepoint and
  /// relies on [cluster] to carry the rest).
  int codepoint;

  /// Index into the source text. Glyphs that merged share a cluster; a glyph
  /// that decomposed into several keeps one. Cluster values only ever merge
  /// downward, which is what makes them safe to use for `ActualText` spans.
  int cluster;

  /// Arabic joining type from `ArabicShaping.txt`, resolved before the joining
  /// state machine runs.
  int joiningType;

  /// Unicode general category, packed as an index into [GeneralCategory].
  int generalCategory;

  /// `GDEF` glyph class — base, ligature, mark or component. Drives lookup-flag
  /// skipping, so a wrong value here silently misplaces every mark in the run.
  int glyphClass;

  /// `GDEF` mark attachment class, for `LookupFlag.markAttachmentType`.
  int markAttachClass;

  /// Identifies which ligature this glyph belongs to. Zero means "not part of
  /// one". Marks inherit the id of the ligature they attached to so that
  /// mark-to-ligature positioning can find their component afterwards.
  int ligatureId;

  /// 1-based component index within [ligatureId]; 0 for the ligature itself.
  int ligatureComponent;

  /// Bitmask of the features enabled for this glyph. The Arabic shaper sets
  /// exactly one of the `isol`/`init`/`medi`/`fina` bits per glyph here, which
  /// is how one GSUB pass applies four mutually exclusive features.
  int mask;

  /// Set when `stch`-style advance multiplication has already been applied, so
  /// a second positioning pass does not double it.
  bool multipliedAdvance;

  GlyphInfo copy() => GlyphInfo(
    glyphId: glyphId,
    codepoint: codepoint,
    cluster: cluster,
    joiningType: joiningType,
    generalCategory: generalCategory,
    glyphClass: glyphClass,
    markAttachClass: markAttachClass,
    ligatureId: ligatureId,
    ligatureComponent: ligatureComponent,
    mask: mask,
    multipliedAdvance: multipliedAdvance,
  );

  @override
  String toString() => 'GlyphInfo(gid: $glyphId, cluster: $cluster)';
}

/// Where one glyph sits relative to the pen, in font design units.
///
/// Units are the font's own (`head.unitsPerEm`), never points — scaling happens
/// once, at the PDF content-stream boundary, so shaping stays integer-exact and
/// comparable with HarfBuzz's unscaled output.
class GlyphPosition {
  GlyphPosition({
    this.xAdvance = 0,
    this.yAdvance = 0,
    this.xOffset = 0,
    this.yOffset = 0,
    this.attachChain = 0,
    this.attachType = 0,
  });

  int xAdvance;
  int yAdvance;
  int xOffset;
  int yOffset;

  /// Relative index (may be negative) of the glyph this one is attached to.
  /// Zero means unattached. Resolved into absolute offsets by the final
  /// `_propagateAttachments` pass, exactly as HarfBuzz does.
  int attachChain;

  /// [attachTypeMark] or [attachTypeCursive].
  int attachType;

  static const int attachTypeNone = 0;
  static const int attachTypeMark = 1;
  static const int attachTypeCursive = 2;

  GlyphPosition copy() => GlyphPosition(
    xAdvance: xAdvance,
    yAdvance: yAdvance,
    xOffset: xOffset,
    yOffset: yOffset,
    attachChain: attachChain,
    attachType: attachType,
  );

  @override
  String toString() =>
      'GlyphPosition(adv: $xAdvance,$yAdvance off: $xOffset,$yOffset)';
}

/// Text direction of a shaping run.
enum TextDirection {
  ltr,
  rtl;

  bool get isHorizontalRtl => this == TextDirection.rtl;
}

/// `GDEF` glyph classes. The numeric values are the spec's, so they can be read
/// straight out of a `ClassDef` with no translation.
abstract final class GlyphClass {
  static const int unclassified = 0;
  static const int base = 1;
  static const int ligature = 2;
  static const int mark = 3;
  static const int component = 4;
}

/// Arabic joining types from `ArabicShaping.txt`.
///
/// [transparent] is the `T` class — combining marks that the joining state
/// machine must see through, not stop at. Getting that wrong is why naive
/// shapers break `ڕێـ` the moment a diacritic appears.
abstract final class JoiningType {
  static const int nonJoining = 0; // U
  static const int leftJoining = 1; // L
  static const int rightJoining = 2; // R
  static const int dualJoining = 3; // D
  static const int joinCausing = 4; // C  (ZWJ, tatweel)
  static const int transparent = 5; // T
}

/// The Unicode general categories the shaper actually branches on.
abstract final class GeneralCategory {
  static const int unassigned = 0;
  static const int nonSpacingMark = 1; // Mn
  static const int spacingMark = 2; // Mc
  static const int enclosingMark = 3; // Me
  static const int decimalNumber = 4; // Nd
  static const int format = 5; // Cf
  static const int other = 6;

  static bool isMark(int c) =>
      c == nonSpacingMark || c == spacingMark || c == enclosingMark;
}

/// A run of text being shaped, and the result of shaping it.
///
/// The buffer is reused across [reset] calls so that laying out a page of a
/// document does not allocate a buffer per line.
class GlyphBuffer {
  final List<GlyphInfo> infos = <GlyphInfo>[];
  final List<GlyphPosition> positions = <GlyphPosition>[];

  /// Direction of this run, resolved by the bidi pass before shaping.
  TextDirection direction = TextDirection.ltr;

  /// OpenType script tag for this run (`arab`, `latn`, …).
  int script = 0;

  /// OpenType language-system tag, or `DFLT`.
  int language = 0;

  int get length => infos.length;

  bool get isEmpty => infos.isEmpty;

  bool get isNotEmpty => infos.isNotEmpty;

  void reset() {
    infos.clear();
    positions.clear();
    direction = TextDirection.ltr;
    script = 0;
    language = 0;
  }

  /// Seeds the buffer from Unicode scalars. [clusterBase] offsets the cluster
  /// values so a run extracted from the middle of a paragraph still reports
  /// clusters in paragraph coordinates.
  void addCodepoints(List<int> codepoints, {int clusterBase = 0}) {
    for (var i = 0; i < codepoints.length; i++) {
      infos.add(
        GlyphInfo(
          glyphId: 0,
          codepoint: codepoints[i],
          cluster: clusterBase + i,
        ),
      );
      positions.add(GlyphPosition());
    }
  }

  /// Reverses the buffer in place, keeping infos and positions in lockstep.
  ///
  /// RTL runs are shaped in *logical* order and reversed once at the end. Both
  /// HarfBuzz and this engine do it that way because GSUB context rules are
  /// specified in logical order; reversing first would match the wrong contexts.
  void reverse() {
    for (var i = 0, j = infos.length - 1; i < j; i++, j--) {
      final ti = infos[i];
      infos[i] = infos[j];
      infos[j] = ti;
      final tp = positions[i];
      positions[i] = positions[j];
      positions[j] = tp;
    }
  }

  /// Total advance of the run in font design units.
  int get totalXAdvance {
    var sum = 0;
    for (final p in positions) {
      sum += p.xAdvance;
    }
    return sum;
  }

  @override
  String toString() =>
      'GlyphBuffer(${infos.length} glyphs, $direction, ${infos.map((i) => i.glyphId).join(" ")})';
}
