/// Composite-font embedding — a subsetted OpenType face inside a PDF as a
/// `Type0` / `CIDFontType2` pair with an `Identity-H` encoding.
///
/// This is the file that lets the shaper's output reach a page UNTRANSLATED.
/// `Identity-H` means the two-byte codes in the content stream ARE glyph
/// indices; there is no encoding vector, no character-to-glyph step, and
/// therefore nothing standing between `GSUB`'s answer and the ink. That is the
/// only arrangement in which glyph 474 — Vazirmatn's ڵ+ا ligature, which has no
/// Unicode codepoint in any block — can be drawn at all.
///
/// The object graph it emits:
///
///     Type0        /Subtype /Type0  /Encoding /Identity-H
///                  /DescendantFonts [ CIDFont ]  /ToUnicode <stream>
///     CIDFont      /Subtype /CIDFontType2  /CIDSystemInfo (Adobe/Identity/0)
///                  /DW 1000  /W [ … ]  /CIDToGIDMap /Identity
///                  /FontDescriptor <descriptor>
///     descriptor   /Flags /FontBBox /Ascent /Descent /CapHeight /StemV
///                  /FontFile2 <stream + /Length1>
///
/// Three things here fail silently rather than loudly, which is why each has a
/// comment on it below and a test behind it:
///
///  1. **A variable font cannot be embedded.** PDF has no syntax for "draw this
///     face at wght 600", so a variable program in a `FontFile2` prints at the
///     default instance on every viewer. [EmbeddedFont.finish] runs the
///     instancer first, always.
///  2. **Every metric is in 1000-unit glyph space**, not the font's own em.
///     See `font_descriptor.dart`.
///  3. **`fsType` is a licence, and this package reads it.** Embedding a font
///     whose foundry forbade it is a liability transferred to whoever ships the
///     document. Most PDF libraries do it anyway, without a word.
library;

import 'dart:typed_data';

import '../api/text_style.dart';
import '../font/instancer.dart';
import '../font/open_type_font.dart';
import '../font/subset.dart';
import 'document.dart';
import 'font_descriptor.dart';
import 'object.dart';
import 'page.dart';
import 'to_unicode.dart';

/// Thrown when a font's own `OS/2.fsType` bits forbid embedding it.
///
/// A hard failure on purpose. The alternative — dropping the font and letting a
/// reader substitute — produces a document that looks nearly right and is not
/// the document that was approved, which on a signed record is worse than no
/// document at all.
class FontEmbeddingNotPermittedException implements Exception {
  const FontEmbeddingNotPermittedException(this.fontName, this.fsType);

  /// The face, named so the message is actionable.
  final String fontName;

  /// The raw `fsType` word, so the licence can be looked up.
  final int fsType;

  @override
  String toString() =>
      'FontEmbeddingNotPermittedException: "$fontName" declares '
      'OS/2.fsType 0x${fsType.toRadixString(16).padLeft(4, '0')}, which '
      'forbids embedding it in a document. Licence a font that permits '
      'embedding, or ask the foundry.';
}

/// One face, at one variation instance, embedded once for a whole document.
class EmbeddedFont {
  EmbeddedFont._(this._document, this.font, this.resourceName, this.fontRef);

  final PdfDocument _document;

  /// The source face. Carries its variation instance with it.
  final PayvFont font;

  /// The name this font is registered under in a page's `/Font` dictionary.
  ///
  /// Allocated per DOCUMENT, not per page, so `/F2` means the same face on
  /// every page of the file — which is worth a great deal when reading a
  /// content stream by hand. See [attachTo] for the invariant that keeps it
  /// unambiguous.
  final String resourceName;

  /// The `Type0` font object. Reserved at construction so a page can reference
  /// it while it is still being drawn, and filled by [finish].
  final PdfRef fontRef;

  /// Used glyph → the codepoints it came from. Insertion-ordered, but every
  /// consumer sorts, so the output does not depend on draw order.
  final Map<int, List<int>> _codepoints = <int, List<int>>{};

