/// [Shaper] — text in, positioned glyphs out.
///
/// This is the whole pipeline in one class, and the order of its steps is not
/// negotiable: it is the order HarfBuzz uses, and `harfbuzz_parity_test.dart`
/// compares against HarfBuzz glyph id for glyph id and advance for advance.
///
///     scalars
///       → guess script and direction
///       → Unicode properties, grapheme clusters
///       → mirror brackets (RTL)
///       → normalise, and resolve every glyph through the cmap
///       → per-glyph feature masks (the Arabic joining state machine)
///       → GSUB, stage by stage
///       → default advances from hmtx
///       → GPOS, then zero marks, resolve attachments, reverse for RTL
///       → hide the joiners that did their job
///
/// ONE SEGMENT, ONE SCRIPT. [shape] resolves a single script and a single
/// direction for the whole string, from the first strong character, exactly as
/// `hb_buffer_guess_segment_properties` does. It does NOT run bidi and it does
/// NOT itemize — a mixed string comes out in one piece under one script, which
/// is what makes its output comparable with HarfBuzz's. Bidi and itemization
/// belong one level up, in the layout engine, which calls [shapeScalars] once
/// per resolved run. Doing it here would quietly make this class unmeasurable.
library;

import '../api/text_style.dart' show FontFeature;
import '../font/open_type_font.dart';
import '../layout/gdef.dart';
import '../layout/gpos.dart';
import '../text/script_itemizer.dart';
import '../text/unicode.dart';
import '../util/tag.dart';
import 'arabic_shaper.dart';
import 'default_shaper.dart';
import 'glyph_buffer.dart';
import 'normalize.dart';
import 'shaping_plan.dart';

/// The result of shaping one run: glyphs, positions, and the direction they are
/// already laid out in.
///
/// Both lists are in VISUAL order — an RTL run has been reversed — because that
/// is the order a PDF content stream and a canvas both want, and because storing
/// logical order in a PDF gives every extractor backwards Kurdish.
class ShapedRun {
  const ShapedRun(this.infos, this.positions, this.direction);

  final List<GlyphInfo> infos;
  final List<GlyphPosition> positions;
  final TextDirection direction;

  int get length => infos.length;

  /// Total advance in font design units. Divide by `unitsPerEm` and multiply by
  /// the point size to get a width.
  int get totalXAdvance {
    var sum = 0;
    for (final p in positions) {
      sum += p.xAdvance;
    }
    return sum;
  }

  @override
  String toString() =>
      'ShapedRun($length glyphs, $direction, '
      '${infos.map((i) => i.glyphId).join(" ")})';
}

/// Shapes text with one font.
///
/// Cheap to construct and safe to keep: it caches compiled plans, which is the
/// expensive part of shaping a page of text. It is NOT thread-safe, but neither
/// is anything else in a Dart isolate.
class Shaper {
  Shaper(this.font);

  final OpenTypeFont font;

  final Map<int, ShapingPlan> _planCache = <int, ShapingPlan>{};
  late final Normalizer _normalizer = Normalizer(font);
  final GlyphBuffer _buffer = GlyphBuffer();

  /// Shapes [text], guessing script and direction from its first strong
  /// character.
  ///
  /// Clusters come back as UTF-16 indices into [text] — the caller's own
  /// coordinates — so a cluster can be used directly to slice the string for an
  /// `ActualText` span or a hit test. That silently disagrees with a scalar
  /// index the moment an emoji or a rare CJK ideograph appears, which is exactly
  /// why the offset map exists.
  ShapedRun shape(
    String text, {
    int? script,
    int? language,
    TextDirection? direction,
    List<FontFeature> features = const <FontFeature>[],
  }) {
    final (scalars, utf16Offsets) = toScalars(text);
    final resolvedScript = script ?? guessScript(scalars);
    return _shape(
      scalars,
      clusters: utf16Offsets,
      script: resolvedScript,
      language: language ?? Tag.dflt,
      direction: direction ?? horizontalDirectionOf(resolvedScript),
      features: features,
    );
  }

  /// Shapes a run whose script and direction the caller has already resolved —
  /// the entry point a bidi-aware layout engine uses.
  ///
  /// Clusters come back as `clusterBase + index into [scalars]`, so a run taken
  /// from the middle of a paragraph still reports in paragraph coordinates.
  ShapedRun shapeScalars(
    List<int> scalars, {
    required int script,
    int? language,
    required TextDirection direction,
    List<FontFeature> features = const <FontFeature>[],
    int clusterBase = 0,
  }) => _shape(
    scalars,
    clusters: [for (var i = 0; i < scalars.length; i++) clusterBase + i],
    script: script,
    language: language ?? Tag.dflt,
    direction: direction,
    features: features,
  );

