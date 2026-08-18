/// Variable → static: pinning a variable font at one point in its design space.
///
/// This exists because of a hard limit in PDF, not a convenience. A PDF font
/// resource has nowhere to say "draw this face at wght 600" — there is no
/// variation dictionary, no axis array, nothing. A viewer handed a variable
/// font either ignores the variations entirely and draws the DEFAULT instance,
/// or refuses the file. So a document set in Vazirmatn SemiBold that embeds the
/// variable face prints Regular, on every viewer, silently. The only fix is to
/// bake the instance into the outlines before embedding, which is this file.
///
/// Baking means re-encoding `glyf`. `gvar` deltas are fractional and per point;
/// once they are applied, the glyph's flag runs, its short/long delta choices
/// and its bounding box are all wrong, so the record has to be written from
/// scratch. The encoder at the bottom is therefore not an optimisation — it is
/// the only way to get the moved points back into a font at all.
///
/// What this does NOT instance: `GPOS` values carrying `VariationIndex` device
/// records, which resolve through `GDEF`'s `ItemVariationStore`. That store is
/// kept, so those values stay at their default instance. It is deliberate and
/// it is safe HERE, because `payv` shapes against the ORIGINAL variable face —
/// where the coordinates are live — and instances only for embedding, and the
/// subsetter then drops `GPOS` entirely. A caller using the instanced font as a
/// general-purpose face should know that positioning is at the default.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';
import '../util/tag.dart';
import 'open_type_font.dart';
import 'subset.dart';
import 'table_builder.dart';
import 'tables/glyf.dart';
import 'variations/gvar.dart';
import 'variations/variation_store.dart';

/// Simple-glyph point flags. Duplicated from `glyf.dart` rather than shared:
/// that file's set is a reader's, this one is a writer's, and the writer needs
/// `OVERLAP_SIMPLE` — the bit that tells a rasteriser the contours self-cross
/// and must be filled non-zero. Lose it and a re-encoded glyph develops holes
/// where its strokes overlap.
const int _flagOnCurve = 0x01;
const int _flagXShort = 0x02;
const int _flagYShort = 0x04;
const int _flagRepeat = 0x08;
const int _flagXSameOrPositive = 0x10;
const int _flagYSameOrPositive = 0x20;
const int _flagOverlapSimple = 0x40;

/// A composite nesting deeper than this is broken; the same ceiling `glyf.dart`
/// uses, for the same reason.
const int _maxCompositeDepth = 8;

/// Tables that describe variation and therefore cannot survive instancing.
///
/// `avar` and `fvar` describe an axis that no longer exists; `gvar`, `HVAR`,
/// `VVAR` and `MVAR` describe deltas that have been applied; `STAT` describes
/// this face's place in a family whose axes are gone. `CFF2` is here because a
/// CFF2 face reaching this point is a bug — see the throw in [Instancer.instance].
final Set<int> _droppedTables = <int>{
  Tag.fvar,
  Tag.gvar,
  Tag.avar,
  Tag.hvar,
  Tag.mvar,
  Tag.stat,
  Tag.cff2,
  Tag.parse('VVAR'), // no constant in `Tag`; this file is its only user
};

/// One glyph, decoded and moved to the requested instance.
class _Instanced {
  _Instanced.empty()
    : xs = const <double>[],
      ys = const <double>[],
      onCurve = const <bool>[],
      rawFlags = const <int>[],
      endPoints = const <int>[],
      instructions = _noBytes,
      composite = null,
      phantomDx = 0,
      advanceDx = 0;

  _Instanced.simple({
    required this.xs,
    required this.ys,
    required this.onCurve,
    required this.rawFlags,
    required this.endPoints,
    required this.instructions,
    required this.phantomDx,
    required this.advanceDx,
  }) : composite = null;

  _Instanced.composite(this.composite, this.phantomDx, this.advanceDx)
    : xs = const <double>[],
      ys = const <double>[],
      onCurve = const <bool>[],
      rawFlags = const <int>[],
      endPoints = const <int>[],
      instructions = _noBytes;

