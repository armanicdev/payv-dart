/// The feature plan — which features run, in which order, and on which glyphs.
///
/// This is the piece that decides whether `ڵ` comes out as `uni06B5.medi` or as
/// a bare `uni06B5`, and it does it WITHOUT ever substituting anything itself.
/// The trick, which is HarfBuzz's, is worth stating plainly because it is not
/// obvious:
///
///  * `isol`, `init`, `medi` and `fina` are mutually exclusive per glyph, but
///    they are four separate OpenType features over four separate lookups.
///  * So each gets a BIT. The Arabic joining state machine sets exactly one bit
///    per glyph in [GlyphInfo.mask], and every lookup carries the union of the
///    bits of the features that reached it.
///  * A lookup then applies to a glyph only when `glyph.mask & lookup.mask != 0`.
///
/// One GSUB traversal therefore applies four contradictory features correctly.
/// The alternative — running the buffer once per feature and hand-picking which
/// glyphs to touch — is how shapers end up with initial forms in the middle of
/// words.
///
/// ORDER IS PART OF THE ANSWER. Features are grouped into *stages* separated by
/// pauses, and within a stage lookups run in ascending LookupList index (which
/// is what [LayoutTable.stagedLookups] returns, and why it returns it). Get the
/// stage boundaries wrong and a handful of cases in the parity corpus fail while
/// the rest pass — `kurdistan` loses `uniFE98.long`, or `palawtn` ligates before
/// it has been given a joining form. Total failure would be easier to notice.
library;

import '../layout/script_list.dart';
import '../util/tag.dart';
import 'glyph_buffer.dart';

/// One lookup as the plan schedules it: which lookup, and the mask that decides
/// which glyphs it may touch.
class PlannedLookup {
  const PlannedLookup({
    required this.lookupIndex,
    required this.mask,
    required this.autoZwnj,
    required this.autoZwj,
  });

  final int lookupIndex;

  /// Bitwise-ANDed against [GlyphInfo.mask]; non-zero means "apply here".
  final int mask;

  /// When true (the default), a ZWNJ is *skipped* by this lookup's matcher, so
  /// it cannot break a context. Unicode says a ZWNJ means "do not ligate", so
  /// the ligating features clear this and let the ZWNJ block the match.
  final bool autoZwnj;

  /// The same for ZWJ. Arabic clears it on `rclt`/`calt` because in Arabic
  /// script a ZWJ also means "do not ligate" — it is a joining request, not a
  /// ligating one.
  final bool autoZwj;

  @override
  String toString() =>
      'PlannedLookup($lookupIndex, mask 0x${mask.toRadixString(16)})';
}

/// A group of lookups applied back to back, with a pause after it.
///
/// A pause matters because some lookups are only correct once everything before
/// them has settled: the font's `rlig` ligatures expect glyphs that have already
/// taken their joining form, and Uniscribe — which the fonts were tested
/// against — pauses in the same places.
class PlanStage {
  const PlanStage(this.lookups);

  final List<PlannedLookup> lookups;

  bool get isEmpty => lookups.isEmpty;

  @override
  String toString() => 'PlanStage(${lookups.length} lookups)';
}

/// The compiled plan for one (font, script, language, direction, user features)
/// combination.
class ShapingPlan {
  ShapingPlan._({
    required this.script,
    required this.language,
    required this.direction,
    required this.gsubStages,
    required this.gposStages,
    required this.globalMask,
    required Map<int, int> masks,
    required Set<int> present,
  }) : _masks = masks,
       _present = present;

  final int script;
  final int language;
  final TextDirection direction;

  /// GSUB stages in application order.
  final List<PlanStage> gsubStages;

  /// GPOS stages in application order. In practice one — nothing in the
  /// horizontal pipeline calls for a GPOS pause — but the shape of the field is
  /// what lets a future shaper add one without a rewrite.
  final List<PlanStage> gposStages;

  /// The mask every glyph starts with: the global bit, plus the default value of
  /// any feature that is on by default.
  final int globalMask;

  final Map<int, int> _masks;
  final Set<int> _present;

  /// The mask bit for [featureTag], or 0 when the plan does not carry it.
  ///
  /// 0 is meaningful and correct: a lookup gated on a zero mask never matches,
  /// which is exactly how a user's `FontFeature.disable('liga')` turns `liga`
  /// off without the plan needing a second code path.
  int maskFor(int featureTag) => _masks[featureTag] ?? 0;

  /// Whether the font actually carries [featureTag] for this script/language.
  bool hasFeature(int featureTag) => _present.contains(featureTag);