  ShapedRun _shape(
    List<int> scalars, {
    required List<int> clusters,
    required int script,
    required int language,
    required TextDirection direction,
    required List<FontFeature> features,
  }) {
    final plan = _planFor(script, language, direction, features);
    final shaper = shaperForScript(script);

    final buffer = _buffer
      ..reset()
      ..direction = direction
      ..script = script
      ..language = language;

    for (var i = 0; i < scalars.length; i++) {
      buffer.infos.add(
        GlyphInfo(glyphId: 0, codepoint: scalars[i], cluster: clusters[i]),
      );
      buffer.positions.add(GlyphPosition());
    }
    if (buffer.isEmpty) return ShapedRun(const [], const [], direction);

    _setUnicodeProps(buffer, plan);
    _formClusters(buffer);
    _ensureNativeDirection(buffer);

    // ── substitution ──────────────────────────────────────────────────────────
    _mirrorChars(buffer, plan);
    _normalizer.normalize(buffer, shaper);
    shaper.setupMasks(buffer, plan);

    final gdef = font.gdef;
    _assignGlyphClasses(buffer, gdef);

    final gsub = font.gsub;
    if (gsub != null) {
      for (final stage in plan.gsubStages) {
        for (final lookup in stage.lookups) {
          gsub.applyLookup(
            lookup.lookupIndex,
            buffer,
            mask: lookup.mask,
            gdef: gdef,
          );
        }
      }
    }

    // ── positioning ───────────────────────────────────────────────────────────
    buffer.positions
      ..clear()
      ..addAll([
        for (final info in buffer.infos)
          GlyphPosition(xAdvance: font.advanceWidth(info.glyphId)),
      ]);

    final gpos = font.gpos;
    if (gpos != null) {
      for (final stage in plan.gposStages) {
        for (final lookup in stage.lookups) {
          gpos.applyLookup(
            lookup.lookupIndex,
            buffer,
            mask: lookup.mask,
            gdef: gdef,
            coords: font.variationCoords,
          );
        }
      }
    }

    GposTable.positionFinish(
      buffer,
      // A font with a working `mark` feature has already placed its marks; the
      // forward-direction offset compensation would move them a second time.
      // Stated explicitly even though it matches the default — this is a
      // correctness decision, not a defaulted argument.
      // ignore: avoid_redundant_argument_values
      adjustOffsetsWhenZeroing: false,
    );

    _hideJoiners(buffer);

    return ShapedRun(
      List<GlyphInfo>.of(buffer.infos),
      List<GlyphPosition>.of(buffer.positions),
      buffer.direction,
    );
  }

  // ── plan ────────────────────────────────────────────────────────────────────

  ShapingPlan _planFor(
    int script,
    int language,
    TextDirection direction,
    List<FontFeature> features,
  ) {
    final key = Object.hash(
      script,
      language,
      direction,
      Object.hashAll([for (final f in features) f.tag * 31 + f.value]),
    );
    final cached = _planCache[key];
    if (cached != null) return cached;

    final builder = ShapingPlanBuilder(
      script: script,
      language: language,
      direction: direction,
    );
    collectAllFeatures(builder, shaperForScript(script));
    for (final f in features) {
      // A caller's feature arrives LAST, so the merge in `compile` lets it beat
      // the default schedule — including down to value 0, which allocates a zero
      // mask and switches the feature off without a second code path.
      builder.addFeature(f.tag, flags: FeatureFlag.global, value: f.value);
    }

    return _planCache[key] = builder.compile(
      gsub: font.gsub?.layout,
      gpos: font.gpos?.layout,
    );
  }

  // ── the passes this class owns ──────────────────────────────────────────────

  /// Fills in the Unicode properties every later pass reads, and seeds the mask.
  void _setUnicodeProps(GlyphBuffer buffer, ShapingPlan plan) {
    for (final info in buffer.infos) {
      info
        ..generalCategory = generalCategoryOf(info.codepoint)
        ..joiningType = joiningTypeOf(info.codepoint)
        ..mask = plan.globalMask;
    }
  }

