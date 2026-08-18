/// CIDFontType2 / Identity-H embedding, against the real face.
///
/// Everything asserted here fails SILENTLY in a viewer. A `/W` array built in
/// the font's own 2048-unit em still draws every glyph — a few percent too
/// wide, cumulatively, so the last word of a justified line creeps out of the
/// column. A missing `/Length1` opens fine in Preview and fails in a print RIP.
/// A `ToUnicode` entry that lists one codepoint of a two-letter ligature prints
/// perfectly and loses a letter when someone copies their own address out.
/// None of them throw, so the test has to read the bytes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/api/text_style.dart';
import 'package:payv/src/font/open_type_font.dart';
import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/pdf/cid_font.dart';
import 'package:payv/src/pdf/document.dart';
import 'package:payv/src/pdf/font_descriptor.dart';
import 'package:payv/src/pdf/object.dart';
import 'package:payv/src/pdf/to_unicode.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// Same override every other test in the package uses.
final String fontPath =
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf';

/// ڵ + ا. A ligature with no Unicode codepoint of its own, which is the case
/// the whole `ToUnicode` half of this file exists for.
const int gidLamVAboveAlef = 474;
const int cpLamV = 0x06B5; // ڵ
const int cpAlef = 0x0627; // ا

/// A block of Vazirmatn glyphs that all share one advance (zero — they are
/// marks). The `/W` compaction is supposed to collapse these into a single
/// `cFirst cLast w` triple rather than list twenty-four numbers.
const int gidZeroWidthFirst = 724;
const int gidZeroWidthLast = 747;

