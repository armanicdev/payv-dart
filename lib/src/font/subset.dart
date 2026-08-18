/// Font subsetting — emitting a font that carries only the glyphs a document
/// actually draws.
///
/// A 240 KB face embedded in every invoice is 240 KB per invoice; a billing run
/// that mails ten thousand of them a month notices. So the PDF writer embeds a
/// subset, and the subset is far smaller than people expect — usually 3-5% of
/// the original — because of what it is allowed to THROW AWAY, which is the
/// part that surprises everyone:
///
///   A `CIDFontType2` with `Identity-H` encoding addresses glyphs by INDEX. The
///   PDF content stream says "draw glyph 839"; it never says "draw U+06B5". So
///   the embedded font needs no `cmap` — there is nothing left to map from. And
///   the shaping has ALREADY happened, in `payv`, against the original face:
///   `GSUB`/`GPOS`/`GDEF` have done their work and produced that glyph id. A
///   viewer must never re-shape, so shipping the layout tables would at best
///   waste 100 KB and at worst let a viewer disagree with us about what the
///   document says.
///
/// What survives is exactly what a rasteriser needs to draw a glyph by index:
/// `glyf`, `loca`, `head`, `hhea`, `hmtx`, `maxp`, plus the hinting tables
/// (`cvt `, `fpgm`, `prep`, `gasp`) copied verbatim because glyph instructions
/// call into them. That is the set PDF 32000-1 §9.9.2 itself names.
///
/// The one thing a subsetter cannot be lazy about is COMPOSITE CLOSURE. `Aacute`
/// is not an outline, it is "glyph 2 plus glyph 313 shifted up" — and no text
/// ever asked for glyph 313. Drop it and the accent silently disappears. The
/// closure below runs to a fixed point because a component may itself be a
/// composite.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';
import '../util/tag.dart';
import 'open_type_font.dart';
import 'table_builder.dart';
import 'tables/glyf.dart';

/// A subset font plus the glyph renumbering that produced it.
///
/// The maps are the whole point of the return value: after subsetting, the
/// glyph ids the shaper produced are stale, and every one of them has to be
/// translated before it reaches a content stream.
class FontSubset {
  const FontSubset({
    required this.bytes,
    required this.oldToNewGid,
    required this.newToOldGid,
    required this.numGlyphs,
  });

  /// The finished font, ready to become a `FontFile2` stream.
  final Uint8List bytes;

  /// Original glyph id → subset glyph id. Contains every retained glyph,
  /// including the `.notdef` at 0.
  final Map<int, int> oldToNewGid;

  /// Subset glyph id → original glyph id. The inverse of [oldToNewGid]; kept
  /// alongside it so the `CIDToGIDMap` and the `ToUnicode` CMap can both be
  /// built without inverting a map at write time.
  final Map<int, int> newToOldGid;

  /// Glyph count of the subset — what `maxp.numGlyphs` says.
  final int numGlyphs;

  @override
  String toString() => 'FontSubset($numGlyphs glyphs, ${bytes.length} bytes)';
}

/// One component of a composite glyph, decoded.
///
/// The 2×2 transform is carried as its RAW F2Dot14 words rather than as
/// doubles. That is not miserliness: the subsetter and the instancer both
/// re-emit components, and a round trip through a double and back would move
/// the last bit of a scale on some glyphs. [xxValue] and friends exist for the
/// arithmetic; [xxRaw] is what gets written.
class CompositeComponent {
  CompositeComponent({
    required this.flags,
    required this.glyphId,
    required this.arg1,
    required this.arg2,
    required this.xxRaw,
    required this.xyRaw,
    required this.yxRaw,
    required this.yyRaw,
  });

  int flags;
  int glyphId;

  /// x offset, or a point number when [argsAreXy] is false.
  int arg1;

  /// y offset, or a point number when [argsAreXy] is false.
  int arg2;

  final int xxRaw;
  final int xyRaw;
  final int yxRaw;
  final int yyRaw;

  bool get argsAreXy => flags & compArgsAreXy != 0;

  bool get hasTransform =>
      flags & (compHaveScale | compHaveXAndYScale | compHaveTwoByTwo) != 0;

  double get xxValue => xxRaw / 16384.0;
  double get xyValue => xyRaw / 16384.0;
  double get yxValue => yxRaw / 16384.0;
  double get yyValue => yyRaw / 16384.0;