  /// Instanced point coordinates, already rounded to integers but kept as
  /// doubles because a composite parent transforms them.
  final List<double> xs;
  final List<double> ys;
  final List<bool> onCurve;

  /// The source flags, from which only `ON_CURVE` and `OVERLAP_SIMPLE` survive
  /// re-encoding — every other bit describes the delta encoding, which changes.
  final List<int> rawFlags;
  final List<int> endPoints;
  final Uint8List instructions;

  /// Non-null for a composite glyph, whose "points" are component offsets.
  final CompositeGlyph? composite;

  /// How far `gvar` moved phantom point 1, the left sidebearing origin. Needed
  /// to recover the left sidebearing, which is measured from it and not from
  /// the origin.
  final double phantomDx;

  /// How far `gvar` moved pp2 relative to pp1 — i.e. how much wider or narrower
  /// this instance's advance is. Only consulted when the font ships no `HVAR`.
  final double advanceDx;

  bool get isEmpty => composite == null && endPoints.isEmpty;
}

/// Pins a variable font to a static instance.
class Instancer {
  const Instancer._();

  /// Instances [font] at [normalizedCoords] — one F2Dot14-range value per
  /// `fvar` axis, already `avar`-mapped.
  ///
  /// A short list is padded with zeros (those axes stay at their default) and a
  /// long one is trimmed, so a caller may pass `[1.0]` to a one-axis font
  /// without knowing the axis count.
  ///
  /// A static font passes through unchanged apart from being re-containered.
  static Uint8List instance(OpenTypeFont font, List<double> normalizedCoords) {
    final builder = SfntBuilder();
    for (final tag in font.sfnt.tableTags) {
      if (_droppedTables.contains(tag)) continue;
      final bytes = font.sfnt.tableBytes(tag);
      if (bytes != null) builder.setTable(tag, bytes);
    }
    if (!font.isVariable) {
      return builder.build(sfntVersion: font.sfnt.sfntVersion);
    }

    final glyf = font.glyf;
    if (glyf == null) {
      throw UnsupportedError(
        'instancing needs glyf outlines; CFF2 instancing is not implemented',
      );
    }

    final axisCount = font.fvar?.axes.length ?? 0;
    final coords = List<double>.generate(
      axisCount,
      (i) => i < normalizedCoords.length ? normalizedCoords[i] : 0.0,
      growable: false,
    );
    // The facade at these coords — the only path that applies `HVAR`, and the
    // one the shaper itself measures with. Advances taken from anywhere else
    // would disagree with the positions already written into the page.
    final view = font.withVariationCoords(coords);
    final gvar = font.gvar;

    final numGlyphs = font.numGlyphs;
    final glyphs = List<_Instanced>.generate(
      numGlyphs,
      (gid) => _decode(glyf, gvar, coords, gid),
      growable: false,
    );

    final bounds = _Bounds(glyphs, numGlyphs);
    final records = List<Uint8List?>.generate(numGlyphs, (gid) {
      final g = glyphs[gid];
      final box = bounds.of(gid);
      final composite = g.composite;
      if (composite != null) return composite.encode(box);
      if (g.isEmpty) return null;
      return _encodeSimple(g, box);
    }, growable: false);

    final glyphData = _assembleGlyf(records);
    builder.setTable(Tag.glyf, glyphData.$1);
    builder.setTable(Tag.loca, glyphData.$2);

    final metrics = _buildHmtx(font, view, glyphs, bounds, numGlyphs);
    builder.setTable(Tag.hmtx, metrics.$1);

    final head = _table(font, Tag.head, 54);
    ByteData.view(head.buffer).setInt16(50, glyphData.$3 ? 1 : 0);
    // `head`'s font-wide box is left alone. Every instanced glyph fits inside
    // the union across the whole design space, which is what the variable font
    // already declared, so the box stays valid — merely loose. fontTools makes
    // the same call.
    builder.setTable(Tag.head, head);

    final hhea = _table(font, Tag.hhea, 36);
    ByteData.view(hhea.buffer).setUint16(34, metrics.$2);
    builder.setTable(Tag.hhea, hhea);

    _applyMvar(font, builder, coords);

    return builder.build(sfntVersion: font.sfnt.sfntVersion);
  }

