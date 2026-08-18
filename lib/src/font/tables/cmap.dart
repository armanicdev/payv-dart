/// `cmap` — character-to-glyph mapping.
///
/// The floor of the whole engine: `cmap` is where a codepoint becomes a glyph
/// id, and it is also the ceiling of every PDF library that shapes Arabic by
/// remapping to presentation forms. Sorani's ڕ ڵ ە ێ resolve here to their
/// *isolated* glyphs and no further — the joined shapes are GSUB-only and have
/// no codepoint at all. So this table's job is narrow and it must do it
/// exactly: wrong here and the shaper is fed the wrong glyphs to substitute.
///
/// A font carries several subtables for several platforms, mapping the same
/// text differently. Picking the wrong one is not a crash, it is a document
/// full of the wrong letters, so the choice is made by an explicit ranked
/// preference and the winner is recorded on [platformId]/[encodingId]/[format].
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// The parsed `cmap` table: one chosen subtable, plus any format 14 variation
/// selector subtable that sits alongside it.
class CmapTable {
  CmapTable._(
    this._subtable,
    this._variations,
    this.encodingRecords,
    this.chosenEncoding,
  );

  /// Parses the table [r] is positioned at, choosing the best subtable.
  static CmapTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 4)) {
      throw const FontFormatException('cmap is too short to hold a header');
    }
    final numTables = r.uint16At(base + 2);
    if (!r.canRead(base + 4, numTables * 8)) {
      throw FontFormatException(
        'cmap claims $numTables encoding records it does not contain',
      );
    }

    final records = <CmapEncodingRecord>[];
    for (var i = 0; i < numTables; i++) {
      final at = base + 4 + i * 8;
      final offset = r.uint32At(at + 4);
      final start = base + offset;
      // A subtable offset past the file is corruption; a *record* that is
      // merely unreadable is skipped rather than fatal, because a font with
      // one bad legacy record and one good Unicode record still renders.
      if (!r.canRead(start, 2)) continue;
      records.add(
        CmapEncodingRecord(
          platformId: r.uint16At(at),
          encodingId: r.uint16At(at + 2),
          offset: start,
          format: r.uint16At(start),
        ),
      );
    }
    if (records.isEmpty) {
      throw const FontFormatException('cmap has no usable encoding record');
    }

    // Fonts commonly point several records at ONE subtable (Vazirmatn's (0,3)
    // and (3,1) share a single format 4 body). Ranking still has to run so the
    // recorded platform/encoding matches what a consumer would expect.
    final ranked = List<CmapEncodingRecord>.of(records)
      ..sort((a, b) => a._rank.compareTo(b._rank));

    _CmapSubtable? chosen;
    CmapEncodingRecord? chosenRecord;
    for (final rec in ranked) {
      final sub = _parseSubtable(r, rec.offset);
      // An unsupported or malformed subtable is not fatal while a lower-ranked
      // one may still work — a broken format 2 record must not cost the font
      // its perfectly good format 4.
      if (sub == null) continue;
      chosen = sub;
      chosenRecord = rec;
      break;
    }
    if (chosen == null || chosenRecord == null) {
      throw const FontFormatException(
        'cmap has no subtable in a format this parser supports',
      );
    }

    // Format 14 is never "the" subtable — it is an overlay on whichever one
    // won, so it is looked up independently of the ranking.
    _Format14? variations;
    for (final rec in records) {
      if (rec.format == 14) {
        variations = _Format14.parse(r, rec.offset);
        break;
      }
    }

    return CmapTable._(
      chosen,
      variations,
      List.unmodifiable(records),
      chosenRecord,
    );
  }

  final _CmapSubtable _subtable;
  final _Format14? _variations;

  /// Every encoding record the font declared, in file order. Diagnostic — the
  /// engine only ever reads through the chosen one.
  final List<CmapEncodingRecord> encodingRecords;

  /// Which subtable won the ranking.
  final CmapEncodingRecord chosenEncoding;

  int get platformId => chosenEncoding.platformId;

  int get encodingId => chosenEncoding.encodingId;

  int get format => chosenEncoding.format;

  /// True only when the chosen subtable is a (3,0) Microsoft *Symbol* mapping.
  ///
  /// Symbol fonts do not map Unicode: they map the private-use block
  /// 0xF000…0xF0FF, and a caller passing 'A' expects to reach 0xF041. That
  /// fallback lives inside [lookup] so no caller has to remember it, but the
  /// flag is exposed because a symbolic font also changes how the PDF font
  /// descriptor must be written.
  bool get isSymbolic =>
      chosenEncoding.platformId == 3 && chosenEncoding.encodingId == 0;

  /// Glyph id for [codepoint], or 0 (`.notdef`) when unmapped.
  int lookup(int codepoint) {
    if (codepoint < 0) return 0;
    final gid = _subtable.lookup(codepoint);
    if (gid != 0 || !isSymbolic) return gid;
    // Symbol subtables live entirely in 0xF000…0xF0FF. Try the aliased
    // codepoint before giving up; this is what every rasteriser does and what
    // makes a Wingdings-style font usable from ASCII input.
    if (codepoint <= 0xFF) return _subtable.lookup(0xF000 + codepoint);
    return 0;
  }

  /// Glyph id for the (base, variation-selector) pair, or 0 when the font
  /// declares no mapping for it.
  ///
  /// A pair listed in a *default* UVS set means "this selector changes
  /// nothing", so the ordinary [lookup] answer is returned — that is the glyph
  /// the font is asking for. Only a pair the font never mentions gives 0.
  int lookupVariation(int cp, int vs) {
    final v = _variations;
    if (v == null) return 0;
    final nonDefault = v.lookupNonDefault(cp, vs);
    if (nonDefault != 0) return nonDefault;
    return v.isDefault(cp, vs) ? lookup(cp) : 0;
  }

  /// True when the font ships a format 14 subtable at all.
  bool get hasVariationSelectors => _variations != null;

  /// Every mapping in the chosen subtable, codepoint → glyph id.
  ///
  /// Built on demand and cached: the subsetter needs it once to decide which
  /// glyphs survive, and the PDF writer needs it once more, reversed, to emit
  /// `ToUnicode`. Shaping never touches it — that path goes through [lookup],
  /// which is a binary search rather than a million-entry map.
  ///
  /// Reports what the table literally says. The symbolic 0xF000 alias applied
  /// by [lookup] is deliberately NOT folded in, so a caller writing
  /// `ToUnicode` sees the font's real codepoints.
  Map<int, int> get allMappings => _allMappings ??= _buildMappings();
  Map<int, int>? _allMappings;

  Map<int, int> _buildMappings() {
    final out = <int, int>{};
    _subtable.forEach((cp, gid) {
      // .notdef is the absence of a mapping, not a mapping to glyph 0. Keeping
      // it would make the subsetter retain a glyph for every unmapped
      // codepoint in a format 4 segment.
      if (gid != 0) out[cp] = gid;
    });
    return Map.unmodifiable(out);
  }

  @override
  String toString() =>
      'CmapTable(platform $platformId, encoding $encodingId, '
      'format $format${isSymbolic ? ", symbolic" : ""})';

  /// Returns null for a format this parser does not implement, or for one whose
  /// header does not fit — the caller falls through to the next candidate.
  static _CmapSubtable? _parseSubtable(ByteReader r, int offset) {
    if (!r.canRead(offset, 2)) return null;
    switch (r.uint16At(offset)) {
      case 0:
        return _Format0.parse(r, offset);
      case 4:
        return _Format4.parse(r, offset);
      case 6:
        return _Format6.parse(r, offset);
      case 12:
        return _Format12or13.parse(r, offset, manyToOne: false);
      case 13:
        return _Format12or13.parse(r, offset, manyToOne: true);
      default:
        // Formats 2 (high-byte CJK), 8 and 10 are deliberately unimplemented —
        // see the class doc on why they are dead ends in practice.
        return null;
    }
  }
}