  /// Bytes this component occupies once re-encoded.
  ///
  /// The args widen when an instanced offset no longer fits in a signed byte,
  /// which is why the length is computed from the CURRENT values rather than
  /// remembered from the source.
  int get encodedLength {
    var n = 4; // flags + glyphIndex
    n += _argsAreWords ? 4 : 2;
    if (flags & compHaveScale != 0) {
      n += 2;
    } else if (flags & compHaveXAndYScale != 0) {
      n += 4;
    } else if (flags & compHaveTwoByTwo != 0) {
      n += 8;
    }
    return n;
  }

  /// Whether the args must be written as words.
  ///
  /// Point numbers are UNSIGNED and offsets are SIGNED, so the two cases have
  /// different byte ranges. Widening is always legal; narrowing an already-wide
  /// record is not attempted, because a font that wrote words for a small value
  /// may be relying on the record length elsewhere.
  bool get _argsAreWords {
    if (flags & compArgsAreWords != 0) return true;
    if (argsAreXy) {
      return arg1 < -128 || arg1 > 127 || arg2 < -128 || arg2 > 127;
    }
    return arg1 < 0 || arg1 > 255 || arg2 < 0 || arg2 > 255;
  }

  void _encode(GlyphWriter w) {
    final words = _argsAreWords;
    w.uint16(words ? flags | compArgsAreWords : flags & ~compArgsAreWords);
    w.uint16(glyphId);
    if (words) {
      if (argsAreXy) {
        w.int16(arg1);
        w.int16(arg2);
      } else {
        w.uint16(arg1);
        w.uint16(arg2);
      }
    } else {
      if (argsAreXy) {
        w.int8(arg1);
        w.int8(arg2);
      } else {
        w.uint8(arg1);
        w.uint8(arg2);
      }
    }
    if (flags & compHaveScale != 0) {
      w.int16(xxRaw);
    } else if (flags & compHaveXAndYScale != 0) {
      w.int16(xxRaw);
      w.int16(yyRaw);
    } else if (flags & compHaveTwoByTwo != 0) {
      w.int16(xxRaw);
      w.int16(xyRaw);
      w.int16(yxRaw);
      w.int16(yyRaw);
    }
  }
}

/// A decoded composite glyph: its components and its trailing hinting program.
class CompositeGlyph {
  CompositeGlyph(this.components, this.instructions);

  final List<CompositeComponent> components;

  /// The instruction stream that follows the last component when
  /// `WE_HAVE_INSTRUCTIONS` is set. Empty otherwise — and it must STAY empty,
  /// or the flag and the stream disagree and a hinting rasteriser walks off the
  /// end of the glyph.
  final Uint8List instructions;

  /// Decodes the composite in [data], which is one glyph's `glyf` record.
  ///
  /// Returns null when [data] is not a composite (`numberOfContours >= 0`).
  static CompositeGlyph? parse(Uint8List data) {
    if (data.length < 10) return null;
    final r = ByteReader.fromBytes(data);
    if (r.int16At(0) >= 0) return null;

    final components = <CompositeComponent>[];
    var p = 10;
    var flags = 0;
    while (true) {
      flags = r.uint16At(p);
      final glyphId = r.uint16At(p + 2);
      p += 4;

      final int arg1;
      final int arg2;
      if (flags & compArgsAreWords != 0) {
        if (flags & compArgsAreXy != 0) {
          arg1 = r.int16At(p);
          arg2 = r.int16At(p + 2);
        } else {
          arg1 = r.uint16At(p);
          arg2 = r.uint16At(p + 2);
        }
        p += 4;
      } else {
        if (flags & compArgsAreXy != 0) {
          arg1 = r.int8At(p);
          arg2 = r.int8At(p + 1);
        } else {
          arg1 = r.uint8At(p);
          arg2 = r.uint8At(p + 1);
        }
        p += 2;
      }

      var xx = 16384;
      var xy = 0;
      var yx = 0;
      var yy = 16384;
      if (flags & compHaveScale != 0) {
        xx = yy = r.int16At(p);
        p += 2;
      } else if (flags & compHaveXAndYScale != 0) {
        xx = r.int16At(p);
        yy = r.int16At(p + 2);
        p += 4;
      } else if (flags & compHaveTwoByTwo != 0) {
        xx = r.int16At(p);
        xy = r.int16At(p + 2);
        yx = r.int16At(p + 4);
        yy = r.int16At(p + 6);
        p += 8;
      }

      components.add(
        CompositeComponent(
          flags: flags,
          glyphId: glyphId,
          arg1: arg1,
          arg2: arg2,
          xxRaw: xx,
          xyRaw: xy,
          yxRaw: yx,
          yyRaw: yy,
        ),
      );

      if (flags & compMoreComponents == 0) break;
      if (p >= data.length) {
        throw const FontFormatException(
          'composite glyph runs past its glyf record',
        );
      }
    }

    var instructions = _emptyBytes;
    if (flags & compWeHaveInstructions != 0 && p + 2 <= data.length) {
      final n = r.uint16At(p);
      p += 2;
      if (p + n <= data.length) {
        instructions = Uint8List.fromList(data.sublist(p, p + n));
      }
    }
    return CompositeGlyph(components, instructions);
  }

