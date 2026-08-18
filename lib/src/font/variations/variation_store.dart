/// The `ItemVariationStore` — the one delta mechanism OpenType reuses
/// everywhere.
///
/// `HVAR` advances, `GDEF` mark anchors, `MVAR` metrics and `avar` 2.0 axis
/// mapping all encode "how does this number move as the axes move" with exactly
/// this structure, so it lives on its own rather than inside any one of them.
/// The store answers a delta for an (outer, inner) index pair at a point in
/// normalised variation space; who owns the index pair is the caller's problem.
library;

import '../../util/byte_reader.dart';

/// One region of variation space: per axis, a triangular tent function.
class _Region {
  const _Region(this.start, this.peak, this.end);

  final List<double> start;
  final List<double> peak;
  final List<double> end;

  /// The region's contribution at [coords], in 0.0 … 1.0.
  ///
  /// This mirrors HarfBuzz's `VarRegionAxis::evaluate` branch for branch,
  /// including the order of the early exits. Parity is not stylistic here: a
  /// delta that differs in the last bit moves a glyph, and HarfBuzz is the
  /// reference our tests grade against.
  double scalar(List<double> coords) {
    var result = 1.0;
    for (var i = 0; i < peak.length; i++) {
      final p = peak[i];
      // A zero peak means the region does not constrain this axis at all —
      // not that the axis must be at zero.
      if (p == 0) continue;
      final coord = i < coords.length ? coords[i] : 0.0;
      if (coord == p) continue;
      final s = start[i];
      final e = end[i];
      // A region that is not a well-formed tent is IGNORED for this axis, not
      // treated as zero. Dropping this branch turns one malformed axis record
      // into a font where every variable glyph collapses to its default.
      if (s > p || p > e || (s < 0 && e > 0 && p != 0)) continue;
      if (coord <= s || e <= coord) return 0.0;
      result *= coord < p ? (coord - s) / (p - s) : (e - coord) / (e - p);
    }
    return result;
  }
}

/// One `ItemVariationData` subtable: a matrix of delta values, rows indexed by
/// the inner index and columns by [regionIndexes].
///
/// The rows are NOT read at parse time. `HVAR` on a 1300-glyph font is a couple
/// of thousand rows across eight subtables, of which shaping a line touches a
/// handful; materialising them all would cost more than the whole rest of the
/// parse.
class _ItemData {
  const _ItemData({
    required this.itemCount,
    required this.regionIndexes,
    required this.wordCount,
    required this.longWords,
    required this.rowOffset,
    required this.rowSize,
  });

  final int itemCount;
  final List<int> regionIndexes;

  /// How many leading columns use the wide encoding.
  final int wordCount;

  /// `LONG_WORDS`: widens both encodings — 32-bit leading columns, 16-bit tail.
  final bool longWords;

  /// Absolute file offset of row 0.
  final int rowOffset;
  final int rowSize;
}

/// Maps a glyph (or any item id) onto an (outer, inner) pair.
///
/// Present in `HVAR`/`VVAR` when several glyphs share a delta row, which is the
/// usual case — a text face has far fewer distinct advance-delta patterns than
/// glyphs.
class DeltaSetIndexMap {
  const DeltaSetIndexMap._(
    this._reader,
    this._dataOffset,
    this._mapCount,
    this._entrySize,
    this._innerBits,
  );

  static DeltaSetIndexMap parse(ByteReader r) {
    final base = r.position;
    final format = r.uint8At(base);
    if (format != 0 && format != 1) {
      throw FontFormatException('DeltaSetIndexMap format $format');
    }
    final entryFormat = r.uint8At(base + 1);
    final int mapCount;
    final int dataOffset;
    if (format == 0) {
      mapCount = r.uint16At(base + 2);
      dataOffset = base + 4;
    } else {
      mapCount = r.uint32At(base + 2);
      dataOffset = base + 6;
    }
    final entrySize = ((entryFormat & 0x30) >> 4) + 1;
    final innerBits = (entryFormat & 0x0F) + 1;
    if (!r.canRead(dataOffset, mapCount * entrySize)) {
      throw const FontFormatException(
        'DeltaSetIndexMap entries overrun the font',
      );
    }
    return DeltaSetIndexMap._(r, dataOffset, mapCount, entrySize, innerBits);
  }