  /// Instances at user-space axis values — `{'wght': 600}`.
  ///
  /// Goes through [OpenTypeFont.normalizeAxisValues], so `avar` is applied and
  /// the result is quantised to the F2Dot14 grid the font's own masters sit on.
  static Uint8List instanceAxes(
    OpenTypeFont font,
    Map<String, double> axisValues,
  ) => instance(font, font.normalizeAxisValues(axisValues));

  // ── decoding + delta application ──────────────────────────────────────────

  /// Reads glyph [gid] and moves it to [coords].
  ///
  /// The point-level decode here duplicates what `GlyfTable` does internally,
  /// and there is no way around it: the frozen facade exposes outlines as
  /// [GlyphPath] — move/line/quad commands — which has already thrown away the
  /// on-curve flags, the contour ends and the implied midpoints. You cannot
  /// re-encode a `glyf` record from curves. `glyphBytes` is the seam the
  /// contract does offer, so this reads through it and decodes the points
  /// itself, applying `gvar` through [GvarTable.deltas] exactly as `glyf.dart`
  /// does so that the two agree point for point before rounding.
  static _Instanced _decode(
    GlyfTable glyf,
    GvarTable? gvar,
    List<double> coords,
    int gid,
  ) {
    final data = glyf.glyphBytes(gid);
    if (data == null) return _Instanced.empty();

    final r = ByteReader.fromBytes(data);
    final numberOfContours = r.int16At(0);
    if (numberOfContours < 0) {
      return _decodeComposite(data, gvar, coords, gid);
    }
    if (numberOfContours == 0) return _Instanced.empty();

    var p = 10;
    final endPoints = List<int>.filled(numberOfContours, 0);
    for (var i = 0; i < numberOfContours; i++) {
      endPoints[i] = r.uint16At(p);
      p += 2;
    }
    final numPoints = endPoints[numberOfContours - 1] + 1;

    final instructionLength = r.uint16At(p);
    p += 2;
    final instructions = instructionLength == 0
        ? _noBytes
        : Uint8List.fromList(data.sublist(p, p + instructionLength));
    p += instructionLength;

    final flags = List<int>.filled(numPoints, 0);
    var i = 0;
    while (i < numPoints) {
      final f = r.uint8At(p);
      p += 1;
      flags[i] = f;
      i += 1;
      if (f & _flagRepeat != 0) {
        var repeat = r.uint8At(p);
        p += 1;
        while (repeat > 0 && i < numPoints) {
          flags[i] = f;
          i += 1;
          repeat -= 1;
        }
      }
    }

    // Four phantom points ride behind the real ones: `gvar` indexes them, and
    // pp1 is where the left sidebearing is measured from. They belong to no
    // contour, so IUP never touches them and their coordinates can stay at
    // zero — which is what `glyf.dart` does, and matching it is what keeps the
    // instanced outline identical to the one the shaper drew.
    final total = numPoints + 4;
    final xs = List<double>.filled(total, 0);
    var x = 0;
    for (var k = 0; k < numPoints; k++) {
      final f = flags[k];
      if (f & _flagXShort != 0) {
        final d = r.uint8At(p);
        p += 1;
        x += f & _flagXSameOrPositive != 0 ? d : -d;
      } else if (f & _flagXSameOrPositive == 0) {
        x += r.int16At(p);
        p += 2;
      }
      xs[k] = x.toDouble();
    }

    final ys = List<double>.filled(total, 0);
    var y = 0;
    for (var k = 0; k < numPoints; k++) {
      final f = flags[k];
      if (f & _flagYShort != 0) {
        final d = r.uint8At(p);
        p += 1;
        y += f & _flagYSameOrPositive != 0 ? d : -d;
      } else if (f & _flagYSameOrPositive == 0) {
        y += r.int16At(p);
        p += 2;
      }
      ys[k] = y.toDouble();
    }

    var phantomDx = 0.0;
    var advanceDx = 0.0;
    if (gvar != null && coords.isNotEmpty) {
      final deltas = gvar.deltas(
        gid,
        coords,
        total,
        contourEnds: endPoints,
        xs: xs,
        ys: ys,
      );
      if (deltas != null) {
        for (var k = 0; k < numPoints; k++) {
          xs[k] += deltas[k].$1;
          ys[k] += deltas[k].$2;
        }
        phantomDx = deltas[numPoints].$1;
        advanceDx = deltas[numPoints + 1].$1 - phantomDx;
      }
    }

    // Round now, not at encode time. A `glyf` coordinate is an integer, so the
    // rounding has to happen before the bounding box and the sidebearing are
    // derived from it — otherwise the box describes a glyph that was never
    // written.
    for (var k = 0; k < numPoints; k++) {
      xs[k] = _otRound(xs[k]).toDouble();
      ys[k] = _otRound(ys[k]).toDouble();
    }

    return _Instanced.simple(
      xs: xs.sublist(0, numPoints),
      ys: ys.sublist(0, numPoints),
      onCurve: List<bool>.generate(
        numPoints,
        (k) => flags[k] & _flagOnCurve != 0,
        growable: false,
      ),
      rawFlags: flags,
      endPoints: endPoints,
      instructions: instructions,
      phantomDx: phantomDx,
      advanceDx: advanceDx,
    );
  }