  Map<int, int> _oldToNewGid = const <int, int>{};
  String _baseFont = '';
  bool _finished = false;

  /// How many distinct glyphs this face has been asked for.
  int get glyphCount => _codepoints.length;

  bool get isFinished => _finished;

  /// `/BaseFont`, with its subset tag. Empty until [finish].
  String get baseFont => _baseFont;

  /// Records that [glyphId] — an ORIGINAL, pre-subset id, exactly what the
  /// shaper produced — is drawn somewhere in this document.
  ///
  /// [codepoints] is the source cluster the glyph came from, and it is what
  /// makes the text extractable. Pass the WHOLE cluster for a ligature: glyph
  /// 474 came from ڵ followed by ا and has to map back to both, or copy-paste
  /// loses a letter. Pass an empty list for a glyph with no textual meaning.
  ///
  /// Called once per shaped glyph, so it is on the hot path and does almost
  /// nothing. The first non-empty mapping for a glyph wins; a later call with
  /// different codepoints is ignored, because a CID has exactly one entry in
  /// the `ToUnicode` CMap and re-deciding it per occurrence would make the
  /// output depend on draw order.
  void use(int glyphId, {required List<int> codepoints}) {
    if (_finished) {
      throw StateError(
        'use($glyphId) after finish() — glyph $glyphId is not in the subset '
        'that has already been written',
      );
    }
    final existing = _codepoints[glyphId];
    if (existing != null && existing.isNotEmpty) return;
    _codepoints[glyphId] = codepoints.isEmpty
        ? const <int>[]
        : List<int>.unmodifiable(codepoints.where((c) => c > 0));
  }

  /// The CID for [originalGlyphId] — its id in the FINAL subset numbering,
  /// which with `/CIDToGIDMap /Identity` is also its glyph index in the
  /// embedded program.
  ///
  /// Only meaningful after [finish], and that is not an implementation detail:
  /// the subset numbering is a function of the whole glyph set, and the whole
  /// glyph set is not known until the last page has been drawn. A caller that
  /// needs codes while drawing must buffer its runs and resolve them at save
  /// time — which is what the text engine does.
  int cidFor(int originalGlyphId) {
    if (!_finished) {
      throw StateError(
        'cidFor($originalGlyphId) before finish() — subset glyph numbering is '
        'not decided until every page has been drawn',
      );
    }
    final cid = _oldToNewGid[originalGlyphId];
    if (cid == null) {
      throw ArgumentError.value(
        originalGlyphId,
        'originalGlyphId',
        'never passed to use(), so it was not embedded',
      );
    }
    return cid;
  }

  /// [glyphIds] as the big-endian two-byte codes an `Identity-H` `Tj` wants.
  Uint8List cidBytes(Iterable<int> glyphIds) {
    final list = glyphIds.toList(growable: false);
    final out = Uint8List(list.length * 2);
    for (var i = 0; i < list.length; i++) {
      final cid = cidFor(list[i]);
      out[i * 2] = (cid >> 8) & 0xFF;
      out[i * 2 + 1] = cid & 0xFF;
    }
    return out;
  }

  /// Registers this font in [page]'s `/Font` resource dictionary and returns
  /// [resourceName].
  ///
  /// Idempotent. Note the invariant: within `payv`, the `/Font` category is
  /// owned by [CidFontEmbedder], and its names are document-wide — unlike
  /// `/XObject` and the rest, which go through `PdfPage.addResource` and are
  /// numbered per page. Mixing the two on one page would let a second `/F1`
  /// overwrite the first, so this throws rather than let that happen quietly.
  String attachTo(PdfPage page) {
    final fonts = page.resources.subDict('Font');
    final existing = fonts[resourceName];
    if (existing != null && existing != fontRef) {
      throw StateError(
        '/$resourceName on this page already points at $existing, not '
        '$fontRef — a /Font name was allocated outside CidFontEmbedder',
      );
    }
    fonts[resourceName] = fontRef;
    return resourceName;
  }