void main() {
  late Uint8List fontBytes;
  late OpenTypeFont face;

  setUpAll(() {
    fontBytes = File(fontPath).readAsBytesSync();
    face = OpenTypeFont.parse(fontBytes);
    // Pin the fixture. Every glyph id here is Vazirmatn's.
    expect(face.numGlyphs, 1333, reason: 'fixture font changed');
    expect(
      face.unitsPerEm,
      2048,
      reason: 'the 1000-em scaling tests need this',
    );
    expect(face.isVariable, isTrue, reason: 'the instancing test needs this');
  });

  // ── the object graph ───────────────────────────────────────────────────────

  group('the embedded font graph', () {
    late _Embedded built;

    setUpAll(() {
      built = _build(fontBytes, _kurdishGlyphs(face)..add(gidLamVAboveAlef));
    });

    test('the Type0 font is an Identity-H composite with a ToUnicode CMap', () {
      final type0 = built.objectContaining('/Subtype /Type0');
      expect(type0, contains('/Type /Font'));
      expect(type0, contains('/Encoding /Identity-H'));
      expect(
        type0,
        matches(RegExp(r'/BaseFont /[A-Z]{6}\+')),
        reason: 'BaseFont needs a six-letter subset tag',
      );
      expect(
        type0,
        matches(RegExp(r'/DescendantFonts \[\d+ 0 R\]')),
        reason: 'exactly one descendant, by indirect reference',
      );
      expect(
        type0,
        matches(RegExp(r'/ToUnicode \d+ 0 R')),
        reason: 'without this the page is unreadable back out',
      );
    });

    test('the descendant is a CIDFontType2 over Adobe-Identity-0', () {
      final cid = built.objectContaining('/Subtype /CIDFontType2');
      expect(cid, contains('/Type /Font'));
      expect(
        cid,
        contains(
          '/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) '
          '/Supplement 0>>',
        ),
      );
      expect(cid, contains('/DW 1000'));
      expect(
        cid,
        contains('/CIDToGIDMap /Identity'),
        reason: 'the CIDs ARE the subset glyph indices',
      );
      expect(cid, matches(RegExp(r'/FontDescriptor \d+ 0 R')));
      // The BaseFont on both dictionaries must agree exactly, tag included.
      expect(cid, contains('/BaseFont /${built.baseFont}'));
    });

    test('the descriptor is Symbolic and never Nonsymbolic', () {
      final descriptor = built.objectContaining('/Type /FontDescriptor');
      final flags = int.parse(
        RegExp(r'/Flags (\d+)').firstMatch(descriptor)!.group(1)!,
      );
      expect(
        flags & PdfFontFlags.symbolic,
        PdfFontFlags.symbolic,
        reason: 'an Identity encoding is not StandardEncoding',
      );
      expect(
        flags & PdfFontFlags.nonsymbolic,
        0,
        reason: 'Symbolic and Nonsymbolic are mutually exclusive',
      );
      expect(descriptor, contains('/FontName /${built.baseFont}'));
      expect(descriptor, matches(RegExp(r'/FontFile2 \d+ 0 R')));
    });

    test('every descriptor metric is in 1000-unit glyph space, not 2048', () {
      final descriptor = built.objectContaining('/Type /FontDescriptor');
      int value(String key) =>
          int.parse(RegExp('/$key (-?\\d+)').firstMatch(descriptor)!.group(1)!);

      final os2 = face.os2!;
      final upem = face.unitsPerEm;
      expect(value('Ascent'), scaleToPdfGlyphSpace(os2.sTypoAscender, upem));
      expect(value('Descent'), scaleToPdfGlyphSpace(os2.sTypoDescender, upem));
      expect(value('CapHeight'), scaleToPdfGlyphSpace(os2.sCapHeight, upem));
      expect(value('XHeight'), scaleToPdfGlyphSpace(os2.sxHeight, upem));
      expect(
        value('Descent'),
        lessThan(0),
        reason: 'PDF wants the descent negative; usWinDescent is positive',
      );

      final bbox = RegExp(
        r'/FontBBox \[(-?\d+) (-?\d+) (-?\d+) (-?\d+)\]',
      ).firstMatch(descriptor)!;
      expect(
        int.parse(bbox.group(1)!),
        scaleToPdfGlyphSpace(face.head.xMin, upem),
      );
      expect(
        int.parse(bbox.group(2)!),
        scaleToPdfGlyphSpace(face.head.yMin, upem),
      );
      expect(
        int.parse(bbox.group(3)!),
        scaleToPdfGlyphSpace(face.head.xMax, upem),
      );
      expect(
        int.parse(bbox.group(4)!),
        scaleToPdfGlyphSpace(face.head.yMax, upem),
      );

      // The whole point: the unscaled numbers must NOT appear.
      expect(value('Ascent'), isNot(os2.sTypoAscender));
      expect(value('Ascent'), lessThan(1200));
    });

    test('StemV is a 1000-em estimate and is never scaled a second time', () {
      final descriptor = built.objectContaining('/Type /FontDescriptor');
      final stemV = int.parse(
        RegExp(r'/StemV (\d+)').firstMatch(descriptor)!.group(1)!,
      );
      expect(stemV, estimateStemV(face.os2!.usWeightClass));
      // Scaling a 1000-space value by 1000/2048 would roughly halve it, and
      // 88 → 43 is the exact shape of that bug.
      expect(stemV, greaterThan(60));
    });
  });

  // ── /W ─────────────────────────────────────────────────────────────────────

  group('the /W array', () {
    test('every entry matches hmtx scaled to a 1000-unit em', () {
      final glyphs = _kurdishGlyphs(face)..add(gidLamVAboveAlef);
      final built = _build(fontBytes, glyphs);
      final widths = built.widths();

      for (final gid in glyphs) {
        final expected = scaleToPdfGlyphSpace(
          face.advanceWidth(gid),
          face.unitsPerEm,
        );
        final actual = widths[built.font.cidFor(gid)] ?? 1000;
        expect(
          actual,
          expected,
          reason: 'glyph $gid advance ${face.advanceWidth(gid)}/2048',
        );
      }
    });

    test('a width equal to /DW is omitted rather than written out', () {
      // Vazirmatn has no glyph a full em wide, so one is made: glyph 1's
      // advance is rewritten to 2048 design units, which is exactly 1000 in
      // PDF glyph space and therefore exactly /DW.
      const fullEm = 1;
      final patched = _withAdvance(fontBytes, fullEm, 2048);
      final built = _build(patched, {fullEm, gidLamVAboveAlef});
      final widths = built.widths();

      expect(
        widths.containsKey(built.font.cidFor(fullEm)),
        isFalse,
        reason: 'a width equal to /DW is dead weight in every invoice',
      );
      expect(
        widths.containsKey(built.font.cidFor(gidLamVAboveAlef)),
        isTrue,
        reason: 'the other glyph still has to be there',
      );
      expect(widths.values, isNot(contains(1000)));
    });

    test('a run of equal widths collapses into a cFirst cLast w range', () {
      final glyphs = <int>{
        for (var g = gidZeroWidthFirst; g <= gidZeroWidthLast; g++) g,
      };
      for (final g in glyphs) {
        expect(face.advanceWidth(g), 0, reason: 'fixture glyph $g moved');
      }

      final built = _build(fontBytes, glyphs);
      expect(
        built.widthRanges(),
        isNotEmpty,
        reason: '24 identical widths must not be written as 24 numbers',
      );
      // And it still has to be correct: every one of them reads back as 0.
      final widths = built.widths();
      for (final g in glyphs) {
        expect(widths[built.font.cidFor(g)], 0);
      }
    });

    test('a 400-glyph subset round-trips through both shapes at once', () {
      // The compaction interleaves `c [w…]` blocks and `cFirst cLast w` runs,
      // and the place it can go wrong is the boundary between them — one CID
      // dropped there is one glyph drawn at 1000 units instead of its own
      // width, which nothing reports. A subset this size hits every boundary.
      final glyphs = <int>{for (var g = 1; g < face.numGlyphs; g += 3) g};
      final built = _build(fontBytes, glyphs);
      final widths = built.widths();

      for (final gid in glyphs) {
        expect(
          widths[built.font.cidFor(gid)] ?? 1000,
          scaleToPdfGlyphSpace(face.advanceWidth(gid), face.unitsPerEm),
          reason: 'glyph $gid',
        );
      }
      expect(
        built.widthRanges(),
        isNotEmpty,
        reason: 'no range at all means the compaction never fired',
      );
    });
  });

  // ── the embedded program ───────────────────────────────────────────────────

  group('the FontFile2 stream', () {
    test('/Length1 is the length of the uncompressed program', () {
      final built = _build(fontBytes, _kurdishGlyphs(face));
      expect(built.length1, built.program.length);
      expect(
        built.program.length,
        lessThan(fontBytes.length),
        reason: 'a subset that is not smaller is not a subset',
      );
    });

    test('the program is a real sfnt a reader can parse by glyph index', () {
      final built = _build(fontBytes, _kurdishGlyphs(face));
      final embedded = OpenTypeFont.parse(built.program);
      expect(embedded.unitsPerEm, face.unitsPerEm);
      // Every CID must be addressable in it — that is what /CIDToGIDMap
      // /Identity promises the reader.
      for (final gid in _kurdishGlyphs(face)) {
        expect(built.font.cidFor(gid), lessThan(embedded.numGlyphs));
      }
    });

    test('a variable face is instanced before it is embedded', () {
      final built = _build(fontBytes, _kurdishGlyphs(face));
      final embedded = SfntFile.parse(built.program);
      // PDF has no syntax for "draw this face at wght 600". A variable program
      // in a FontFile2 prints the default instance on every viewer, silently.
      expect(
        embedded.has(Tag.fvar),
        isFalse,
        reason: 'fvar survived embedding',
      );
      expect(
        embedded.has(Tag.gvar),
        isFalse,
        reason: 'gvar survived embedding',
      );
      expect(
        embedded.has(Tag.hvar),
        isFalse,
        reason: 'HVAR survived embedding',
      );
    });

    test('two instances of one face are embedded separately', () {
      final regular = PayvFont.load(fontBytes);
      final semibold = regular.weight(600);
      expect(semibold.raw.variationCoords, isNotNull);

      final document = PdfDocument(compress: false);
      document.addPage();
      final embedder = CidFontEmbedder(document);
      final a = embedder.fontFor(regular);
      final b = embedder.fontFor(semibold);

      expect(identical(a, b), isFalse);
      expect(a.resourceName, isNot(b.resourceName));
      expect(identical(embedder.fontFor(regular), a), isTrue);

      a.use(gidLamVAboveAlef, codepoints: const [cpLamV, cpAlef]);
      b.use(gidLamVAboveAlef, codepoints: const [cpLamV, cpAlef]);
      embedder.finishAll();
      expect(
        a.baseFont,
        isNot(b.baseFont),
        reason: 'the tag has to separate two instances of the same face',
      );
    });
  });

  // ── the subset tag ─────────────────────────────────────────────────────────

  group('the subset tag', () {
    test('is exactly six uppercase letters', () {
      final built = _build(fontBytes, _kurdishGlyphs(face));
      expect(built.baseFont, matches(RegExp(r'^[A-Z]{6}\+[A-Za-z0-9\-]+$')));
    });

    test('is stable — the same document builds to the same bytes twice', () {
      final glyphs = _kurdishGlyphs(face)..add(gidLamVAboveAlef);
      final first = _build(fontBytes, glyphs);
      final second = _build(fontBytes, glyphs);
      expect(second.baseFont, first.baseFont);
      expect(
        second.bytes,
        orderedEquals(first.bytes),
        reason: 'a random tag would make every build a different file',
      );
    });

    test('changes when the glyph set changes', () {
      final a = _build(fontBytes, _kurdishGlyphs(face));
      final b = _build(fontBytes, _kurdishGlyphs(face)..add(gidLamVAboveAlef));
      expect(b.baseFont, isNot(a.baseFont));
    });
  });

  // ── ToUnicode ──────────────────────────────────────────────────────────────

  group('the ToUnicode CMap', () {
    test('a ligature CID maps back to BOTH of its codepoints', () {
      final built = _build(fontBytes, {gidLamVAboveAlef});
      final cid = built.font.cidFor(gidLamVAboveAlef);
      final cmap = built.toUnicode();
      expect(
        cmap,
        contains(
          '<${cid.toRadixString(16).toUpperCase().padLeft(4, '0')}> '
          '<06B50627>',
        ),
        reason: 'ڵ+ا has no codepoint; losing one letter here is silent',
      );
    });

    test('has the preamble and codespace range every reader looks for', () {
      final built = _build(fontBytes, _kurdishGlyphs(face));
      final cmap = built.toUnicode();
      expect(cmap, contains('/CIDInit /ProcSet findresource begin'));
      expect(cmap, contains('/CMapName /Adobe-Identity-UCS def'));
      expect(cmap, contains('/CMapType 2 def'));
      expect(cmap, contains('1 begincodespacerange\n<0000> <FFFF>'));
      expect(cmap, contains('endcmap'));
    });

    test('never writes a section longer than 100 entries', () {
      // 300 singleton mappings, deliberately non-consecutive so none of them
      // can be collapsed into a bfrange.
      final map = <int, List<int>>{
        for (var i = 0; i < 300; i++) 1 + i * 3: <int>[0x41 + (i % 26)],
      };
      final cmap = latin1.decode(buildToUnicodeCMap(map));
      final counts = RegExp(
        r'(\d+) beginbf(char|range)',
      ).allMatches(cmap).map((m) => int.parse(m.group(1)!)).toList();
      expect(counts, isNotEmpty);
      expect(counts.every((c) => c <= 100), isTrue, reason: '$counts');
      expect(counts.reduce((a, b) => a + b), 300);
      // And the declared count has to match what actually follows it.
      for (final section in RegExp(
        r'(\d+) beginbfchar\n([\s\S]*?)endbfchar',
      ).allMatches(cmap)) {
        expect(
          section.group(2)!.trim().split('\n').length,
          int.parse(section.group(1)!),
        );
      }
    });

    test('collapses a consecutive run into a bfrange', () {
      final map = <int, List<int>>{
        for (var i = 0; i < 10; i++) 100 + i: <int>[0x0660 + i],
      };
      final cmap = latin1.decode(buildToUnicodeCMap(map));
      expect(cmap, contains('<0064> <006D> <0660>'));
    });

    test('never lets a bfrange carry past the low byte', () {
      // 0x00FF → 0x0100 is a carry the format cannot express: a bfrange
      // increments the LAST byte of its destination only.
      final map = <int, List<int>>{
        for (var i = 0; i < 8; i++) 10 + i: <int>[0x00FC + i],
      };
      final cmap = latin1.decode(buildToUnicodeCMap(map));
      for (final range in RegExp(
        r'<([0-9A-F]{4})> <([0-9A-F]{4})> <([0-9A-F]{4})>',
      ).allMatches(cmap)) {
        final span =
            int.parse(range.group(2)!, radix: 16) -
            int.parse(range.group(1)!, radix: 16);
        final low = int.parse(range.group(3)!, radix: 16) & 0xFF;
        expect(low + span, lessThanOrEqualTo(0xFF));
      }
    });

    test('writes a supplementary codepoint as a surrogate pair', () {
      final cmap = latin1.decode(
        buildToUnicodeCMap(<int, List<int>>{
          7: <int>[0x1F600],
        }),
      );
      expect(cmap, contains('<0007> <D83DDE00>'));
    });

    test('drops CID 0 — .notdef is not a character', () {
      final cmap = latin1.decode(
        buildToUnicodeCMap(<int, List<int>>{
          0: <int>[0x41],
          1: <int>[0x42],
        }),
      );
      expect(cmap, contains('<0001> <0042>'));
      expect(cmap, isNot(contains('<0000> <0041>')));
    });
  });

  // ── the licence gate ───────────────────────────────────────────────────────

  group('the embedding licence', () {
    test('a font whose fsType forbids embedding is refused by name', () {
      final restricted = _withFsType(fontBytes, 0x0002);
      expect(OpenTypeFont.parse(restricted).os2!.fsType, 0x0002);

      final font = PayvFont.load(restricted);
      expect(font.canEmbedInPdf, isFalse);

      final document = PdfDocument(compress: false);
      document.addPage();
      final embedder = CidFontEmbedder(document);
      final embedded = embedder.fontFor(font)
        ..use(gidLamVAboveAlef, codepoints: const [cpLamV, cpAlef]);

      expect(
        embedded.finish,
        throwsA(
          isA<FontEmbeddingNotPermittedException>()
              .having((e) => e.fontName, 'fontName', contains('Vazirmatn'))
              .having((e) => e.fsType, 'fsType', 0x0002),
        ),
      );
    });

    test('bitmap-only embedding is refused too — we embed outlines', () {
      final font = PayvFont.load(_withFsType(fontBytes, 0x0200));
      expect(font.canEmbedInPdf, isFalse);
    });

    test(
      'preview-and-print is permitted; it constrains the reader, not us',
      () {
        final font = PayvFont.load(_withFsType(fontBytes, 0x0004));
        expect(font.canEmbedInPdf, isTrue);
      },
    );
  });

  // ── sequencing ─────────────────────────────────────────────────────────────

  group('the embedder contract', () {
    test('cidFor before finish says why rather than guessing', () {
      final document = PdfDocument(compress: false);
      document.addPage();
      final embedded = CidFontEmbedder(document).fontFor(
        PayvFont.load(fontBytes),
      )..use(gidLamVAboveAlef, codepoints: const [cpLamV, cpAlef]);
      expect(() => embedded.cidFor(gidLamVAboveAlef), throwsStateError);
    });

    test('use after finish throws rather than silently dropping a glyph', () {
      final built = _build(fontBytes, {gidLamVAboveAlef});
      expect(
        () => built.font.use(5, codepoints: const [0x41]),
        throwsStateError,
      );
    });

    test('cidFor rejects a glyph that was never used', () {
      final built = _build(fontBytes, {gidLamVAboveAlef});
      expect(() => built.font.cidFor(1200), throwsArgumentError);
    });

    test('finish is idempotent — a second call writes nothing new', () {
      final document = PdfDocument(compress: false);
      document.addPage();
      final embedder = CidFontEmbedder(document);
      embedder.fontFor(PayvFont.load(fontBytes))
        ..use(gidLamVAboveAlef, codepoints: const [cpLamV, cpAlef])
        ..finish();
      final after = document.writer.objectCount;
      embedder.finishAll();
      expect(document.writer.objectCount, after);
    });

    test('attachTo names the font the same way on every page', () {
      final document = PdfDocument(compress: false);
      final first = document.addPage();
      final second = document.addPage();
      final embedded = CidFontEmbedder(
        document,
      ).fontFor(PayvFont.load(fontBytes));
      expect(embedded.attachTo(first), embedded.resourceName);
      expect(embedded.attachTo(second), embedded.resourceName);
      // Idempotent per page: two calls must not grow /Font a second entry.
      expect(embedded.attachTo(first), embedded.resourceName);
      expect((first.resources['Font']! as PdfDict).entries, hasLength(1));
    });

    test('cidBytes are two bytes big-endian, ready for a Tj', () {
      final built = _build(fontBytes, {gidLamVAboveAlef});
      final cid = built.font.cidFor(gidLamVAboveAlef);
      expect(
        built.font.cidBytes([gidLamVAboveAlef]),
        orderedEquals(<int>[(cid >> 8) & 0xFF, cid & 0xFF]),
      );
    });
  });
}