  static _Instanced _decodeComposite(
    Uint8List data,
    GvarTable? gvar,
    List<double> coords,
    int gid,
  ) {
    final composite = CompositeGlyph.parse(data)!;
    var phantomDx = 0.0;
    var advanceDx = 0.0;
    if (gvar != null && coords.isNotEmpty) {
      // A composite varies by moving its components, so `gvar` gives it one
      // "point" per component — plus the same four phantoms. No contour ends
      // are passed because there are no contours: IUP is undefined here, and a
      // component no master moved simply does not move.
      final n = composite.components.length;
      final deltas = gvar.deltas(gid, coords, n + 4);
      if (deltas != null) {
        for (var i = 0; i < n; i++) {
          final c = composite.components[i];
          // Point-matching components position themselves against a point
          // NUMBER, not a coordinate. Adding a delta to an index would pick a
          // different point and detach the accent entirely.
          if (!c.argsAreXy) continue;
          c.arg1 = _otRound(c.arg1 + deltas[i].$1);
          c.arg2 = _otRound(c.arg2 + deltas[i].$2);
        }
        phantomDx = deltas[n].$1;
        advanceDx = deltas[n + 1].$1 - phantomDx;
      }
    }
    return _Instanced.composite(composite, phantomDx, advanceDx);
  }

  // ── glyf assembly ─────────────────────────────────────────────────────────

  /// Returns `(glyf, loca, longLoca)`.
  static (Uint8List, Uint8List, bool) _assembleGlyf(List<Uint8List?> records) {
    final numGlyphs = records.length;
    final offsets = List<int>.filled(numGlyphs + 1, 0);
    var total = 0;
    for (var gid = 0; gid < numGlyphs; gid++) {
      offsets[gid] = total;
      final record = records[gid];
      if (record == null) continue;
      total += record.length;
      if (total.isOdd) total += 1; // short `loca` stores halved offsets
    }
    offsets[numGlyphs] = total;

    final out = Uint8List(total);
    for (var gid = 0; gid < numGlyphs; gid++) {
      final record = records[gid];
      if (record == null) continue;
      out.setRange(offsets[gid], offsets[gid] + record.length, record);
    }

    final longLoca = total > 0x1FFFE;
    final loca = Uint8List((numGlyphs + 1) * (longLoca ? 4 : 2));
    final view = ByteData.view(loca.buffer);
    for (var i = 0; i <= numGlyphs; i++) {
      if (longLoca) {
        view.setUint32(i * 4, offsets[i]);
      } else {
        view.setUint16(i * 2, offsets[i] >> 1);
      }
    }
    return (out, loca, longLoca);
  }