/// One `cmap` encoding record: a platform/encoding pair and where its subtable
/// starts.
class CmapEncodingRecord {
  const CmapEncodingRecord({
    required this.platformId,
    required this.encodingId,
    required this.offset,
    required this.format,
  });

  final int platformId;
  final int encodingId;

  /// Absolute offset of the subtable in the font buffer.
  final int offset;

  final int format;

  /// Ranked preference, lowest wins.
  ///
  /// The order is Unicode-first and full-range-first: a (3,10) format 12
  /// subtable covers the astral planes, a (3,1) format 4 stops at U+FFFF, and a
  /// (1,0) Mac Roman subtable covers 256 codepoints of a 1984 codepage. Taking
  /// the last one when a font ships all three would render a Kurdish document
  /// as mojibake, so the ordering is explicit rather than "first record wins".
  int get _rank {
    final pair = switch ((platformId, encodingId)) {
      (3, 10) => 0, // Windows UCS-4
      (0, 6) => 1, // Unicode full repertoire
      (0, 4) => 1,
      (3, 1) => 2, // Windows BMP — the overwhelmingly common case
      (0, 3) => 3, // Unicode 2.0+ BMP
      (0, 2) => 4,
      (0, 1) => 4,
      (0, 0) => 4,
      (3, 0) => 5, // Microsoft Symbol
      (1, 0) => 6, // Mac Roman
      _ => 9,
    };
    // Within one platform/encoding pair, prefer the subtable format with the
    // widest reach; some fonts declare (3,10) with a format 4 body.
    final byFormat = switch (format) {
      12 => 0,
      13 => 1,
      4 => 2,
      6 => 3,
      0 => 4,
      _ => 8,
    };
    return pair * 10 + byFormat;
  }