  @override
  String toString() =>
      'ShapingPlan(${Tag(script).asString}/${Tag(language).asString}, '
      '$direction, ${gsubStages.length} GSUB stages, '
      '${gposStages.length} GPOS stages)';
}

/// Flags a feature can carry into the plan.
abstract final class FeatureFlag {
  static const int none = 0;

  /// On for every glyph — the feature shares the plan's global bit instead of
  /// burning one of its own.
  static const int global = 1;

  /// Do not let this lookup see through a ZWNJ.
  static const int manualZwnj = 2;

  /// Do not let this lookup see through a ZWJ.
  static const int manualZwj = 4;

  /// The shaper can synthesise this feature's effect if the font omits it, so
  /// keep a bit for it even when the font has no such feature. Arabic wants this
  /// for `isol`/`init`/`medi`/`fina`.
  static const int hasFallback = 8;
}

class _FeatureInfo {
  _FeatureInfo(this.tag, this.flags, this.maxValue, this.defaultValue, this.seq)
    : gsubStage = 0,
      gposStage = 0;

  final int tag;
  int flags;
  int maxValue;
  int defaultValue;

  /// Insertion order, so that the sort by tag stays stable and two adds of the
  /// same tag merge in the order they were written.
  final int seq;

  int gsubStage;
  int gposStage;
}

/// Builds a [ShapingPlan] the way HarfBuzz's `hb_ot_map_builder_t` does.
///
/// The sequence is: collect every feature anyone wants (the generic pipeline,
/// then the script's own shaper, then the common/horizontal sets, then the
/// caller's), sort and merge duplicates keeping the EARLIEST stage each was
/// requested at, allocate one bit per non-global feature, and finally resolve
/// each stage's lookups through the font.
///
/// Merging on the earliest stage is not a detail. `ccmp` is requested twice —
/// once by the Arabic shaper near the front, once by the generic common set at
/// the very end — and it has to run at the front, before the joining features,
/// or the lam-alef ligature never gets a chance to form.
class ShapingPlanBuilder {
  ShapingPlanBuilder({
    required this.script,
    required this.language,
    required this.direction,
  });

  final int script;
  final int language;
  final TextDirection direction;

  final List<_FeatureInfo> _features = <_FeatureInfo>[];
  int _gsubStage = 0;
  int _gposStage = 0;
  int _seq = 0;

  /// Adds [tag] as on-for-every-glyph.
  void enableFeature(int tag, {int flags = FeatureFlag.none, int value = 1}) =>
      addFeature(tag, flags: flags | FeatureFlag.global, value: value);

  /// Adds [tag] as off by default, to be switched on per glyph by whoever owns
  /// the mask — the Arabic joining machine, or the fraction pass.
  void addFeature(int tag, {int flags = FeatureFlag.none, int value = 1}) {
    final info = _FeatureInfo(
      tag,
      flags,
      value,
      flags & FeatureFlag.global != 0 ? value : 0,
      _seq++,
    );
    info.gsubStage = _gsubStage;
    info.gposStage = _gposStage;
    _features.add(info);
  }

  /// Ends the current GSUB stage. Everything added after this runs strictly
  /// after everything added before it.
  void addGsubPause() => _gsubStage++;

  /// Ends the current GPOS stage. Unused by the horizontal pipeline; here so a
  /// script that needs one is a two-line change rather than a redesign.
  void addGposPause() => _gposStage++;

