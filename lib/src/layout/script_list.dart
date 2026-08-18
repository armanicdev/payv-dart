/// The ScriptList / FeatureList / LookupList header that GSUB and GPOS share,
/// and the script → language → feature → lookup resolution built on it.
///
/// GSUB and GPOS have identical headers and differ only below the lookup type,
/// so this is parsed once here and both tables own only their subtables. The
/// job of this file is to answer one question — "which lookups run for this
/// run of text?" — and the answer is three indirections deep: a script picks a
/// LangSys, a LangSys names feature indices, a Feature names lookup indices.
library;

import '../util/byte_reader.dart';
import '../util/tag.dart';

/// A parsed GSUB or GPOS table header.
class LayoutTable {
  LayoutTable._({
    required ByteReader reader,
    required int base,
    required Map<int, int> scripts,
    required List<int> featureTags,
    required List<int> featureOffsets,
    required this.lookupOffsets,
    required this.featureVariationsOffset,
    required this.minorVersion,
  }) : _reader = reader,
       _base = base,
       _scripts = scripts,
       _featureTags = featureTags,
       _featureOffsets = featureOffsets,
       _featureLookups = List<List<int>?>.filled(featureTags.length, null);

  /// Parses the header at [r]'s current position.
  ///
  /// Only the three directory lists are read — every Feature's lookup list is
  /// read on demand, because a Latin+Arabic family ships dozens of features a
  /// given run will never enable.
  static LayoutTable parse(ByteReader r) {
    final base = r.position;
    final major = r.uint16At(base);
    final minor = r.uint16At(base + 2);
    if (major != 1) {
      throw FontFormatException(
        'unsupported layout table version $major.$minor',
      );
    }

    final scriptListOffset = r.uint16At(base + 4);
    final featureListOffset = r.uint16At(base + 6);
    final lookupListOffset = r.uint16At(base + 8);
    int? featureVariations;
    if (minor >= 1) {
      final o = r.uint32At(base + 10);
      if (o != 0) featureVariations = base + o;
    }

    // Every offset below is stored ABSOLUTE. The spec expresses them relative
    // to whichever list contains them, and carrying that relativity around is
    // how offset bugs get written; it is resolved once, here.
    final scripts = <int, int>{};
    if (scriptListOffset != 0) {
      final list = base + scriptListOffset;
      final count = r.uint16At(list);
      for (var i = 0; i < count; i++) {
        final rec = list + 2 + i * 6;
        scripts[r.uint32At(rec)] = list + r.uint16At(rec + 4);
      }
    }

    final featureTags = <int>[];
    final featureOffsets = <int>[];
    if (featureListOffset != 0) {
      final list = base + featureListOffset;
      final count = r.uint16At(list);
      for (var i = 0; i < count; i++) {
        final rec = list + 2 + i * 6;
        featureTags.add(r.uint32At(rec));
        featureOffsets.add(list + r.uint16At(rec + 4));
      }
    }

    final lookupOffsets = <int>[];
    if (lookupListOffset != 0) {
      final list = base + lookupListOffset;
      final count = r.uint16At(list);
      for (var i = 0; i < count; i++) {
        lookupOffsets.add(list + r.uint16At(list + 2 + i * 2));
      }
    }

    return LayoutTable._(
      reader: r,
      base: base,
      scripts: scripts,
      featureTags: featureTags,
      featureOffsets: featureOffsets,
      lookupOffsets: lookupOffsets,
      featureVariationsOffset: featureVariations,
      minorVersion: minor,
    );
  }

  final ByteReader _reader;
  final int _base;
  final Map<int, int> _scripts;
  final List<int> _featureTags;
  final List<int> _featureOffsets;
  final List<List<int>?> _featureLookups;

  final int minorVersion;

  /// Absolute offsets of every Lookup table, indexed by lookup index.
  final List<int> lookupOffsets;

  /// Absolute offset of the FeatureVariations table (version 1.1), or null.
  final int? featureVariationsOffset;

  /// A fresh reader positioned at the start of this table.
  ///
  /// Fresh, not shared: a [ByteReader] carries a mutable cursor, and handing
  /// the same one to two subtable parsers would have them fight over it.
  ByteReader get base => _reader.at(_base);

  int get featureCount => _featureTags.length;

  Iterable<int> get scriptTags => _scripts.keys;

  bool hasScript(int script) => _scripts.containsKey(script);

  /// Feature tag at [featureIndex], as a packed [Tag].
  int featureTag(int featureIndex) {
    if (featureIndex < 0 || featureIndex >= _featureTags.length) {
      throw FontFormatException('feature index $featureIndex out of range');
    }
    return _featureTags[featureIndex];
  }

  /// Lookup indices belonging to [featureIndex], in the feature's own order.
  List<int> featureLookups(int featureIndex) {
    if (featureIndex < 0 || featureIndex >= _featureOffsets.length) {
      throw FontFormatException('feature index $featureIndex out of range');
    }
    final cached = _featureLookups[featureIndex];
    if (cached != null) return cached;

    final offset = _featureOffsets[featureIndex];
    // +0 is featureParamsOffset, which only `size`/`ssXX` use and no shaper
    // reads; the lookup list starts at +2.
    final count = _reader.uint16At(offset + 2);
    final out = List<int>.generate(
      count,
      (i) => _reader.uint16At(offset + 4 + i * 2),
      growable: false,
    );
    _featureLookups[featureIndex] = out;
    return out;
  }

  /// Feature tags available for [script] + [language], after the same DFLT and
  /// default-LangSys fallbacks [lookupsFor] applies.
  Set<int> availableFeatures({required int script, required int language}) {
    final langSys = _langSysOffset(script, language);
    if (langSys == null) return const <int>{};
    final out = <int>{};
    for (final i in _featureIndices(langSys)) {
      out.add(_featureTags[i]);
    }
    return out;
  }