  /// Re-encodes one simple glyph.
  ///
  /// The compression is not decoration. Written naively — 16-bit deltas, one
  /// flag byte per point — Vazirmatn's `glyf` grows by roughly 60%, and the
  /// whole reason to instance before embedding was to make the file smaller.
  /// Three encodings are chosen per coordinate: absent (the delta is zero),
  /// one unsigned byte with the sign carried in a FLAG bit, or a signed word.
  static Uint8List _encodeSimple(_Instanced g, (int, int, int, int) bounds) {
    final n = g.xs.length;
    final w = GlyphWriter();
    w.int16(g.endPoints.length);
    w.int16(bounds.$1);
    w.int16(bounds.$2);
    w.int16(bounds.$3);
    w.int16(bounds.$4);
    for (final e in g.endPoints) {
      w.uint16(e);
    }
    w.uint16(g.instructions.length);
    w.bytes(g.instructions);

    final flags = List<int>.filled(n, 0);
    final dxs = List<int>.filled(n, 0);
    final dys = List<int>.filled(n, 0);
    var prevX = 0;
    var prevY = 0;
    for (var i = 0; i < n; i++) {
      final x = g.xs[i].toInt();
      final y = g.ys[i].toInt();
      final dx = x - prevX;
      final dy = y - prevY;
      prevX = x;
      prevY = y;
      dxs[i] = dx;
      dys[i] = dy;

      // Only two bits survive: the rest describe the delta encoding, which is
      // being rewritten. `OVERLAP_SIMPLE` is carried over EXACTLY as the source
      // font set it and is never added — fontTools' instancer sets it on every
      // glyph by default, on the theory that interpolation can create overlaps,
      // and that is a rendering decision belonging to the type designer rather
      // than to a tool that only moved points the font itself told it to move.
      var f = g.rawFlags[i] & (_flagOnCurve | _flagOverlapSimple);
      if (dx == 0) {
        f |= _flagXSameOrPositive; // "same as previous": no bytes at all
      } else if (dx >= -255 && dx <= 255) {
        f |= _flagXShort;
        if (dx > 0) f |= _flagXSameOrPositive; // here the bit means "positive"
      }
      if (dy == 0) {
        f |= _flagYSameOrPositive;
      } else if (dy >= -255 && dy <= 255) {
        f |= _flagYShort;
        if (dy > 0) f |= _flagYSameOrPositive;
      }
      flags[i] = f;
    }

    // Run-length compression over the flag array. The repeat count is the
    // number of ADDITIONAL points, so a run of 300 is a byte of 255 followed by
    // a fresh flag and a count of 43.
    var i = 0;
    while (i < n) {
      final f = flags[i];
      var run = 1;
      while (i + run < n && flags[i + run] == f && run < 256) {
        run++;
      }
      if (run > 1) {
        w.uint8(f | _flagRepeat);
        w.uint8(run - 1);
      } else {
        w.uint8(f);
      }
      i += run;
    }

    for (var k = 0; k < n; k++) {
      final f = flags[k];
      if (f & _flagXShort != 0) {
        w.uint8(dxs[k].abs());
      } else if (f & _flagXSameOrPositive == 0) {
        w.int16(dxs[k]);
      }
    }
    for (var k = 0; k < n; k++) {
      final f = flags[k];
      if (f & _flagYShort != 0) {
        w.uint8(dys[k].abs());
      } else if (f & _flagYSameOrPositive == 0) {
        w.int16(dys[k]);
      }
    }
    return w.take();
  }

  // ── metrics ───────────────────────────────────────────────────────────────