  @override
  String toString() => 'cmap($platformId,$encodingId) format $format';
}

/// Common shape of every supported subtable.
abstract class _CmapSubtable {
  int lookup(int codepoint);

  /// Visits every (codepoint, glyph) pair the subtable declares.
  void forEach(void Function(int codepoint, int glyphId) visit);
}

/// Format 0 — byte encoding. 256 codepoints, one uint8 glyph id each.
class _Format0 implements _CmapSubtable {
  _Format0(this._glyphs);

  static _Format0? parse(ByteReader r, int offset) {
    if (!r.canRead(offset, 262)) return null;
    return _Format0(r.bytesAt(offset + 6, 256));
  }

  final Uint8List _glyphs;

  @override
  int lookup(int codepoint) =>
      codepoint >= 0 && codepoint < 256 ? _glyphs[codepoint] : 0;

  @override
  void forEach(void Function(int, int) visit) {
    for (var cp = 0; cp < 256; cp++) {
      visit(cp, _glyphs[cp]);
    }
  }
}

/// Format 4 — segment mapping to delta values. The BMP workhorse.
class _Format4 implements _CmapSubtable {
  _Format4({
    required this.endCode,
    required this.startCode,
    required this.idDelta,
    required this.idRangeOffset,
    required this.idRangeOffsetBase,
    required this.reader,
    required this.limit,
  });

  static _Format4? parse(ByteReader r, int offset) {
    if (!r.canRead(offset, 14)) return null;
    final length = r.uint16At(offset + 2);
    final segCountX2 = r.uint16At(offset + 6);
    if (segCountX2 == 0 || segCountX2.isOdd) return null;
    final segCount = segCountX2 >> 1;

    final endBase = offset + 14;
    final startBase = endBase + segCountX2 + 2; // +2 for reservedPad
    final deltaBase = startBase + segCountX2;
    final rangeBase = deltaBase + segCountX2;
    if (!r.canRead(rangeBase, segCountX2)) return null;

    final end = r.at(endBase).readUint16List(segCount);
    final start = r.at(startBase).readUint16List(segCount);
    final delta = r.at(deltaBase).readUint16List(segCount);
    final range = r.at(rangeBase).readUint16List(segCount);

    // glyphIdArray follows idRangeOffset and runs to the end of the subtable.
    // Reads into it are bounded by the subtable's own declared length, not by
    // the file, so a truncated font cannot hand back a neighbouring table's
    // bytes as glyph ids.
    //
    // `length` is a uint16, so a format 4 subtable larger than 64 KB cannot
    // state its real size and some fonts write 0 or a wrapped value. When the
    // declared end lands before the arrays we already read, it is nonsense —
    // fall back to the file bound, which is still a bound.
    var declaredEnd = offset + length;
    if (declaredEnd < rangeBase + segCountX2) declaredEnd = r.length;
    return _Format4(
      endCode: end,
      startCode: start,
      idDelta: delta,
      idRangeOffset: range,
      idRangeOffsetBase: rangeBase,
      reader: r,
      limit: declaredEnd > r.length ? r.length : declaredEnd,
    );
  }

  final Uint16List endCode;
  final Uint16List startCode;
  final Uint16List idDelta;
  final Uint16List idRangeOffset;

  /// Absolute offset of `idRangeOffset[0]`. Load-bearing — see [lookup].
  final int idRangeOffsetBase;

  final ByteReader reader;

  /// One past the last byte of this subtable.
  final int limit;