  /// Merges the cluster of every combining mark into the character it sits on.
  ///
  /// Without this, `بّب` reports three clusters and a PDF extractor hands the
  /// shadda back as if it were a separate character from the letter it sits on.
  /// HarfBuzz calls this cluster level "monotone graphemes" and it is the
  /// default there for the same reason it is not optional here.
  ///
  /// A ZWJ continues its cluster too — UAX #29 rule GB9 — which is not a detail
  /// anyone would guess. `ڵ‍` is ONE grapheme, so the joiner and the letter must
  /// report the same cluster even though the joiner is a format character and
  /// not a mark.
  static void _formClusters(GlyphBuffer buffer) {
    var start = 0;
    for (var i = 1; i <= buffer.length; i++) {
      final isContinuation =
          i < buffer.length &&
          (GeneralCategory.isMark(buffer.infos[i].generalCategory) ||
              buffer.infos[i].codepoint == _zwj);
      if (isContinuation) continue;
      if (i - start > 1) {
        var min = buffer.infos[start].cluster;
        for (var j = start + 1; j < i; j++) {
          if (buffer.infos[j].cluster < min) min = buffer.infos[j].cluster;
        }
        for (var j = start; j < i; j++) {
          buffer.infos[j].cluster = min;
        }
      }
      start = i;
    }
  }

  /// Reverses the buffer when the caller asked for a direction the script does
  /// not natively run in.
  ///
  /// GSUB context rules are written in the script's own reading order, so a
  /// backwards buffer matches the wrong contexts. Reversing here and again at
  /// the end costs two passes and keeps every lookup in between correct.
  static void _ensureNativeDirection(GlyphBuffer buffer) {
    final native = horizontalDirectionOf(buffer.script);
    if (buffer.direction == native) return;
    buffer.reverse();
    buffer.direction = buffer.direction == TextDirection.rtl
        ? TextDirection.ltr
        : TextDirection.rtl;
  }

  /// Swaps paired brackets for their mirror image in an RTL run.
  ///
  /// A `(` in Kurdish text opens on the right, so it must be DRAWN as `)`. Where
  /// the font has no mirrored glyph the character keeps its codepoint and gets
  /// the `rtlm` bit instead, so a font that ships its own mirroring feature can
  /// do the job the cmap could not.
  ///
  /// Only paired brackets are mirrored, not the whole Bidi_Mirrored set — the
  /// engine carries `BidiBrackets.txt` for rule N0 and does not carry
  /// `BidiMirroring.txt`. The difference is `<`, `»` and about a hundred maths
  /// symbols, which no Kurdish document uses and which no font mirrors anyway.
  void _mirrorChars(GlyphBuffer buffer, ShapingPlan plan) {
    if (buffer.direction != TextDirection.rtl) return;
    final rtlm = plan.maskFor(_rtlm);
    for (final info in buffer.infos) {
      final mirrored = pairedBracketOf(info.codepoint);
      if (mirrored > 0 && font.glyphForCodepoint(mirrored) != 0) {
        info.codepoint = mirrored;
      } else if (rtlm != 0) {
        info.mask |= rtlm;
      }
    }
  }

  /// Seeds every glyph's `GDEF` class before the first lookup runs.
  ///
  /// Every `Ignore*` lookup flag reads these. A buffer that reaches GSUB with
  /// them all zero skips nothing, so a mark blocks the very contexts the flags
  /// exist to see through — and the word comes out unjoined with no error.
  static void _assignGlyphClasses(GlyphBuffer buffer, GdefTable? gdef) {
    if (gdef == null || !gdef.hasGlyphClasses) return;
    for (final info in buffer.infos) {
      info
        ..glyphClass = gdef.glyphClass(info.glyphId)
        ..markAttachClass = gdef.markAttachClass(info.glyphId);
    }
  }

  /// Replaces the joiners and other default-ignorables that survived shaping
  /// with a zero-width space glyph.
  ///
  /// They are not deleted. Deleting them would renumber the buffer after
  /// positioning, and a caller mapping glyphs back to text would find the
  /// indices had moved under it. HarfBuzz makes the same call: swap the glyph,
  /// zero the metrics, leave the slot.
  void _hideJoiners(GlyphBuffer buffer) {
    var space = -1;
    for (var i = 0; i < buffer.length; i++) {
      final info = buffer.infos[i];
      if (!isDefaultIgnorable(info.codepoint)) continue;
      if (space < 0) space = font.glyphForCodepoint(0x20);
      if (space != 0) info.glyphId = space;
      buffer.positions[i]
        ..xAdvance = 0
        ..yAdvance = 0
        ..xOffset = 0
        ..yOffset = 0;
    }
  }

  /// The per-script strategy for [scriptTag].
  ///
  /// Only the cursive-joining scripts get a shaper of their own here. The Indic,
  /// Khmer, Myanmar and Hangul families need reordering engines this package
  /// does not have; they fall back to the default shaper, which applies their
  /// features correctly but does not reorder — legible, not correct, and said
  /// out loud rather than silently approximated.
  static ScriptShaper shaperForScript(int scriptTag) =>
      _cursiveScripts.contains(scriptTag)
      ? ArabicShaper(script: scriptTag)
      : const DefaultShaper();
}