  /// Returns `(hmtx, numberOfHMetrics)`.
  static (Uint8List, int) _buildHmtx(
    OpenTypeFont font,
    OpenTypeFont instanceView,
    List<_Instanced> glyphs,
    _Bounds bounds,
    int numGlyphs,
  ) {
    final hmtx = font.hmtx;
    final glyf = font.glyf;
    final hasHvar = font.sfnt.has(Tag.hvar);
    final advances = List<int>.filled(numGlyphs, 0);
    final lsbs = List<int>.filled(numGlyphs, 0);

    for (var gid = 0; gid < numGlyphs; gid++) {
      final g = glyphs[gid];
      advances[gid] = hasHvar
          // `HVAR` wins when the font has one. The spec makes it authoritative
          // over the phantom points, and it is also what the SHAPER measured
          // with — an embedded font whose advances disagree with the positions
          // already written into the content stream draws text that creeps.
          //
          // It matters rarely and it does matter: on Vazirmatn the two sources
          // agree on 1332 of 1333 glyphs at wght 900, and disagree on uniFBDC,
          // where `HVAR` says 932 and the phantoms say the glyph never moves.
          // fontTools breaks the tie the other way, so that one glyph is an
          // expected difference against it and not a bug.
          ? instanceView.advanceWidth(gid)
          // No `HVAR`: the advance moves with the horizontal phantom points,
          // pp2 − pp1. The only source available in a font shipping `gvar`
          // alone, and what HarfBuzz and FreeType fall back to.
          : hmtx.advanceWidth(gid) + _otRound(g.advanceDx);

      // lsb is measured from pp1, not from the origin. The two differ exactly
      // when a master moved the sidebearing without moving the ink, and baking
      // the new `xMin` alone would slide such a glyph inside its own advance.
      //
      // This runs for glyphs with no ink too, and must: `.notdef` in Vazirmatn
      // has no contours and a sidebearing of 100, which the general formula
      // reproduces as `0 − (0 − 100)` and a "no outline, so lsb 0" shortcut
      // silently destroys.
      final defaultXMin = glyf?.boundingBox(gid)?.xMin.toInt() ?? 0;
      final pp1 = defaultXMin - hmtx.leftSideBearing(gid) + g.phantomDx;
      lsbs[gid] = bounds.of(gid).$1 - _otRound(pp1);
    }

    // The trailing glyphs share the last advance; an Arabic subset ends in a
    // run of marks that all measure zero, so this is not a rounding error's
    // worth of saving.
    var metrics = numGlyphs;
    while (metrics > 1 && advances[metrics - 1] == advances[metrics - 2]) {
      metrics--;
    }

    final bytes = Uint8List(metrics * 4 + (numGlyphs - metrics) * 2);
    final out = ByteData.view(bytes.buffer);
    for (var i = 0; i < metrics; i++) {
      out.setUint16(i * 4, advances[i].clamp(0, 0xFFFF));
      out.setInt16(i * 4 + 2, lsbs[i].clamp(-32768, 32767));
    }
    for (var i = metrics; i < numGlyphs; i++) {
      out.setInt16(
        metrics * 4 + (i - metrics) * 2,
        lsbs[i].clamp(-32768, 32767),
      );
    }
    return (bytes, metrics);
  }

  // ── MVAR ──────────────────────────────────────────────────────────────────

  /// Bakes `MVAR` deltas into the metric tables they target.
  ///
  /// Absent from Vazirmatn — as it is from most text faces, which vary outlines
  /// and advances but keep one set of line metrics across the whole space — so
  /// this path is written from the spec's own value-tag table and exercised by
  /// no test in this package. It is here because a font that DOES ship `MVAR`
  /// and is instanced without it comes out with line metrics from the wrong
  /// weight, which shows up as leading that changes when a heading is bolded.
  static void _applyMvar(
    OpenTypeFont font,
    SfntBuilder builder,
    List<double> coords,
  ) {
    final mvar = font.sfnt.table(Tag.mvar);
    if (mvar == null) return;
    final base = mvar.position;
    if (mvar.uint16At(base) != 1) return; // an MVAR we do not understand
    final recordSize = mvar.uint16At(base + 6);
    final recordCount = mvar.uint16At(base + 8);
    final storeOffset = mvar.uint16At(base + 10);
    if (recordCount == 0 || storeOffset == 0 || recordSize < 8) return;

    final store = ItemVariationStore.parse(mvar.at(base + storeOffset));
    final patched = <int, Uint8List>{};

    for (var i = 0; i < recordCount; i++) {
      final at = base + 12 + i * recordSize;
      final target = _mvarTargets[mvar.uint32At(at)];
      if (target == null) continue; // gasp ranges and anything unregistered
      final delta = _otRound(
        store.delta(mvar.uint16At(at + 4), mvar.uint16At(at + 6), coords),
      );
      if (delta == 0) continue;

      final bytes = patched[target.table] ??= _staged(
        font,
        builder,
        target.table,
      );
      // A font may name a target table it does not ship, or ship a version too
      // short to hold the field — `sxHeight` needs OS/2 v2. Skip, don't throw.
      if (bytes.length < target.offset + 2) continue;
      final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
      if (target.signed) {
        view.setInt16(
          target.offset,
          (view.getInt16(target.offset) + delta).clamp(-32768, 32767),
        );
      } else {
        view.setUint16(
          target.offset,
          (view.getUint16(target.offset) + delta).clamp(0, 0xFFFF),
        );
      }
    }

    patched.forEach((tag, bytes) {
      if (bytes.isNotEmpty) builder.setTable(tag, bytes);
    });
  }