  /// Re-encodes the composite with [bounds] as its header box.
  ///
  /// [bounds] is `(xMin, yMin, xMax, yMax)`. A caller that has not recomputed
  /// the box passes the source glyph's own, which is what the subsetter does —
  /// it moves no points.
  Uint8List encode((int, int, int, int) bounds) {
    final w = GlyphWriter();
    w.int16(-1); // numberOfContours: negative means composite
    w.int16(bounds.$1);
    w.int16(bounds.$2);
    w.int16(bounds.$3);
    w.int16(bounds.$4);
    for (var i = 0; i < components.length; i++) {
      final c = components[i];
      // MORE_COMPONENTS and WE_HAVE_INSTRUCTIONS are authored by the ENCODER,
      // never carried over from the source: they describe what FOLLOWS this
      // record, and only the encoder knows that.
      final last = i == components.length - 1;
      final saved = c.flags;
      var f = saved & ~(compMoreComponents | compWeHaveInstructions);
      if (!last) f |= compMoreComponents;
      if (last && instructions.isNotEmpty) f |= compWeHaveInstructions;
      c.flags = f;
      c._encode(w);
      c.flags = saved;
    }
    if (instructions.isNotEmpty) {
      w.uint16(instructions.length);
      w.bytes(instructions);
    }
    return w.take();
  }
}

/// Cuts a font down to a glyph set.
class Subsetter {
  const Subsetter._();

  /// Builds a font holding only [glyphIds], their composite components, and
  /// `.notdef`.
  ///
  /// With [retainGids] the original glyph numbering is preserved — dropped
  /// glyphs become empty records rather than being renumbered away — and the
  /// subset ends at the highest retained id. That mode exists for callers that
  /// have already baked glyph ids into a content stream or a `CIDToGIDMap` and
  /// cannot renumber; it costs a `loca` entry per skipped glyph and nothing
  /// else.
  ///
  /// Throws [UnsupportedError] for a CFF face — `CFF `/`CFF2` subsetting is a
  /// different problem (charstring INDEX surgery, subroutine closure) and this
  /// engine only ever embeds `glyf` outlines.
  static FontSubset subset(
    OpenTypeFont font,
    Set<int> glyphIds, {
    bool retainGids = false,
  }) {
    final glyf = font.glyf;
    if (glyf == null) {
      throw UnsupportedError(
        'subsetting needs glyf outlines; this font is CFF-based',
      );
    }

    final kept = closure(font, glyphIds);
    final ordered = kept.toList()..sort();

    final oldToNew = <int, int>{};
    final newToOld = <int, int>{};
    final int numGlyphs;
    if (retainGids) {
      numGlyphs = ordered.last + 1;
      for (final g in ordered) {
        oldToNew[g] = g;
        newToOld[g] = g;
      }
    } else {
      numGlyphs = ordered.length;
      for (var i = 0; i < ordered.length; i++) {
        oldToNew[ordered[i]] = i;
        newToOld[i] = ordered[i];
      }
    }

    final builder = SfntBuilder();
    final glyphData = _buildGlyf(glyf, numGlyphs, newToOld, oldToNew);
    builder.setTable(Tag.glyf, glyphData.$1);
    builder.setTable(Tag.loca, glyphData.$2);
    builder.setTable(Tag.head, _head(font, longLoca: glyphData.$3));

    final metrics = _buildHmtx(font, numGlyphs, newToOld);
    builder.setTable(Tag.hmtx, metrics.$1);
    builder.setTable(Tag.hhea, _hhea(font, metrics.$2));
    builder.setTable(Tag.maxp, _maxp(font, numGlyphs));

    // Hinting tables ride along untouched. They are indexed by nothing the
    // subset renumbered — `fpgm` and `prep` are programs, `cvt ` is a table of
    // control values, `gasp` is a ppem range list — so copying them verbatim is
    // both correct and the only option: rewriting bytecode is out of scope for
    // any subsetter.
    for (final tag in const [Tag.cvt, Tag.fpgm, Tag.prep, Tag.gasp]) {
      final bytes = font.sfnt.tableBytes(tag);
      if (bytes != null) builder.setTable(tag, bytes);
    }

    return FontSubset(
      bytes: builder.build(),
      oldToNewGid: Map<int, int>.unmodifiable(oldToNew),
      newToOldGid: Map<int, int>.unmodifiable(newToOld),
      numGlyphs: numGlyphs,
    );
  }

