/// The generic shaper, and the feature schedule every script shares.
///
/// "Default" is not "does nothing". Latin still needs `ccmp`, `locl`, `liga`,
/// `clig`, `calt`, `kern`, `mark` and `mkmk` — the `latin-kern` case in the
/// parity corpus is here to prove it, and `AV` is 87 design units narrower than
/// the sum of its advances because `kern` fired.
///
/// The schedule below is HarfBuzz's, stage boundary for stage boundary. Two
/// things about it are easy to get wrong:
///
///  * The script's own shaper contributes features BEFORE the common and
///    horizontal sets, not after. That is what puts Arabic's `ccmp` in an early
///    stage even though the common set asks for `ccmp` again at the very end —
///    duplicates merge onto the EARLIEST stage requested.
///  * `mark` and `mkmk` are the only features in the generic set that refuse to
///    see through ZWJ and ZWNJ. Everything else treats a joiner as invisible.
library;

import '../util/tag.dart';
import 'glyph_buffer.dart';
import 'shaping_plan.dart';

/// A per-script shaping strategy: which extra features it wants, and how it
/// paints per-glyph feature masks onto the buffer.
///
/// Deliberately tiny. Everything a shaper needs to do for Arabic — the whole
/// joining state machine — fits behind [setupMasks], because the substitutions
/// themselves are the font's job, not ours.
abstract class ScriptShaper {
  const ScriptShaper();

  /// Extra features and stage boundaries this script needs, added at the point
  /// in the generic schedule where HarfBuzz adds them.
  void collectFeatures(ShapingPlanBuilder builder) {}

  /// Sets per-glyph bits in [GlyphInfo.mask] before GSUB runs.
  void setupMasks(GlyphBuffer buffer, ShapingPlan plan) {}

  /// Whether this script wants marks reordered by combining class before
  /// shaping. Arabic overrides the plain UAX #15 order for its own marks.
  void reorderMarks(GlyphBuffer buffer, int start, int end) {}
}

/// The shaper for everything that has no shaper of its own.
class DefaultShaper extends ScriptShaper {
  const DefaultShaper();
}

/// Builds the full feature schedule: generic front matter, then [shaper]'s own
/// features, then the common and horizontal sets.
///
/// Order here IS the specification. Reading it top to bottom gives the exact
/// sequence of GSUB stages a run goes through.
void collectAllFeatures(ShapingPlanBuilder builder, ScriptShaper shaper) {
  // `rvrn` — feature variations — gets a stage entirely to itself at the front,
  // because everything after it is allowed to assume the variable instance has
  // already been resolved.
  builder.enableFeature(_rvrn);
  builder.addGsubPause();

  // Direction features. `rtlm` is per-glyph, not global: only a character with
  // no mirrored counterpart in the font gets the bit, so the font can mirror
  // what Unicode could not.
  if (builder.direction == TextDirection.rtl) {
    builder.enableFeature(_rtla);
    builder.addFeature(_rtlm);
  } else {
    builder.enableFeature(_ltra);
    builder.enableFeature(_ltrm);
  }

  // Automatic fractions. Masked, default off — only the digits either side of a
  // U+2044 FRACTION SLASH ever get these bits.
  builder.addFeature(Tag.frac);
  builder.addFeature(Tag.numr);
  builder.addFeature(Tag.dnom);

  shaper.collectFeatures(builder);

  for (final tag in _commonFeatures) {
    builder.enableFeature(
      tag,
      flags: tag == Tag.mark || tag == Tag.mkmk
          // A mark must attach to the base it belongs to even when a joiner sits
          // between them in the buffer, so the positioning matcher is the one
          // place that must NOT skip joiners.
          ? FeatureFlag.manualZwnj | FeatureFlag.manualZwj
          : FeatureFlag.none,
    );
  }
  for (final tag in _horizontalFeatures) {
    builder.enableFeature(
      tag,
      // `kern` keeps its bit even on a font with no GPOS `kern`, so a fallback
      // kerner has something to switch on. We ship no fallback kerner; the flag
      // costs one bit and keeps the plan honest about the feature's existence.
      flags: tag == Tag.kern ? FeatureFlag.hasFallback : FeatureFlag.none,
    );
  }
}

/// Applied to every script, in every direction.
const List<int> _commonFeatures = <int>[
  _abvm,
  _blwm,
  Tag.ccmp,
  Tag.locl,
  Tag.mark,
  Tag.mkmk,
  Tag.rlig,
];

/// Applied only to horizontal runs. (There is no vertical path here — a PDF
/// page of Kurdish is horizontal, and a vertical set would be untested code.)
const List<int> _horizontalFeatures = <int>[
  Tag.calt,
  Tag.clig,
  Tag.curs,
  _dist,
  Tag.kern,
  Tag.liga,
  Tag.rclt,
];

// Tags with no constant in `Tag`, kept private because nothing outside the
// schedule refers to them.
const int _rvrn = 0x7276726E; // 'rvrn'
const int _rtla = 0x72746C61; // 'rtla'
const int _rtlm = 0x72746C6D; // 'rtlm'
const int _ltra = 0x6C747261; // 'ltra'
const int _ltrm = 0x6C74726D; // 'ltrm'
const int _abvm = 0x6162766D; // 'abvm'
const int _blwm = 0x626C776D; // 'blwm'
const int _dist = 0x64697374; // 'dist'