/// The OpenType script tag of the first strong character, or `DFLT`.
///
/// "Strong" here is the Unicode Script property, not the bidi class: an
/// Arabic-Indic digit carries script Arabic and is enough to make a run RTL,
/// which is what puts `٤٥٬٠٠٠ د.ع` the right way round.
int guessScript(List<int> scalars) {
  final runs = ScriptItemizer.itemize(scalars);
  return runs.isEmpty ? Tag.dflt : runs.first.scriptTag;
}

/// The direction a script is written in.
TextDirection horizontalDirectionOf(int scriptTag) =>
    _rtlScripts.contains(scriptTag) ? TextDirection.rtl : TextDirection.ltr;

/// True for the codepoints a shaper must make invisible once they have done
/// their job — joiners, bidi controls, variation selectors, the fillers.
///
/// Derived from `DerivedCoreProperties.txt`'s Default_Ignorable_Code_Point, as
/// ranges rather than a generated table: the property covers about a dozen
/// blocks and is stable enough that a range list is easier to check by eye than
/// a binary search into 4 000 ints.
bool isDefaultIgnorable(int cp) {
  if (cp < 0x00AD) return false;
  return cp == 0x00AD ||
      cp == 0x034F ||
      cp == 0x061C ||
      (cp >= 0x115F && cp <= 0x1160) ||
      (cp >= 0x17B4 && cp <= 0x17B5) ||
      (cp >= 0x180B && cp <= 0x180F) ||
      (cp >= 0x200B && cp <= 0x200F) ||
      (cp >= 0x202A && cp <= 0x202E) ||
      (cp >= 0x2060 && cp <= 0x206F) ||
      cp == 0x3164 ||
      (cp >= 0xFE00 && cp <= 0xFE0F) ||
      cp == 0xFEFF ||
      cp == 0xFFA0 ||
      (cp >= 0xFFF0 && cp <= 0xFFF8) ||
      (cp >= 0x1BCA0 && cp <= 0x1BCA3) ||
      (cp >= 0x1D173 && cp <= 0x1D17A) ||
      (cp >= 0xE0000 && cp <= 0xE0FFF);
}

/// Scripts that join cursively, and therefore need the joining state machine.
const Set<int> _cursiveScripts = <int>{
  Tag.arab,
  Tag.syrc,
  Tag.nko,
  Tag.mong,
  Tag.phag,
  Tag.mand,
  _mani,
  _phlp,
  _rohg,
  _sogd,
  _sogo,
  _ougr,
  _chrs,
};

/// Scripts written right to left.
///
/// Wider than [_cursiveScripts]: Hebrew, Thaana and the historical Semitic
/// scripts run right to left without joining, and they still need the buffer
/// reversed.
const Set<int> _rtlScripts = <int>{
  Tag.arab,
  Tag.syrc,
  Tag.nko,
  Tag.thaa,
  Tag.mand,
  Tag.adlm,
  _hebr,
  _samr,
  _mend,
  _mani,
  _phlp,
  _rohg,
  _sogd,
  _sogo,
  _ougr,
  _chrs,
  _armi,
  _avst,
  _cprt,
  _khar,
  _lydi,
  _mero,
  _merc,
  _narb,
  _nbat,
  _palm,
  _phli,
  _phnx,
  _prti,
  _sarb,
  _orkh,
  _hatr,
  _hung,
  _yezi,
  _elym,
};

const int _rtlm = 0x72746C6D; // 'rtlm'

/// U+200D ZERO WIDTH JOINER.
const int _zwj = 0x200D;
const int _hebr = 0x68656272;
const int _samr = 0x73616D72;
const int _mend = 0x6D656E64;
const int _mani = 0x6D616E69;
const int _phlp = 0x70686C70;
const int _rohg = 0x726F6867;
const int _sogd = 0x736F6764;
const int _sogo = 0x736F676F;
const int _ougr = 0x6F756772;
const int _chrs = 0x63687273;
const int _armi = 0x61726D69;
const int _avst = 0x61767374;
const int _cprt = 0x63707274;
const int _khar = 0x6B686172;
const int _lydi = 0x6C796469;
const int _mero = 0x6D65726F;
const int _merc = 0x6D657263;
const int _narb = 0x6E617262;
const int _nbat = 0x6E626174;
const int _palm = 0x70616C6D;
const int _phli = 0x70686C69;
const int _phnx = 0x70686E78;
const int _prti = 0x70727469;
const int _sarb = 0x73617262;
const int _orkh = 0x6F726B68;
const int _hatr = 0x68617472;
const int _hung = 0x68756E67;
const int _yezi = 0x79657A69;
const int _elym = 0x656C796D;