  /// Instances, subsets, and writes every object. Idempotent.
  void finish() {
    if (_finished) return;

    if (!font.canEmbedInPdf) {
      throw FontEmbeddingNotPermittedException(
        font.postScriptName ?? font.familyName ?? 'unnamed font',
        font.raw.os2?.fsType ?? 0,
      );
    }

    // Instance BEFORE subsetting. `Instancer` bakes the variation deltas into
    // `glyf` and drops `fvar`/`gvar`/`HVAR`, which is the only way a PDF can
    // carry anything but the default instance — and it must happen first,
    // because the subsetter re-encodes the same records and would otherwise
    // ship deltas that no longer have an axis to be indexed by.
    final programBytes = Instancer.instance(
      font.raw,
      font.raw.variationCoords ?? const <double>[],
    );
    final program = OpenTypeFont.parse(programBytes);

    final requested = <int>{0, ..._codepoints.keys};
    final Uint8List embeddedBytes;
    if (font.canSubset) {
      final subset = Subsetter.subset(program, requested);
      embeddedBytes = subset.bytes;
      _oldToNewGid = subset.oldToNewGid;
    } else {
      // Bit 8 of `fsType`: embedding is allowed, subsetting is not. Ship the
      // whole program, and the identity map that goes with it.
      embeddedBytes = programBytes;
      _oldToNewGid = <int, int>{for (final g in requested) g: g};
    }

    _baseFont = '${_subsetTag(requested)}+${_postScriptName()}';

    // /Length1 is the length of the UNCOMPRESSED program. The writer deflates
    // this stream later and rewrites /Length; /Length1 must keep describing
    // what comes back out of the filter, which is what it already does here.
    final fontFile = _document.writer.add(
      PdfStream(
        PdfDict(<String, PdfObject>{
          'Length1': PdfNumber(embeddedBytes.length),
        }),
        embeddedBytes,
      ),
    );

    // Metrics come from the ORIGINAL face at its variation instance, not from
    // the re-containered program: those are the numbers the layout engine
    // measured with, and a /W that disagrees with the advances already written
    // into the page is a viewer-dependent overlap.
    final descriptor = _document.writer.add(
      buildFontDescriptor(
        font: font.raw,
        baseFont: _baseFont,
        fontFile2: fontFile,
      ),
    );

    final cidFont = _document.writer.add(
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('CIDFontType2'),
        'BaseFont': PdfName(_baseFont),
        'CIDSystemInfo': PdfDict(<String, PdfObject>{
          'Registry': PdfString('Adobe'),
          'Ordering': PdfString('Identity'),
          'Supplement': const PdfNumber(0),
        }),
        'FontDescriptor': descriptor,
        'DW': const PdfNumber(_defaultWidth),
        'W': _widthArray(),
        // Identity because the CIDs above ARE the subset's glyph indices. The
        // alternative is a stream mapping one to the other, and every byte of
        // it would be a chance to disagree with the /W array beside it.
        'CIDToGIDMap': const PdfName('Identity'),
      }),
    );

    final type0 = PdfDict(<String, PdfObject>{
      'Type': const PdfName('Font'),
      'Subtype': const PdfName('Type0'),
      'BaseFont': PdfName(_baseFont),
      'Encoding': const PdfName('Identity-H'),
      'DescendantFonts': PdfArray(<PdfObject>[cidFont]),
    });

    final toUnicode = _toUnicodeStream();
    if (toUnicode != null) type0['ToUnicode'] = toUnicode;

    _document.writer.fill(fontRef, type0);
    _finished = true;
  }

  /// PDF's default glyph width for this font, in 1000-unit glyph space.
  ///
  /// 1000 — one em — is the conventional value and the one every `/W` below is
  /// measured against. Choosing the font's own most common advance would make
  /// the array smaller and would also make two documents built from the same
  /// face disagree about what a missing width means.
  static const int _defaultWidth = 1000;

  /// The `/W` array: per-CID advances, in the compact form.
  ///
  /// Two shapes are legal — `c [w1 w2 …]` for a consecutive block and
  /// `cFirst cLast w` for a run that shares one width — and mixing them is what
  /// keeps the array small. An Arabic subset is full of both: the digits are a
  /// consecutive block of differing widths, and the marks are long runs of
  /// zero. Widths equal to [_defaultWidth] are omitted entirely; they fall back
  /// to `/DW`.
  PdfArray _widthArray() {
    final upem = font.unitsPerEm;
    final cids = <int>[];
    final widths = <int>[];
    final byCid = <int, int>{};
    for (final oldGid in _codepoints.keys) {
      final cid = _oldToNewGid[oldGid];
      if (cid == null) continue;
      final width = scaleToPdfGlyphSpace(font.raw.advanceWidth(oldGid), upem);
      if (width == _defaultWidth) continue;
      byCid[cid] = width;
    }
    for (final cid in byCid.keys.toList()..sort()) {
      cids.add(cid);
      widths.add(byCid[cid]!);
    }

    // A same-width range costs three numbers whatever its length, while the
    // array entries it replaces cost one each plus the `c [ ]` framing it
    // interrupts. Four is where it starts paying.
    const minimumRun = 4;
    final array = PdfArray();
    var i = 0;
    while (i < cids.length) {
      var run = i;
      while (run + 1 < cids.length &&
          cids[run + 1] == cids[run] + 1 &&
          widths[run + 1] == widths[i]) {
        run++;
      }
      if (run - i + 1 >= minimumRun) {
        array.add(PdfNumber(cids[i]));
        array.add(PdfNumber(cids[run]));
        array.add(PdfNumber(widths[i]));
        i = run + 1;
        continue;
      }

      // Otherwise gather consecutive CIDs into one bracketed block, stopping
      // where a run long enough to be worth its own range begins.
      var end = i;
      while (end + 1 < cids.length && cids[end + 1] == cids[end] + 1) {
        var ahead = end + 1;
        while (ahead + 1 < cids.length &&
            cids[ahead + 1] == cids[ahead] + 1 &&
            widths[ahead + 1] == widths[end + 1]) {
          ahead++;
        }
        if (ahead - end >= minimumRun) break;
        end++;
      }
      array.add(PdfNumber(cids[i]));
      array.add(
        PdfArray.numbers(<num>[for (var k = i; k <= end; k++) widths[k]]),
      );
      i = end + 1;
    }
    return array;
  }

  /// The `/ToUnicode` stream, or null when nothing in this font carries text.
  PdfRef? _toUnicodeStream() {
    final byCid = <int, List<int>>{};
    for (final entry in _codepoints.entries) {
      if (entry.value.isEmpty) continue;
      final cid = _oldToNewGid[entry.key];
      if (cid == null) continue;
      byCid[cid] = entry.value;
    }
    if (byCid.isEmpty) return null;
    return _document.writer.add(
      PdfStream(PdfDict(), buildToUnicodeCMap(byCid)),
    );
  }

  /// The name under `/BaseFont`, minus the tag.
  ///
  /// PostScript names may not contain spaces or the PDF delimiter characters.
  /// `PdfName` would escape them to `#20`, which is legal and which some
  /// readers then fail to match against the descriptor's `/FontName`, so they
  /// are stripped here instead.
  String _postScriptName() {
    final raw = font.postScriptName ?? font.familyName ?? 'Font';
    final cleaned = raw.replaceAll(RegExp(r'[\s()<>\[\]{}/%#]'), '');
    return cleaned.isEmpty ? 'Font' : cleaned;
  }

  /// The six-uppercase-letter subset tag, e.g. `ABCDEF+Vazirmatn`.
  ///
  /// PDF requires the tag so a reader can tell two different subsets of one
  /// face apart instead of caching the first and drawing the rest of the
  /// document with a font that is missing half its glyphs.
  ///
  /// Derived by hash, NEVER randomly. Two builds of the same document have to
  /// produce identical bytes — that is what makes a golden test of a PDF
  /// possible and what lets a build be cached — and a random tag would make
  /// every build a different file. The variation instance is in the hash too,
  /// so the same face at wght 400 and at wght 600 cannot collide.
  String _subsetTag(Set<int> glyphIds) {
    var hash = 0x811C9DC5;
    void mix(int byte) {
      hash ^= byte & 0xFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }

    for (final unit in _postScriptName().codeUnits) {
      mix(unit);
      mix(unit >> 8);
    }
    for (final coord in font.raw.variationCoords ?? const <double>[]) {
      // Quantised to F2Dot14, the precision the font itself stores, so a
      // rounding difference upstream cannot change the tag.
      final q = (coord * 16384).round() & 0xFFFF;
      mix(q);
      mix(q >> 8);
    }
    for (final gid in glyphIds.toList()..sort()) {
      mix(gid);
      mix(gid >> 8);
      mix(gid >> 16);
    }

    final letters = List<int>.filled(6, 0);
    var value = hash;
    for (var i = 5; i >= 0; i--) {
      letters[i] = 0x41 + value % 26; // 'A'
      value ~/= 26;
    }
    return String.fromCharCodes(letters);
  }

  @override
  String toString() =>
      'EmbeddedFont($resourceName, ${_baseFont.isEmpty ? font : _baseFont}, '
      '${_codepoints.length} glyphs${_finished ? "" : ", unfinished"})';
}