  ShapingPlan compile({LayoutTable? gsub, LayoutTable? gpos}) {
    // ── merge duplicates ──────────────────────────────────────────────────────
    final sorted = List<_FeatureInfo>.from(_features)
      ..sort((a, b) => a.tag != b.tag ? a.tag - b.tag : a.seq - b.seq);

    final merged = <_FeatureInfo>[];
    for (final info in sorted) {
      if (merged.isNotEmpty && merged.last.tag == info.tag) {
        final j = merged.last;
        if (info.flags & FeatureFlag.global != 0) {
          // A later GLOBAL add wins outright on value. That is what makes a
          // caller's explicit `FontFeature('liga', 0)` beat the default enable:
          // it arrives last and drops maxValue to 0, which allocates a zero
          // mask, which no lookup can ever match.
          j.flags |= FeatureFlag.global;
          j.maxValue = info.maxValue;
          j.defaultValue = info.defaultValue;
        } else {
          j.flags &= ~FeatureFlag.global;
          if (info.maxValue > j.maxValue) j.maxValue = info.maxValue;
        }
        j.flags |= info.flags & FeatureFlag.hasFallback;
        // Earliest stage wins — see the class comment.
        if (info.gsubStage < j.gsubStage) j.gsubStage = info.gsubStage;
        if (info.gposStage < j.gposStage) j.gposStage = info.gposStage;
      } else {
        merged.add(info);
      }
    }

    // ── allocate bits ─────────────────────────────────────────────────────────
    //
    // Bit 0 is the global bit, set on every glyph. A feature that is global with
    // a max value of 1 needs nothing of its own and simply borrows it.
    const globalBit = 1;
    var nextBit = 1;
    var globalMask = globalBit;

    // Resolved once each: this is a walk of the font's ScriptList, and asking it
    // per feature would make plan compilation quadratic in the feature count for
    // no gain.
    final inGsubSet = gsub == null
        ? const <int>{}
        : gsub.availableFeatures(script: script, language: language);
    final inGposSet = gpos == null
        ? const <int>{}
        : gpos.availableFeatures(script: script, language: language);

    final masks = <int, int>{};
    final present = <int>{};
    final flagsOf = <int, int>{};
    final gsubOf = <int, int>{};
    final gposOf = <int, int>{};

    for (final info in merged) {
      final inGsub = inGsubSet.contains(info.tag);
      final inGpos = inGposSet.contains(info.tag);
      if (inGsub || inGpos) present.add(info.tag);

      // A feature the font does not carry gets no bit and no lookups — unless a
      // shaper says it can synthesise the effect, in which case the bit still
      // has to exist for the shaper to set.
      if (!inGsub && !inGpos && info.flags & FeatureFlag.hasFallback == 0) {
        continue;
      }

      int mask;
      if (info.flags & FeatureFlag.global != 0 && info.maxValue == 1) {
        mask = globalBit;
      } else {
        final bitsNeeded = _bitStorage(info.maxValue);
        if (nextBit + bitsNeeded > 32) continue; // out of bits; drop it
        mask = ((1 << bitsNeeded) - 1) << nextBit;
        globalMask |= (info.defaultValue << nextBit) & mask;
        nextBit += bitsNeeded;
      }
      masks[info.tag] = mask;
      flagsOf[info.tag] = info.flags;
      gsubOf[info.tag] = info.gsubStage;
      gposOf[info.tag] = info.gposStage;
    }

    return ShapingPlan._(
      script: script,
      language: language,
      direction: direction,
      gsubStages: _resolve(gsub, masks, flagsOf, gsubOf, _gsubStage),
      gposStages: _resolve(gpos, masks, flagsOf, gposOf, _gposStage),
      globalMask: globalMask,
      masks: masks,
      present: present,
    );
  }

  /// Turns "feature tag → stage" into "stage → lookups, in lookup order".
  ///
  /// Empty stages are dropped rather than kept as no-ops: a pause is only a
  /// boundary between lookups, so a stage that resolved to nothing has nothing
  /// to be a boundary for.
  List<PlanStage> _resolve(
    LayoutTable? table,
    Map<int, int> masks,
    Map<int, int> flagsOf,
    Map<int, int> stageOf,
    int stageCount,
  ) {
    if (table == null) return const <PlanStage>[];

    final out = <PlanStage>[];
    for (var stage = 0; stage <= stageCount; stage++) {
      final tags = <int>{
        for (final e in stageOf.entries)
          if (e.value == stage) e.key,
      };
      if (tags.isEmpty) continue;

      final staged = table.stagedLookups(
        script: script,
        language: language,
        features: tags,
      );
      if (staged.isEmpty) continue;

      out.add(
        PlanStage([for (final l in staged) _plan(l, tags, masks, flagsOf)]),
      );
    }
    return out;
  }

  /// One [StagedLookup] merged with the masks and joiner flags of every feature
  /// in this stage that reaches it.
  ///
  /// The mask is a UNION and the joiner flags are an INTERSECTION, both because
  /// the lookup runs once. If either of two features wants it applied to a glyph
  /// it must be; if either wants the matcher to see a joiner, it must.
  PlannedLookup _plan(
    StagedLookup l,
    Set<int> tags,
    Map<int, int> masks,
    Map<int, int> flagsOf,
  ) {
    var mask = 0;
    var autoZwnj = true;
    var autoZwj = true;
    for (final t in l.featureTags) {
      if (!tags.contains(t)) continue;
      mask |= masks[t] ?? 0;
      final f = flagsOf[t] ?? 0;
      autoZwnj &= f & FeatureFlag.manualZwnj == 0;
      autoZwj &= f & FeatureFlag.manualZwj == 0;
    }
    return PlannedLookup(
      lookupIndex: l.lookupIndex,
      mask: mask,
      autoZwnj: autoZwnj,
      autoZwj: autoZwj,
    );
  }

  static int _bitStorage(int v) {
    var bits = 0;
    while (v > 0) {
      bits++;
      v >>= 1;
    }
    return bits;
  }
}