  /// A mutable copy of the table AS ALREADY STAGED, falling back to the source.
  ///
  /// Reading from the source font instead would be the obvious version and a
  /// real bug: `hhea` has by this point been rewritten with a new
  /// `numberOfHMetrics`, and an `MVAR` caret delta patched onto the ORIGINAL
  /// bytes would put the old metric count back and truncate `hmtx`.
  static Uint8List _staged(OpenTypeFont font, SfntBuilder builder, int tag) {
    final bytes = builder.table(tag) ?? font.sfnt.tableBytes(tag);
    return bytes == null ? _noBytes : Uint8List.fromList(bytes);
  }

  static Uint8List _table(OpenTypeFont font, int tag, int minimumLength) {
    final bytes = font.sfnt.tableBytes(tag);
    if (bytes == null || bytes.length < minimumLength) {
      throw FontFormatException(
        'font has no usable ${Tag(tag).asString} table to instance',
      );
    }
    return Uint8List.fromList(bytes);
  }
}

/// Recomputed glyph bounding boxes.
///
/// A composite's box cannot be derived from its components' boxes — a component
/// may carry a 2×2 transform that rotates or reflects it, and the box of a
/// rotated box is not the box of the rotated points. So this resolves a
/// composite down to its actual points, exactly as a rasteriser would, and
/// memoises the result because an accented small-cap resolves the same base
/// letter several times over.
class _Bounds {
  _Bounds(this._glyphs, int numGlyphs)
    : _cache = List<(int, int, int, int)?>.filled(numGlyphs, null);

  final List<_Instanced> _glyphs;
  final List<(int, int, int, int)?> _cache;

  (int, int, int, int) of(int gid) {
    final hit = _cache[gid];
    if (hit != null) return hit;
    final points = _points(gid, 0);
    if (points.$1.isEmpty) return _cache[gid] = (0, 0, 0, 0);
    var xMin = double.infinity;
    var yMin = double.infinity;
    var xMax = double.negativeInfinity;
    var yMax = double.negativeInfinity;
    for (var i = 0; i < points.$1.length; i++) {
      final x = points.$1[i];
      final y = points.$2[i];
      if (x < xMin) xMin = x;
      if (x > xMax) xMax = x;
      if (y < yMin) yMin = y;
      if (y > yMax) yMax = y;
    }
    return _cache[gid] = (
      _otRound(xMin),
      _otRound(yMin),
      _otRound(xMax),
      _otRound(yMax),
    );
  }

  /// Every point of [gid] after composition, in glyph space.
  (List<double>, List<double>) _points(int gid, int depth) {
    if (gid < 0 || gid >= _glyphs.length || depth >= _maxCompositeDepth) {
      return (const <double>[], const <double>[]);
    }
    final g = _glyphs[gid];
    final composite = g.composite;
    if (composite == null) return (g.xs, g.ys);

    final xs = <double>[];
    final ys = <double>[];
    for (final c in composite.components) {
      final child = _points(c.glyphId, depth + 1);
      final n = child.$1.length;
      if (n == 0) continue;
      final tx = List<double>.filled(n, 0);
      final ty = List<double>.filled(n, 0);
      for (var k = 0; k < n; k++) {
        tx[k] = c.xxValue * child.$1[k] + c.yxValue * child.$2[k];
        ty[k] = c.xyValue * child.$1[k] + c.yyValue * child.$2[k];
      }

      double ox;
      double oy;
      if (c.argsAreXy) {
        ox = c.arg1.toDouble();
        oy = c.arg2.toDouble();
        if (c.flags & compScaledOffset != 0) {
          final sx = c.xxValue * ox + c.yxValue * oy;
          final sy = c.xyValue * ox + c.yyValue * oy;
          ox = sx;
          oy = sy;
        }
      } else {
        if (c.arg1 >= xs.length || c.arg2 >= n) continue;
        ox = xs[c.arg1] - tx[c.arg2];
        oy = ys[c.arg1] - ty[c.arg2];
      }

      for (var k = 0; k < n; k++) {
        xs.add(tx[k] + ox);
        ys.add(ty[k] + oy);
      }
    }
    return (xs, ys);
  }
}