  /// Expands [glyphIds] with every glyph they reach through composite
  /// components, to a fixed point, and always includes `.notdef`.
  ///
  /// The fixed point is not theoretical: a small-cap accented letter is a
  /// composite of a composite, so one pass would keep the accented form and
  /// still lose the accent.
  static Set<int> closure(OpenTypeFont font, Iterable<int> glyphIds) {
    final glyf = font.glyf;
    final out = <int>{0};
    final stack = <int>[0];
    for (final g in glyphIds) {
      if (g >= 0 && g < font.numGlyphs && out.add(g)) stack.add(g);
    }
    if (glyf == null) return out;
    while (stack.isNotEmpty) {
      for (final c in componentGlyphs(glyf, stack.removeLast())) {
        if (c >= 0 && c < font.numGlyphs && out.add(c)) stack.add(c);
      }
    }
    return out;
  }

  /// The glyph ids [glyphId] references directly. Empty for a simple glyph.
  static List<int> componentGlyphs(GlyfTable glyf, int glyphId) {
    final data = glyf.glyphBytes(glyphId);
    if (data == null) return const <int>[];
    final composite = CompositeGlyph.parse(data);
    if (composite == null) return const <int>[];
    return [for (final c in composite.components) c.glyphId];
  }

  // ── tables ────────────────────────────────────────────────────────────────

  /// Returns `(glyf, loca, longLoca)`.
  static (Uint8List, Uint8List, bool) _buildGlyf(
    GlyfTable glyf,
    int numGlyphs,
    Map<int, int> newToOld,
    Map<int, int> oldToNew,
  ) {
    final parts = <Uint8List>[];
    final offsets = List<int>.filled(numGlyphs + 1, 0);
    var at = 0;

    for (var gid = 0; gid < numGlyphs; gid++) {
      offsets[gid] = at;
      final old = newToOld[gid];
      // Absent in `retainGids` mode: a hole, spelled as a zero-length record.
      if (old == null) continue;
      final source = glyf.glyphBytes(old);
      if (source == null) continue; // an empty glyph, e.g. `space`

      var data = source;
      final composite = CompositeGlyph.parse(source);
      if (composite != null) {
        for (final c in composite.components) {
          final mapped = oldToNew[c.glyphId];
          if (mapped == null) {
            // Impossible after `closure`, and worth saying so out loud rather
            // than emitting a component pointing at whatever glyph happens to
            // sit at that index in the subset.
            throw StateError(
              'composite glyph $old references ${c.glyphId}, which the '
              'closure did not retain',
            );
          }
          c.glyphId = mapped;
        }
        final r = ByteReader.fromBytes(source);
        data = composite.encode((
          r.int16At(2),
          r.int16At(4),
          r.int16At(6),
          r.int16At(8),
        ));
      }

      parts.add(data);
      at += data.length;
      // Every glyph starts on an even boundary. Not cosmetic: a short `loca`
      // stores offsets HALVED, so an odd offset simply cannot be expressed, and
      // padding here is what keeps the short format available at all.
      if (at.isOdd) {
        parts.add(_onePadByte);
        at += 1;
      }
    }
    offsets[numGlyphs] = at;

    final glyfBytes = Uint8List(at);
    var cursor = 0;
    for (final part in parts) {
      glyfBytes.setRange(cursor, cursor + part.length, part);
      cursor += part.length;
    }

    // Short `loca` while the halved offsets fit a uint16 — which caps `glyf` at
    // 128 KB, and is why a full font is long and nearly every subset is short.
    final longLoca = at > 0x1FFFE;
    final locaBytes = Uint8List((numGlyphs + 1) * (longLoca ? 4 : 2));
    final locaView = ByteData.view(locaBytes.buffer);
    for (var i = 0; i <= numGlyphs; i++) {
      if (longLoca) {
        locaView.setUint32(i * 4, offsets[i]);
      } else {
        locaView.setUint16(i * 2, offsets[i] >> 1);
      }
    }
    return (glyfBytes, locaBytes, longLoca);
  }