// ── harness ──────────────────────────────────────────────────────────────────

/// The glyphs a Kurdish line actually draws, straight out of the cmap.
Set<int> _kurdishGlyphs(OpenTypeFont font) {
  const text = 'ڕێگای وڵاتەکە لە هەرێمی کوردستان ٢٠٢٦';
  return <int>{
    for (final scalar in text.runes)
      if (font.glyphForCodepoint(scalar) != 0) font.glyphForCodepoint(scalar),
  };
}

/// A one-page document with [glyphs] embedded, plus the readers this file needs.
class _Embedded {
  _Embedded(this.font, this.bytes) : text = latin1.decode(bytes);

  final EmbeddedFont font;
  final Uint8List bytes;

  /// The file as one byte-per-character string, so a string index is also a
  /// byte offset into [bytes] — which is how [program] slices the font out.
  final String text;

  String get baseFont => font.baseFont;

  /// The body of the indirect object containing [marker].
  String objectContaining(String marker) {
    final at = text.indexOf(marker);
    expect(at, isNot(-1), reason: 'no object contains "$marker"');
    final start = text.lastIndexOf(' obj\n', at) + ' obj\n'.length;
    final end = text.indexOf('\nendobj', at);
    expect(end, greaterThan(start));
    return text.substring(start, end);
  }

