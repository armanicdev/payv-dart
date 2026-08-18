/// [OpenTypeFont] — the facade every other part of `payv` talks to.
///
/// This file is the CONTRACT. Each table class named here is implemented in its
/// own file with exactly the constructor and members used below; nothing in the
/// engine reaches around this facade into raw bytes. That is what keeps the
/// shaper, the subsetter and the PDF writer independently testable.
///
/// Tables parse LAZILY. Building an [OpenTypeFont] over a 4 MB variable font
/// reads only the table directory; `GSUB` is not touched until something asks
/// to shape.
library;

import 'dart:typed_data';

import '../layout/gdef.dart';
import '../layout/gpos.dart';
import '../layout/gsub.dart';
import '../util/byte_reader.dart';
import '../util/tag.dart';
import 'glyph_path.dart';
import 'sfnt.dart';
import 'tables/cmap.dart';
import 'tables/glyf.dart';
import 'tables/head.dart';
import 'tables/hmtx.dart';
import 'tables/maxp.dart';
import 'tables/name.dart';
import 'tables/os2.dart';
import 'tables/post.dart';
import 'variations/fvar.dart';
import 'variations/gvar.dart';
import 'variations/variation_store.dart';

/// A parsed OpenType font, ready to shape and to embed.
class OpenTypeFont {
  OpenTypeFont._(this.sfnt, this._coords);

  /// Parses [bytes]. Cheap — only the table directory is read.
  ///
  /// [fontIndex] picks a face out of a `ttcf` collection.
  factory OpenTypeFont.parse(Uint8List bytes, {int fontIndex = 0}) =>
      OpenTypeFont._(SfntFile.parse(bytes, fontIndex: fontIndex), null);

  /// A view of this font at a point in its variation space.
  ///
  /// PDF cannot carry a variable font — a viewer has no way to be told which
  /// instance to draw — so an export of a variable face MUST go through here or
  /// through the instancer. Coordinates are in normalised F2Dot14 space
  /// (-1.0 … 1.0) after `avar` mapping; use [normalizeAxisValues] to convert
  /// user coordinates such as `{'wght': 600}`.
  OpenTypeFont withVariationCoords(List<double> normalizedCoords) =>
      OpenTypeFont._(sfnt, List<double>.unmodifiable(normalizedCoords));

  final SfntFile sfnt;
  final List<double>? _coords;

  /// Normalised variation coordinates, or null for a static font / the default
  /// instance.
  List<double>? get variationCoords => _coords;

  bool get isVariable => sfnt.has(Tag.fvar);

  /// True when this font still needs instancing before it can be embedded.
  bool get needsInstancing => isVariable;

  // ── required tables ─────────────────────────────────────────────────────────

  HeadTable get head => _head ??= HeadTable.parse(sfnt.requireTable(Tag.head));
  HeadTable? _head;

  /// Font design units per em. Every unscaled value in this library is in these.
  int get unitsPerEm => head.unitsPerEm;

  /// Note the `t.position +` on every offset below.
  ///
  /// [SfntFile.table] hands back a reader over the WHOLE file, positioned at
  /// the table — it does not slice. So a table-relative offset must be added to
  /// `position`; reading `uint16At(4)` reads file offset 4, which in an SFNT is
  /// `numTables`. That mistake made this getter return 18 instead of 1333 on
  /// Vazirmatn, and every downstream bound was silently too small.
  int get numGlyphs => _numGlyphs ??= _u16(Tag.maxp, 4);
  int? _numGlyphs;

  CmapTable get cmap => _cmap ??= CmapTable.parse(sfnt.requireTable(Tag.cmap));
  CmapTable? _cmap;

  HmtxTable get hmtx => _hmtx ??= HmtxTable.parse(
    sfnt.requireTable(Tag.hmtx),
    numberOfHMetrics: _u16(Tag.hhea, 34),
    numGlyphs: numGlyphs,
  );
  HmtxTable? _hmtx;

  int _u16(int tag, int offsetInTable) {
    final t = sfnt.requireTable(tag);
    return t.uint16At(t.position + offsetInTable);
  }

  // ── optional tables ─────────────────────────────────────────────────────────

  Os2Table? get os2 => _os2 ??= _sized(Tag.os2, Os2Table.parse);
  Os2Table? _os2;

  NameTable? get name => _name ??= _lazy(Tag.name, NameTable.parse);
  NameTable? _name;

  PostTable? get post => _post ??= _sized(Tag.post, PostTable.parse);
  PostTable? _post;

  /// `maxp`. [numGlyphs] reads its own field directly and does not need this;
  /// the table is here for a caller that wants the outline limits.
  MaxpTable? get maxp => _maxp ??= _sized(Tag.maxp, MaxpTable.parse);
  MaxpTable? _maxp;

  /// TrueType outlines. Null for a CFF font — check [SfntFile.hasCffOutlines].
  GlyfTable? get glyf {
    if (_glyf != null) return _glyf;
    final t = sfnt.table(Tag.glyf);
    if (t == null) return null;
    return _glyf = GlyfTable.parse(
      t,
      loca: sfnt.requireTable(Tag.loca),
      indexToLocFormat: head.indexToLocFormat,
      numGlyphs: numGlyphs,
    );
  }

  GlyfTable? _glyf;

  FvarTable? get fvar => _fvar ??= _lazy(Tag.fvar, FvarTable.parse);
  FvarTable? _fvar;