  final ByteReader _reader;
  final int _dataOffset;
  final int _mapCount;
  final int _entrySize;
  final int _innerBits;

  int get length => _mapCount;

  /// Looks [index] up, returning `(outerIndex, innerIndex)`.
  ///
  /// Indices past the end resolve to the LAST entry rather than to zero — the
  /// spec's own rule, and the reason a font can end its map early when every
  /// remaining glyph shares one delta row.
  (int, int) operator [](int index) {
    if (_mapCount == 0) return (0, index);
    final i = index >= _mapCount ? _mapCount - 1 : (index < 0 ? 0 : index);
    final at = _dataOffset + i * _entrySize;
    var entry = 0;
    for (var b = 0; b < _entrySize; b++) {
      entry = (entry << 8) | _reader.uint8At(at + b);
    }
    return (entry >> _innerBits, entry & ((1 << _innerBits) - 1));
  }
}

/// A parsed `ItemVariationStore`.
class ItemVariationStore {
  ItemVariationStore._(this._reader, this._regions, this._data, this._map);

  /// Parses a store from a reader positioned at the store itself — not at the
  /// enclosing `HVAR`/`MVAR` header.
  static ItemVariationStore parse(ByteReader r) {
    final base = r.position;
    final format = r.uint16At(base);
    if (format != 1) {
      throw FontFormatException('ItemVariationStore format $format');
    }
    final regionListOffset = r.uint32At(base + 2);
    final dataCount = r.uint16At(base + 6);

    final regions = _parseRegions(r, base + regionListOffset);
    final data = <_ItemData>[];
    for (var i = 0; i < dataCount; i++) {
      data.add(_parseItemData(r, base + r.uint32At(base + 8 + i * 4), regions));
    }
    return ItemVariationStore._(r, regions, data, null);
  }

  /// Parses an `HVAR` table: the store plus its advance-width index map.
  ///
  /// The frozen [OpenTypeFont] facade builds `hvar` by calling [parse] on the
  /// store offset alone, which throws the `advanceWidthMapping` away and leaves
  /// [deltaForGlyph] on its implicit-mapping fallback. That is correct only for
  /// fonts that omit the map — Vazirmatn ships one — so this entry point exists
  /// for callers that can reach the whole `HVAR` table.
  static ItemVariationStore parseHvar(ByteReader hvar) {
    final base = hvar.position;
    final major = hvar.uint16At(base);
    if (major != 1) throw FontFormatException('HVAR version $major');
    final store = parse(hvar.at(base + hvar.uint32At(base + 4)));
    final mapOffset = hvar.uint32At(base + 8);
    if (mapOffset == 0) return store;
    return ItemVariationStore._(
      store._reader,
      store._regions,
      store._data,
      DeltaSetIndexMap.parse(hvar.at(base + mapOffset)),
    );
  }

  static List<_Region> _parseRegions(ByteReader r, int at) {
    final axisCount = r.uint16At(at);
    final regionCount = r.uint16At(at + 2);
    final stride = axisCount * 6;
    if (!r.canRead(at + 4, regionCount * stride)) {
      throw const FontFormatException(
        'variation region list overruns the font',
      );
    }
    final out = <_Region>[];
    for (var i = 0; i < regionCount; i++) {
      final start = List<double>.filled(axisCount, 0);
      final peak = List<double>.filled(axisCount, 0);
      final end = List<double>.filled(axisCount, 0);
      var p = at + 4 + i * stride;
      for (var a = 0; a < axisCount; a++, p += 6) {
        start[a] = r.f2dot14At(p);
        peak[a] = r.f2dot14At(p + 2);
        end[a] = r.f2dot14At(p + 4);
      }
      out.add(_Region(start, peak, end));
    }
    return out;
  }