/// Where one `MVAR` value tag lands.
class _MvarTarget {
  const _MvarTarget(this.table, this.offset, {this.signed = true});

  final int table;
  final int offset;
  final bool signed;
}

/// The registered `MVAR` value tags, from the OpenType spec's own table.
///
/// Note that `hasc`/`hdsc`/`hlgp` target `OS/2`'s sTypo fields and NOT `hhea`'s
/// ascender/descender, which is the one entry everybody gets backwards — the
/// tag names read like `hhea` fields and are not.
final Map<int, _MvarTarget> _mvarTargets = {
  Tag.parse('hasc'): const _MvarTarget(Tag.os2, 68),
  Tag.parse('hdsc'): const _MvarTarget(Tag.os2, 70),
  Tag.parse('hlgp'): const _MvarTarget(Tag.os2, 72),
  Tag.parse('hcla'): const _MvarTarget(Tag.os2, 74, signed: false),
  Tag.parse('hcld'): const _MvarTarget(Tag.os2, 76, signed: false),
  Tag.parse('sbxs'): const _MvarTarget(Tag.os2, 10),
  Tag.parse('sbys'): const _MvarTarget(Tag.os2, 12),
  Tag.parse('sbxo'): const _MvarTarget(Tag.os2, 14),
  Tag.parse('sbyo'): const _MvarTarget(Tag.os2, 16),
  Tag.parse('spxs'): const _MvarTarget(Tag.os2, 18),
  Tag.parse('spys'): const _MvarTarget(Tag.os2, 20),
  Tag.parse('spxo'): const _MvarTarget(Tag.os2, 22),
  Tag.parse('spyo'): const _MvarTarget(Tag.os2, 24),
  Tag.parse('strs'): const _MvarTarget(Tag.os2, 26),
  Tag.parse('stro'): const _MvarTarget(Tag.os2, 28),
  Tag.parse('xhgt'): const _MvarTarget(Tag.os2, 86),
  Tag.parse('cpht'): const _MvarTarget(Tag.os2, 88),
  Tag.parse('hcrs'): const _MvarTarget(Tag.hhea, 18),
  Tag.parse('hcrn'): const _MvarTarget(Tag.hhea, 20),
  Tag.parse('hcof'): const _MvarTarget(Tag.hhea, 22),
  Tag.parse('vasc'): const _MvarTarget(Tag.vhea, 4),
  Tag.parse('vdsc'): const _MvarTarget(Tag.vhea, 6),
  Tag.parse('vlgp'): const _MvarTarget(Tag.vhea, 8),
  Tag.parse('vcrs'): const _MvarTarget(Tag.vhea, 18),
  Tag.parse('vcrn'): const _MvarTarget(Tag.vhea, 20),
  Tag.parse('vcof'): const _MvarTarget(Tag.vhea, 22),
  Tag.parse('undo'): const _MvarTarget(Tag.post, 8),
  Tag.parse('unds'): const _MvarTarget(Tag.post, 10),
};

final Uint8List _noBytes = Uint8List(0);

/// OpenType's rounding: half goes UP, toward positive infinity.
///
/// Not `double.round()`, which rounds half AWAY from zero — the two disagree at
/// exactly −0.5, −1.5, −2.5 …, which is where a left sidebearing on a glyph
/// that leans left tends to land. fontTools calls this `otRound` and HarfBuzz
/// spells it `roundf(x)`; a font instanced with the wrong one differs from
/// every other tool by one unit on a handful of glyphs, which is the most
/// annoying possible size of bug.
int _otRound(double v) => (v + 0.5).floor();