  @override
  int lookup(int codepoint) {
    if (codepoint < 0 || codepoint > 0xFFFF) return 0;

    // Segments are sorted by endCode, so find the first that could contain it.
    var lo = 0;
    var hi = endCode.length - 1;
    var seg = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (endCode[mid] < codepoint) {
        lo = mid + 1;
      } else {
        seg = mid;
        hi = mid - 1;
      }
    }
    if (seg < 0 || codepoint < startCode[seg]) return 0;

    final delta = idDelta[seg];
    final range = idRangeOffset[seg];
    if (range == 0) return (codepoint + delta) & 0xFFFF;

    // The classic format 4 bug lives in these three lines.
    //
    // idRangeOffset[seg] is a byte offset relative to ITS OWN slot inside the
    // idRangeOffset array — not to the subtable, not to the glyphIdArray. The
    // spec writes it that way so that glyphIdArray can immediately follow the
    // array with no separate offset, which means the base is
    // `idRangeOffsetBase + seg * 2` and nothing else. Using the subtable start
    // here is the single most common cmap defect, and it fails *quietly*: it
    // returns real glyph ids from the wrong segment.
    final at =
        idRangeOffsetBase + seg * 2 + range + (codepoint - startCode[seg]) * 2;
    if (at < 0 || at + 2 > limit) return 0;
    final gid = reader.uint16At(at);

    // And the second half of the same bug: a zero read out of glyphIdArray
    // means "unmapped" and must stay 0. Adding idDelta to it would invent a
    // glyph — usually a plausible-looking one, since idDelta is small.
    return gid == 0 ? 0 : (gid + delta) & 0xFFFF;
  }

  @override
  void forEach(void Function(int, int) visit) {
    for (var seg = 0; seg < endCode.length; seg++) {
      final first = startCode[seg];
      final last = endCode[seg];
      if (first > last) continue;
      for (var cp = first; cp <= last; cp++) {
        visit(cp, lookup(cp));
        // The final segment is the mandatory 0xFFFF…0xFFFF terminator; without
        // this break the counter wraps past 0xFFFF and loops forever.
        if (cp == 0xFFFF) break;
      }
    }
  }
}

/// Format 6 — trimmed table mapping: one contiguous run of codepoints.
class _Format6 implements _CmapSubtable {
  _Format6(this._firstCode, this._glyphs);

  static _Format6? parse(ByteReader r, int offset) {
    if (!r.canRead(offset, 10)) return null;
    final firstCode = r.uint16At(offset + 6);
    final entryCount = r.uint16At(offset + 8);
    if (!r.canRead(offset + 10, entryCount * 2)) return null;
    return _Format6(firstCode, r.at(offset + 10).readUint16List(entryCount));
  }

  final int _firstCode;
  final Uint16List _glyphs;

  @override
  int lookup(int codepoint) {
    final i = codepoint - _firstCode;
    return i >= 0 && i < _glyphs.length ? _glyphs[i] : 0;
  }

  @override
  void forEach(void Function(int, int) visit) {
    for (var i = 0; i < _glyphs.length; i++) {
      visit(_firstCode + i, _glyphs[i]);
    }
  }
}

/// Formats 12 and 13 — grouped ranges. Identical layout, opposite meaning.
///
/// In format 12 `startGlyphId` is the glyph of the *first* codepoint and the
/// rest of the group counts up from it. In format 13 every codepoint in the
/// group maps to that one glyph — the shape "last resort" fonts use to map all
/// of Unicode onto a single box. One boolean apart, and reading a format 13 as
/// a 12 walks glyph ids off the end of the font.
class _Format12or13 implements _CmapSubtable {
  _Format12or13(this._starts, this._ends, this._glyphs, this._manyToOne);

  static _Format12or13? parse(
    ByteReader r,
    int offset, {
    required bool manyToOne,
  }) {
    if (!r.canRead(offset, 16)) return null;
    final numGroups = r.uint32At(offset + 12);
    // 12 bytes per group; refuse a count that cannot physically fit rather
    // than allocating three lists of it first.
    if (numGroups > (r.length - offset - 16) ~/ 12) return null;

    final starts = Uint32List(numGroups);
    final ends = Uint32List(numGroups);
    final glyphs = Uint32List(numGroups);
    for (var i = 0; i < numGroups; i++) {
      final at = offset + 16 + i * 12;
      starts[i] = r.uint32At(at);
      ends[i] = r.uint32At(at + 4);
      glyphs[i] = r.uint32At(at + 8);
    }
    return _Format12or13(starts, ends, glyphs, manyToOne);
  }