  int get length1 =>
      int.parse(RegExp(r'/Length1 (\d+)').firstMatch(text)!.group(1)!);

  /// The embedded font program. The document is built uncompressed, so the
  /// stream bytes are the program itself.
  Uint8List get program {
    final at = text.indexOf('/Length1 ');
    final length = int.parse(
      RegExp(r'/Length (\d+)').firstMatch(text.substring(at))!.group(1)!,
    );
    final start = text.indexOf('stream\n', at) + 'stream\n'.length;
    return Uint8List.sublistView(bytes, start, start + length);
  }

  String toUnicode() {
    final at = text.indexOf('/CIDInit /ProcSet findresource begin');
    expect(at, isNot(-1), reason: 'no ToUnicode CMap in the file');
    return text.substring(at, text.indexOf('\nendstream', at));
  }

  /// The raw tokens of `/W`, with the brackets kept.
  List<String> _widthTokens() {
    final cid = objectContaining('/Subtype /CIDFontType2');
    final open = cid.indexOf('/W [');
    expect(open, isNot(-1));
    var depth = 0;
    var end = open + 3;
    for (var i = open + 3; i < cid.length; i++) {
      if (cid[i] == '[') depth++;
      if (cid[i] == ']') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    return cid
        .substring(open + 4, end)
        .replaceAll('[', ' [ ')
        .replaceAll(']', ' ] ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// `/W` decoded to CID → width, exercising both of its legal shapes.
  Map<int, int> widths() {
    final tokens = _widthTokens();
    final out = <int, int>{};
    var i = 0;
    while (i < tokens.length) {
      final first = int.parse(tokens[i]);
      if (tokens[i + 1] == '[') {
        var cid = first;
        var j = i + 2;
        while (tokens[j] != ']') {
          out[cid++] = int.parse(tokens[j++]);
        }
        i = j + 1;
      } else {
        final last = int.parse(tokens[i + 1]);
        final width = int.parse(tokens[i + 2]);
        for (var c = first; c <= last; c++) {
          out[c] = width;
        }
        i += 3;
      }
    }
    return out;
  }

  /// The `cFirst cLast w` triples in `/W`.
  List<List<int>> widthRanges() {
    final tokens = _widthTokens();
    final out = <List<int>>[];
    var i = 0;
    while (i < tokens.length) {
      if (tokens[i + 1] == '[') {
        i = tokens.indexOf(']', i + 2) + 1;
      } else {
        out.add([
          int.parse(tokens[i]),
          int.parse(tokens[i + 1]),
          int.parse(tokens[i + 2]),
        ]);
        i += 3;
      }
    }
    return out;
  }
}

/// Builds a one-page document embedding [glyphs], uncompressed so the test can
/// read the dictionaries the way a reader would.
_Embedded _build(Uint8List fontBytes, Set<int> glyphs) {
  final document = PdfDocument(compress: false);
  final page = document.addPage();
  final embedder = CidFontEmbedder(document);
  final embedded = embedder.fontFor(PayvFont.load(fontBytes));
  embedded.attachTo(page);

  for (final gid in glyphs.toList()..sort()) {
    embedded.use(
      gid,
      codepoints: gid == gidLamVAboveAlef
          ? const <int>[cpLamV, cpAlef]
          : <int>[_anyCodepointFor(fontBytes, gid)],
    );
  }
  embedder.finishAll();

  page.content
    ..beginText()
    ..setFontRaw(embedded.resourceName, 12)
    ..setTextMatrix(1, 0, 0, 1, 40, 700)
    ..showTextRaw(embedded.cidBytes(glyphs.toList()..sort()))
    ..endText();

  return _Embedded(embedded, document.save());
}

/// A codepoint that maps to [gid], or the glyph id itself as a stand-in when
/// the glyph has none — this is only feeding the `ToUnicode` map, and the
/// tests that care about the value supply their own.
final Map<int, int> _reverseCmap = <int, int>{};
int _anyCodepointFor(Uint8List fontBytes, int gid) {
  if (_reverseCmap.isEmpty) {
    final font = OpenTypeFont.parse(fontBytes);
    for (var cp = 0x20; cp <= 0x2FFF; cp++) {
      final g = font.glyphForCodepoint(cp);
      if (g != 0) _reverseCmap.putIfAbsent(g, () => cp);
    }
  }
  return _reverseCmap[gid] ?? 0x41;
}

/// A copy of [bytes] with `OS/2.fsType` rewritten to [fsType].
///
/// Byte surgery rather than a second fixture font: the point is to test OUR
/// refusal, and shipping a deliberately restricted font in a repository is a
/// worse idea than patching two bytes here.
Uint8List _withFsType(Uint8List bytes, int fsType) {
  final out = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(out);
  view.setUint16(_tableOffset(view, Tag.os2) + 8, fsType);
  return out;
}

/// A copy of [bytes] with [gid]'s `hmtx` advance rewritten.
///
/// Vazirmatn has no glyph exactly one em wide, and the `/DW` omission rule
/// needs one. Faking it here beats asserting a rule the fixture cannot trigger,
/// which is a test that passes whether or not the rule is implemented.
Uint8List _withAdvance(Uint8List bytes, int gid, int advance) {
  final out = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(out);
  final numberOfHMetrics = view.getUint16(_tableOffset(view, Tag.hhea) + 34);
  expect(
    gid,
    lessThan(numberOfHMetrics),
    reason: 'glyph $gid has no long metric',
  );
  view.setUint16(_tableOffset(view, Tag.hmtx) + gid * 4, advance);
  return out;
}

int _tableOffset(ByteData view, int tag) {
  final numTables = view.getUint16(4);
  for (var i = 0; i < numTables; i++) {
    final record = 12 + i * 16;
    if (view.getUint32(record) == tag) return view.getUint32(record + 8);
  }
  fail('the fixture font has no ${Tag(tag).asString} table');
}