  /// `gvar` point deltas. Needed together with [variationCoords] to draw a
  /// variable font at anything but its default instance.
  GvarTable? get gvar {
    if (_gvarRead) return _gvar;
    _gvarRead = true;
    final t = sfnt.table(Tag.gvar);
    if (t == null) return null;
    return _gvar = GvarTable.parse(
      t,
      numGlyphs: numGlyphs,
      axisCount: fvar?.axes.length ?? 0,
    );
  }

  GvarTable? _gvar;
  bool _gvarRead = false;

  /// The outline of [glyphId] at this font's variation instance.
  ///
  /// Prefer this over `glyf!.outline(gid)` — it is the only path that actually
  /// applies [variationCoords]. Calling the table directly silently gives you
  /// the default instance, which on a weight axis means every exported document
  /// comes out Regular no matter what was asked for.
  GlyphPath? outline(int glyphId) {
    final table = glyf;
    if (table == null) return null;
    final coords = _coords;
    return coords == null || coords.isEmpty
        ? table.outline(glyphId)
        : table.outline(glyphId, coords: coords, gvar: gvar);
  }

  /// `HVAR` advance deltas, applied on top of `hmtx` for a variable instance.
  ///
  /// Built through [ItemVariationStore.parseHvar], which reads the table's
  /// `advanceWidthMapping` as well as its VarStore. Skipping that map and
  /// falling back to the spec's implicit `(outer 0, inner glyphId)` looks
  /// plausible and is wrong: measured against fontTools on Vazirmatn, the
  /// mapped path gets 1333/1333 advances right and the fallback 179/1333.
  ItemVariationStore? get hvar {
    if (_hvarRead) return _hvar;
    _hvarRead = true;
    final t = sfnt.table(Tag.hvar);
    if (t == null) return null;
    return _hvar = ItemVariationStore.parseHvar(t);
  }

  ItemVariationStore? _hvar;
  bool _hvarRead = false;

  // ── layout tables ───────────────────────────────────────────────────────────

  GdefTable? get gdef => _gdef ??= _lazy(Tag.gdef, GdefTable.parse);
  GdefTable? _gdef;

  GsubTable? get gsub => _gsub ??= _lazy(Tag.gsub, GsubTable.parse);
  GsubTable? _gsub;

  GposTable? get gpos => _gpos ??= _lazy(Tag.gpos, GposTable.parse);
  GposTable? _gpos;

  // ── glyph queries ───────────────────────────────────────────────────────────

  /// Glyph index for [codepoint], or 0 (`.notdef`) when unmapped.
  ///
  /// Note what this CANNOT do: reach `lamVabove_alef.isol`, `uni06D5.fina` or
  /// any other glyph the font exposes only through `GSUB`. Those glyphs have no
  /// codepoint, in any Unicode block, by design. Every PDF library that shapes
  /// Arabic by "mapping to presentation forms" is stuck behind exactly this
  /// method, which is why four Sorani letters are unrenderable to them. The way
  /// out is [GsubTable], not a bigger cmap.
  int glyphForCodepoint(int codepoint) => cmap.lookup(codepoint);

  /// Horizontal advance of [glyphId] in design units, including any `HVAR`
  /// delta for the current variation instance.
  int advanceWidth(int glyphId) {
    final base = hmtx.advanceWidth(glyphId);
    final coords = _coords;
    if (coords == null) return base;
    final store = hvar;
    if (store == null) return base;
    return base + store.deltaForGlyph(glyphId, coords).round();
  }

  int leftSideBearing(int glyphId) => hmtx.leftSideBearing(glyphId);

  /// Converts user-space axis values (`{'wght': 600}`) into the normalised
  /// coordinates [withVariationCoords] expects, applying `avar` if present.
  List<double> normalizeAxisValues(Map<String, double> axisValues) {
    final f = fvar;
    if (f == null) return const <double>[];
    return f.normalize(axisValues, avar: sfnt.table(Tag.avar));
  }

  T? _lazy<T>(int tag, T Function(ByteReader) parse) {
    final t = sfnt.table(tag);
    return t == null ? null : parse(t);
  }

  /// [_lazy] for a table whose format has a VERSION TAIL — a header field that
  /// says how much more table follows.
  ///
  /// Those parsers cannot bound themselves. `SfntFile.table()` hands back a
  /// reader over the whole file positioned at the table (deliberately: an
  /// OpenType offset may point backwards into a parent, so slicing per table
  /// would break real fonts), so a parser's own `canRead` asks "does the FILE
  /// have room", and a table that is not the last one always says yes. The
  /// version word is then believed over the body, and the tail decodes out of
  /// whichever table happens to follow.
  ///
  /// The directory already records the true length, and this is the one place
  /// that knows it, so it passes it rather than leaving each parser to be told
  /// by every caller. Measured before this existed, on Vazirmatn with its
  /// `OS/2` version word flipped to 5 over a 96-byte body:
  /// `usLowerOpticalPointSize` decoded to 908 out of `post`, and `sCapHeight` /
  /// `sxHeight` go straight into the PDF font descriptor.
  T? _sized<T>(int tag, T Function(ByteReader, {int? tableLength}) parse) {
    final rec = sfnt.record(tag);
    if (rec == null) return null;
    return parse(sfnt.reader.at(rec.offset), tableLength: rec.length);
  }
}