  final Uint32List _starts;
  final Uint32List _ends;
  final Uint32List _glyphs;
  final bool _manyToOne;

  @override
  int lookup(int codepoint) {
    var lo = 0;
    var hi = _starts.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (codepoint < _starts[mid]) {
        hi = mid - 1;
      } else if (codepoint > _ends[mid]) {
        lo = mid + 1;
      } else {
        return _manyToOne
            ? _glyphs[mid]
            : _glyphs[mid] + (codepoint - _starts[mid]);
      }
    }
    return 0;
  }

  @override
  void forEach(void Function(int, int) visit) {
    for (var i = 0; i < _starts.length; i++) {
      final first = _starts[i];
      // A format 13 group legally spans the whole of Unicode. Clamping to the
      // last real codepoint keeps a "last resort" font from enumerating four
      // billion entries into a Map.
      final last = _ends[i] > _maxCodepoint ? _maxCodepoint : _ends[i];
      for (var cp = first; cp <= last; cp++) {
        visit(cp, _manyToOne ? _glyphs[i] : _glyphs[i] + (cp - first));
      }
    }
  }

  static const int _maxCodepoint = 0x10FFFF;
}

/// Format 14 — Unicode Variation Sequences.
///
/// Not a mapping in its own right: it modifies whichever subtable won, telling
/// the shaper what `<base, U+FE00…U+FE0F>` should produce. Two disjoint sets
/// per selector — "default" meaning the base glyph already is the right one,
/// and "non-default" carrying an explicit glyph id.
class _Format14 {
  _Format14(this._selectors, this._defaults, this._nonDefaults);

  static _Format14? parse(ByteReader r, int offset) {
    if (!r.canRead(offset, 10)) return null;
    final count = r.uint32At(offset + 6);
    if (!r.canRead(offset + 10, count * 11)) return null;

    final selectors = Uint32List(count);
    final defaults = <List<int>>[];
    final nonDefaults = <Map<int, int>>[];

    for (var i = 0; i < count; i++) {
      final at = offset + 10 + i * 11;
      selectors[i] = r.uint24At(at);
      final defaultOffset = r.uint32At(at + 3);
      final nonDefaultOffset = r.uint32At(at + 7);

      // Default UVS: ranges of base codepoints the selector leaves alone.
      // Stored flat as [start, end, start, end, …] and binary-searched, because
      // CJK fonts ship tens of thousands of these.
      final ranges = <int>[];
      if (defaultOffset != 0) {
        final d = offset + defaultOffset;
        if (r.canRead(d, 4)) {
          final numRanges = r.uint32At(d);
          if (r.canRead(d + 4, numRanges * 4)) {
            for (var j = 0; j < numRanges; j++) {
              final at2 = d + 4 + j * 4;
              final start = r.uint24At(at2);
              ranges.add(start);
              ranges.add(start + r.uint8At(at2 + 3));
            }
          }
        }
      }
      defaults.add(ranges);

      final map = <int, int>{};
      if (nonDefaultOffset != 0) {
        final n = offset + nonDefaultOffset;
        if (r.canRead(n, 4)) {
          final numMappings = r.uint32At(n);
          if (r.canRead(n + 4, numMappings * 5)) {
            for (var j = 0; j < numMappings; j++) {
              final at2 = n + 4 + j * 5;
              map[r.uint24At(at2)] = r.uint16At(at2 + 3);
            }
          }
        }
      }
      nonDefaults.add(map);
    }

    return _Format14(selectors, defaults, nonDefaults);
  }

  final Uint32List _selectors;
  final List<List<int>> _defaults;
  final List<Map<int, int>> _nonDefaults;

  int lookupNonDefault(int cp, int vs) {
    final i = _selectorIndex(vs);
    return i < 0 ? 0 : (_nonDefaults[i][cp] ?? 0);
  }

  bool isDefault(int cp, int vs) {
    final i = _selectorIndex(vs);
    if (i < 0) return false;
    final ranges = _defaults[i];
    var lo = 0;
    var hi = (ranges.length >> 1) - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cp < ranges[mid * 2]) {
        hi = mid - 1;
      } else if (cp > ranges[mid * 2 + 1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  int _selectorIndex(int vs) {
    var lo = 0;
    var hi = _selectors.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_selectors[mid] < vs) {
        lo = mid + 1;
      } else if (_selectors[mid] > vs) {
        hi = mid - 1;
      } else {
        return mid;
      }
    }
    return -1;
  }
}