  static _ItemData _parseItemData(ByteReader r, int at, List<_Region> regions) {
    final itemCount = r.uint16At(at);
    final wordDeltaCount = r.uint16At(at + 2);
    final regionIndexCount = r.uint16At(at + 4);
    final longWords = wordDeltaCount & 0x8000 != 0;
    final wordCount = wordDeltaCount & 0x7FFF;
    if (wordCount > regionIndexCount) {
      throw FontFormatException(
        'ItemVariationData claims $wordCount wide columns of only '
        '$regionIndexCount',
      );
    }
    final regionIndexes = List<int>.generate(regionIndexCount, (i) {
      final idx = r.uint16At(at + 6 + i * 2);
      if (idx >= regions.length) {
        throw FontFormatException('region index $idx out of range');
      }
      return idx;
    }, growable: false);
    final rowSize = longWords
        ? wordCount * 4 + (regionIndexCount - wordCount) * 2
        : wordCount * 2 + (regionIndexCount - wordCount);
    final rowOffset = at + 6 + regionIndexCount * 2;
    if (!r.canRead(rowOffset, itemCount * rowSize)) {
      throw const FontFormatException('delta set rows overrun the font');
    }
    return _ItemData(
      itemCount: itemCount,
      regionIndexes: regionIndexes,
      wordCount: wordCount,
      longWords: longWords,
      rowOffset: rowOffset,
      rowSize: rowSize,
    );
  }

  final ByteReader _reader;
  final List<_Region> _regions;
  final List<_ItemData> _data;
  final DeltaSetIndexMap? _map;

  /// The index map, when this store was built from a whole `HVAR` table.
  DeltaSetIndexMap? get deltaSetIndexMap => _map;

  int get subtableCount => _data.length;

  int get regionCount => _regions.length;

  /// The delta for one delta-set index pair at [coords] (normalised, F2Dot14
  /// range). Out-of-range indices yield 0 rather than throwing: a stale index
  /// means "no variation for this item", and a font is allowed to under-fill
  /// its maps.
  double delta(int outerIndex, int innerIndex, List<double> coords) {
    if (outerIndex < 0 || outerIndex >= _data.length) return 0.0;
    final d = _data[outerIndex];
    if (innerIndex < 0 || innerIndex >= d.itemCount) return 0.0;

    var at = d.rowOffset + innerIndex * d.rowSize;
    var sum = 0.0;
    for (var i = 0; i < d.regionIndexes.length; i++) {
      // The row is read column by column even when the scalar is zero: the
      // columns are variable-width, so skipping one means losing the cursor.
      final int value;
      if (i < d.wordCount) {
        if (d.longWords) {
          value = _reader.int32At(at);
          at += 4;
        } else {
          value = _reader.int16At(at);
          at += 2;
        }
      } else {
        if (d.longWords) {
          value = _reader.int16At(at);
          at += 2;
        } else {
          value = _reader.int8At(at);
          at += 1;
        }
      }
      if (value == 0) continue;
      final s = _regions[d.regionIndexes[i]].scalar(coords);
      if (s != 0) sum += value * s;
    }
    return sum;
  }

  /// `HVAR` convenience: resolves [glyphId] through the delta-set index map, if
  /// this store has one, and then through the store.
  ///
  /// With no map the spec's implicit mapping applies — subtable 0, row
  /// `glyphId` — which is what a font that lists every glyph separately means.
  double deltaForGlyph(int glyphId, List<double> coords) {
    final map = _map;
    if (map == null) return delta(0, glyphId, coords);
    final (outer, inner) = map[glyphId];
    return delta(outer, inner, coords);
  }
}