  /// Returns `(hmtx, numberOfHMetrics)`.
  static (Uint8List, int) _buildHmtx(
    OpenTypeFont font,
    int numGlyphs,
    Map<int, int> newToOld,
  ) {
    final advances = List<int>.filled(numGlyphs, 0);
    final lsbs = List<int>.filled(numGlyphs, 0);
    for (var gid = 0; gid < numGlyphs; gid++) {
      final old = newToOld[gid];
      if (old == null) continue;
      // Through the facade, not through `hmtx` directly: on a font carrying
      // variation coords this is where `HVAR` is applied, and a subset that
      // skipped it would draw an instanced glyph at its default width.
      advances[gid] = font.advanceWidth(old);
      lsbs[gid] = font.leftSideBearing(old);
    }

    // `hmtx` compresses by letting the trailing glyphs share the last advance.
    // Worth doing even here: an Arabic subset ends in a run of marks that all
    // measure zero.
    var metrics = numGlyphs;
    while (metrics > 1 && advances[metrics - 1] == advances[metrics - 2]) {
      metrics--;
    }

    final bytes = Uint8List(metrics * 4 + (numGlyphs - metrics) * 2);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < metrics; i++) {
      view.setUint16(i * 4, advances[i].clamp(0, 0xFFFF));
      view.setInt16(i * 4 + 2, lsbs[i].clamp(-32768, 32767));
    }
    for (var i = metrics; i < numGlyphs; i++) {
      view.setInt16(
        metrics * 4 + (i - metrics) * 2,
        lsbs[i].clamp(-32768, 32767),
      );
    }
    return (bytes, metrics);
  }

  static Uint8List _head(OpenTypeFont font, {required bool longLoca}) {
    final head = _copy(font, Tag.head, 54);
    ByteData.view(head.buffer).setInt16(50, longLoca ? 1 : 0);
    // `head.xMin`…`yMax` are left as the source font's. They are a bound over
    // every glyph, and a subset's glyphs are a subset of those — so the box
    // stays valid, merely loose. Tightening it would gain nothing a rasteriser
    // reads and adds a second place to get the geometry wrong.
    return head;
  }

  static Uint8List _hhea(OpenTypeFont font, int numberOfHMetrics) {
    final hhea = _copy(font, Tag.hhea, 36);
    ByteData.view(hhea.buffer).setUint16(34, numberOfHMetrics);
    return hhea;
  }

  static Uint8List _maxp(OpenTypeFont font, int numGlyphs) {
    final maxp = _copy(font, Tag.maxp, 6);
    ByteData.view(maxp.buffer).setUint16(4, numGlyphs);
    // The remaining version 1.0 fields — maxPoints, maxComponentDepth and the
    // rest — are hinting-engine budgets, and they are left at the source
    // font's values on purpose. They are UPPER bounds: recomputing them can
    // only shrink them, which saves no bytes and risks under-declaring a limit
    // an interpreter then allocates against.
    return maxp;
  }

  /// A private, mutable copy of a source table, checked for a minimum length.
  static Uint8List _copy(OpenTypeFont font, int tag, int minimumLength) {
    final bytes = font.sfnt.tableBytes(tag);
    if (bytes == null || bytes.length < minimumLength) {
      throw FontFormatException(
        'font has no usable ${Tag(tag).asString} table to subset',
      );
    }
    return Uint8List.fromList(bytes);
  }
}

// ── composite flags ──────────────────────────────────────────────────────────
//
// Shared with the instancer, which re-encodes the same records. `glyf.dart`
// keeps its own private copies for reading; these are the writer's set and
// include the two the reader had no reason to name.

const int compArgsAreWords = 0x0001;
const int compArgsAreXy = 0x0002;
const int compHaveScale = 0x0008;
const int compMoreComponents = 0x0020;
const int compHaveXAndYScale = 0x0040;
const int compHaveTwoByTwo = 0x0080;
const int compWeHaveInstructions = 0x0100;
const int compScaledOffset = 0x0800;

final Uint8List _emptyBytes = Uint8List(0);
final Uint8List _onePadByte = Uint8List(1);

/// A growing big-endian byte sink for glyph records.
///
/// `BytesBuilder` has no big-endian int16, and a glyph record is almost nothing
/// but those. Shared with the instancer, which encodes glyph records of its own
/// and must produce byte-identical output for an unchanged glyph.
class GlyphWriter {
  final BytesBuilder _out = BytesBuilder();

  int get length => _out.length;

  void uint8(int v) => _out.addByte(v & 0xFF);

  void int8(int v) => _out.addByte(v & 0xFF);

  void uint16(int v) {
    _out.addByte((v >> 8) & 0xFF);
    _out.addByte(v & 0xFF);
  }

  void int16(int v) {
    final c = v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
    _out.addByte((c >> 8) & 0xFF);
    _out.addByte(c & 0xFF);
  }

  void bytes(Uint8List b) => _out.add(b);

  Uint8List take() => _out.toBytes();
}