/// Owns every embedded face in one document.
///
/// One [EmbeddedFont] per (face, variation instance): a face used on forty
/// pages is embedded ONCE, carrying the union of the glyphs those pages drew.
/// That is not a size optimisation so much as a correctness one — forty copies
/// of a subset are forty chances for a reader to pick the wrong one for a page.
///
/// Two instances of the same face — Regular and SemiBold off one variable
/// file — are two entries, because they are two different font programs by the
/// time PDF sees them.
class CidFontEmbedder {
  CidFontEmbedder(this.document);

  final PdfDocument document;

  final Map<_FaceKey, EmbeddedFont> _fonts = <_FaceKey, EmbeddedFont>{};

  /// Every face embedded so far, in the order they were first used.
  Iterable<EmbeddedFont> get fonts => _fonts.values;

  /// The embedded font for [font], creating it on first use.
  EmbeddedFont fontFor(PayvFont font) {
    final key = _FaceKey.of(font);
    final existing = _fonts[key];
    if (existing != null) return existing;
    final made = EmbeddedFont._(
      document,
      font,
      'F${_fonts.length + 1}',
      document.writer.reserve(),
    );
    _fonts[key] = made;
    return made;
  }

  /// Writes every font. Called once, from the document's save path.
  void finishAll() {
    for (final font in _fonts.values) {
      font.finish();
    }
  }
}

/// Identity of a face at an instance.
///
/// The face half is the identity of the parsed `SfntFile`, not a hash of its
/// bytes: `PayvFont.variation()` builds a new wrapper over the SAME parsed
/// file, so every instance of one loaded font shares it, and hashing 400 KB per
/// text run to learn the same thing would be absurd. The consequence, and it is
/// deliberate: loading the same file twice produces two embeddings. Load once.
class _FaceKey {
  _FaceKey(this.faceIdentity, this.coords);

  factory _FaceKey.of(PayvFont font) => _FaceKey(
    identityHashCode(font.raw.sfnt),
    List<double>.unmodifiable(font.raw.variationCoords ?? const <double>[]),
  );

  final int faceIdentity;
  final List<double> coords;

  @override
  bool operator ==(Object other) {
    if (other is! _FaceKey) return false;
    if (other.faceIdentity != faceIdentity) return false;
    if (other.coords.length != coords.length) return false;
    for (var i = 0; i < coords.length; i++) {
      if (other.coords[i] != coords[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = faceIdentity;
    for (final c in coords) {
      h = (h * 31 + c.hashCode) & 0x3FFFFFFF;
    }
    return h;
  }
}