  /// Lookup indices to run for [script] + [language], restricted to the feature
  /// tags in [features], deduplicated, in **ascending lookup order**.
  ///
  /// Lookup order, not FeatureList order. The LookupList table is normative on
  /// this: the font developer defines the lookup *sequence* there to control the
  /// order a client applies them, and HarfBuzz sorts its stage map by lookup
  /// index for the same reason. Returning FeatureList order looks reasonable and
  /// is wrong — on Vazirmatn it yields `[28, 26, 22, 24, 32, 33, 23, 25, 35, 36]`
  /// where the font asked for `[22, 23, 24, 25, 26, 28, 32, 33, 35, 36]`, and for
  /// a Urdu-tagged run it puts `locl` *after* `rlig` and `calt`, so localisation
  /// lands on glyphs that have already been ligated.
  ///
  /// An unknown [script] falls back to `DFLT`; an unknown [language] falls back
  /// to the script's default LangSys. Both fallbacks are what a font means by
  /// shipping a DFLT script with the real rules in it, which most Arabic
  /// families do for at least some features.
  List<int> lookupsFor({
    required int script,
    required int language,
    required Set<int> features,
  }) => [
    for (final l in stagedLookups(
      script: script,
      language: language,
      features: features,
    ))
      l.lookupIndex,
  ];

  /// The same resolution as [lookupsFor], but keeping **which feature each
  /// lookup came from**.
  ///
  /// The shaper cannot work without this. Its whole design rests on running one
  /// GSUB pass in which `isol`/`init`/`medi`/`fina` are mutually exclusive
  /// per glyph, selected by a bit in [GlyphInfo.mask] — and to build those masks
  /// it must know that lookup 22 is `fina` and lookup 24 is `init`. A bare
  /// `List<int>` throws that away and cannot be inverted: two features routinely
  /// share a lookup.
  ///
  /// A lookup reachable from several enabled features appears ONCE, carrying the
  /// union of their tags. Running it twice would apply a substitution to its own
  /// output.
  List<StagedLookup> stagedLookups({
    required int script,
    required int language,
    required Set<int> features,
  }) {
    final langSys = _langSysOffset(script, language);
    if (langSys == null) return const <StagedLookup>[];

    final byLookup = <int, Set<int>>{};
    for (final featureIndex in _featureIndices(langSys)) {
      final tag = _featureTags[featureIndex];
      if (!features.contains(tag)) continue;
      for (final lookup in featureLookups(featureIndex)) {
        (byLookup[lookup] ??= <int>{}).add(tag);
      }
    }

    final indices = byLookup.keys.toList()..sort();
    return [
      for (final i in indices)
        StagedLookup(lookupIndex: i, featureTags: byLookup[i]!),
    ];
  }

  /// Absolute offset of the LangSys table for [script] + [language], or null.
  int? _langSysOffset(int script, int language) {
    final scriptOffset = _scripts[script] ?? _scripts[Tag.dflt];
    if (scriptOffset == null) return null;

    if (language != 0 && language != Tag.dflt) {
      final count = _reader.uint16At(scriptOffset + 2);
      // Linear: a script carries a handful of LangSysRecords, and a binary
      // search over that is slower than the scan plus its own branch.
      for (var i = 0; i < count; i++) {
        final rec = scriptOffset + 4 + i * 6;
        if (_reader.uint32At(rec) == language) {
          return scriptOffset + _reader.uint16At(rec + 4);
        }
      }
    }

    final defaultOffset = _reader.uint16At(scriptOffset);
    return defaultOffset == 0 ? null : scriptOffset + defaultOffset;
  }

  /// Feature indices a LangSys names, ascending, with out-of-range entries
  /// dropped.
  ///
  /// The required feature is included when the LangSys declares one, but it is
  /// still filtered by the caller's tag set in [lookupsFor]. The spec calls it
  /// unconditional; applying it unconditionally here would inject, say, `ccmp`
  /// lookups into every stage a shaper asks about, and re-run them once per
  /// stage. The stage schedule belongs to the shaper, so the tag filter stays.
  List<int> _featureIndices(int langSysOffset) {
    final out = <int>{};
    final required = _reader.uint16At(langSysOffset + 2);
    if (required != 0xFFFF && required < _featureTags.length) {
      out.add(required);
    }
    final count = _reader.uint16At(langSysOffset + 4);
    for (var i = 0; i < count; i++) {
      final index = _reader.uint16At(langSysOffset + 6 + i * 2);
      // A font that names a feature index past the FeatureList is corrupt, but
      // it is corrupt in a way that costs nothing to survive.
      if (index < _featureTags.length) out.add(index);
    }
    return out.toList()..sort();
  }

  @override
  String toString() =>
      'LayoutTable(1.$minorVersion, ${_scripts.length} scripts, '
      '${_featureTags.length} features, ${lookupOffsets.length} lookups)';
}

/// One lookup, plus the feature tags that selected it.
///
/// Exists so the shaper can build per-glyph feature masks. See
/// [LayoutTable.stagedLookups].
class StagedLookup {
  const StagedLookup({required this.lookupIndex, required this.featureTags});

  final int lookupIndex;

  /// Every enabled feature that reaches this lookup. Usually one; `rlig` and
  /// `calt` sharing a lookup is common enough that the plural matters.
  final Set<int> featureTags;

  bool hasFeature(int tag) => featureTags.contains(tag);

  @override
  String toString() =>
      'StagedLookup($lookupIndex, '
      '${featureTags.map((t) => Tag(t).asString).join("+")})';
}
