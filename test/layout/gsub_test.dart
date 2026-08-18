// GSUB, graded against Vazirmatn's real lookups and against hand-built bytes.
//
// The three font-driven assertions in `the package's thesis` are the reason
// this package exists. gid 839 (`uni06B5.init`), gid 896 (`uni06D5.fina`) and
// gid 474 (`lamVabove_alef.isol`) are glyphs no cmap can reach in any font —
// U+06B5, U+06D5 and the ڵ+ا ligature have no Unicode presentation forms. They
// come out of a `GSUB` lookup or they do not come out at all.
//
// They are made non-tautological by asserting the BEFORE state as well: the
// buffer is seeded through the cmap, checked to hold the plain letters, and
// only then run through the lookups the font's own feature table names. No
// lookup index is hardcoded.
//
// The synthetic half covers the lookup types Vazirmatn happens not to ship —
// Multiple, Alternate, Context and Reverse Chaining — plus the two rules that
// fail SILENTLY when they are wrong: backtrack arrays are nearest-first, and a
// SequenceLookupRecord's sequenceIndex counts non-skipped positions.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/tables/cmap.dart';
import 'package:payv/src/layout/common.dart';
import 'package:payv/src/layout/gsub.dart';
import 'package:payv/src/layout/gsub_subtables.dart';
import 'package:payv/src/shaping/glyph_buffer.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

// Glyph ids from `test/fixtures/harfbuzz_golden.json` — HarfBuzz's answers for
// this exact font, not anything this engine derived.
const int gidLamV = 837; // uni06B5   ڵ, straight out of the cmap
const int gidLamVInit = 839; // uni06B5.init   GSUB-only
const int gidLamVMedi = 840; // uni06B5.medi   GSUB-only
const int gidLamVFina = 838; // uni06B5.fina   GSUB-only
const int gidAe = 895; // uni06D5   ە
const int gidAeFina = 896; // uni06D5.fina   GSUB-only
const int gidAlef = 681; // uni0627   ا
const int gidAlefFina = 1173; // uniFE8E
const int gidLamVAlef = 474; // lamVabove_alef.isol   no codepoint, anywhere
const int gidTehMedi = 1188; // uniFE98
const int gidTehMediLong = 1189; // uniFE98.long   contextual alternate
const int gidShadda = 732; // uni0651, a combining mark

/// The single mask bit every test drives features with. Which bit it is does
/// not matter — that a glyph without it is untouched does, and
/// `only the masked glyphs are substituted` pins it.
const int kMask = 0x1;

void main() {
  final fontFile = File(
    Platform.environment['PAYV_TEST_FONT'] ?? 'test/fonts/Vazirmatn.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('test font not found at ${fontFile.path}');
  }
  final sfnt = SfntFile.parse(fontFile.readAsBytesSync());
  final gsub = GsubTable.parse(sfnt.requireTable(Tag.gsub));
  final gdef = GdefTable.parse(sfnt.requireTable(Tag.gdef));
  final cmap = CmapTable.parse(sfnt.requireTable(Tag.cmap));

  /// Lookup indices the font itself names for [feature] under `arab`.
  List<int> lookupsOf(int feature) => gsub.layout.lookupsFor(
    script: Tag.arab,
    language: Tag.dflt,
    features: <int>{feature},
  );

  /// Seeds a buffer the way the shaper does: cmap glyphs, GDEF classes, no
  /// substitutions yet.
  GlyphBuffer seed(String text) {
    final buffer = GlyphBuffer()..direction = TextDirection.rtl;
    buffer.addCodepoints(text.runes.toList());
    for (final info in buffer.infos) {
      info.glyphId = cmap.lookup(info.codepoint);
      info.glyphClass = gdef.glyphClass(info.glyphId);
      info.markAttachClass = gdef.markAttachClass(info.glyphId);
    }
    return buffer;
  }

  /// Runs every lookup of [feature] over [buffer], with the feature bit set on
  /// the buffer positions in [at] (null = the whole buffer).
  ///
  /// This is exactly what the Arabic shaper does — it decides the joining
  /// position of each letter, sets one of the four bits, and lets GSUB run.
  /// Here the positions are stated by hand so the test is about GSUB, not
  /// about the joining state machine.
  bool applyFeature(GlyphBuffer buffer, int feature, {Set<int>? at}) {
    for (var i = 0; i < buffer.length; i++) {
      buffer.infos[i].mask = at == null || at.contains(i) ? kMask : 0;
    }
    var changed = false;
    for (final lookup in lookupsOf(feature)) {
      changed |= gsub.applyLookup(lookup, buffer, mask: kMask, gdef: gdef);
    }
    return changed;
  }

  List<int> gids(GlyphBuffer b) => [for (final i in b.infos) i.glyphId];

  group("the package's thesis, executed against Vazirmatn", () {
    test('init reaches uni06B5.init (gid 839), which no cmap can', () {
      // ڵ before a dual-joiner: the shaper would mark this initial.
      final buffer = seed('ڵب');
      expect(
        buffer.infos[0].glyphId,
        gidLamV,
        reason: 'the cmap can only reach the isolated ڵ',
      );

      expect(applyFeature(buffer, Tag.init, at: {0}), isTrue);
      expect(buffer.infos[0].glyphId, gidLamVInit);
      expect(
        cmap.lookup(0x06B5),
        isNot(gidLamVInit),
        reason:
            'if U+06B5 mapped straight to the initial form there would be no '
            'package here',
      );
    });

    test('medi and fina reach the other two ڵ forms', () {
      final medial = seed('بڵب');
      expect(medial.infos[1].glyphId, gidLamV);
      applyFeature(medial, Tag.medi, at: {1});
      expect(medial.infos[1].glyphId, gidLamVMedi);

      final finalForm = seed('بڵ');
      expect(finalForm.infos[1].glyphId, gidLamV);
      applyFeature(finalForm, Tag.fina, at: {1});
      expect(finalForm.infos[1].glyphId, gidLamVFina);

      expect(
        {gidLamV, gidLamVInit, gidLamVMedi, gidLamVFina}.length,
        4,
        reason: 'all four positional forms must be distinct glyphs',
      );
    });

    test(
      'fina reaches uni06D5.fina (gid 896) — the ە of every Sorani word',
      () {
        final buffer = seed('مە');
        expect(buffer.infos[1].glyphId, gidAe);

        expect(applyFeature(buffer, Tag.fina, at: {1}), isTrue);
        expect(buffer.infos[1].glyphId, gidAeFina);
      },
    );

    test('a ligature lookup builds gid 474 out of ڵ + ا', () {
      final buffer = seed('ڵا');
      expect(gids(buffer), [gidLamV, gidAlef]);

      // The joining pass first: the ligature's components are the CONTEXTUAL
      // forms, not the isolated letters, which is why no amount of cmap
      // work reaches it.
      applyFeature(buffer, Tag.init, at: {0});
      applyFeature(buffer, Tag.fina, at: {1});
      expect(gids(buffer), [gidLamVInit, gidAlefFina]);

      expect(applyFeature(buffer, Tag.rlig), isTrue);
      expect(gids(buffer), [gidLamVAlef]);
      expect(buffer.length, 1, reason: 'two glyphs became one');
      expect(
        buffer.infos[0].cluster,
        0,
        reason: 'the merged cluster must be the minimum, or ToUnicode breaks',
      );
      expect(
        buffer.positions.length,
        1,
        reason: 'positions stayed in lockstep',
      );

      final rlig = lookupsOf(Tag.rlig);
      expect(
        rlig.map(gsub.lookupType),
        contains(4),
        reason: 'gid 474 must come from a Ligature lookup, not a Single one',
      );
    });

    test('the ligature still forms across a mark the lookup cannot see', () {
      // ڵ + shadda + ا. The rlig lookup sets IgnoreMarks, so the shadda must
      // not block the match — and it must survive, stamped with the component
      // it now belongs to, or GPOS puts it on the wrong half of the ligature.
      final buffer = seed('ڵّا');
      expect(gids(buffer), [gidLamV, gidShadda, gidAlef]);
      expect(buffer.infos[1].glyphClass, GlyphClass.mark);

      applyFeature(buffer, Tag.init, at: {0});
      applyFeature(buffer, Tag.fina, at: {2});
      expect(applyFeature(buffer, Tag.rlig), isTrue);

      expect(gids(buffer), [gidLamVAlef, gidShadda]);
      expect(buffer.infos[1].ligatureId, isNot(0));
      expect(buffer.infos[0].ligatureId, buffer.infos[1].ligatureId);
      expect(
        buffer.infos[1].ligatureComponent,
        1,
        reason: 'the shadda sat after component one',
      );
      expect(buffer.infos[0].ligatureComponent, 0);
      expect(buffer.infos.map((i) => i.cluster), everyElement(0));
    });

    test('chaining context produces uniFE98.long in کوردستان', () {
      // Joining positions, as the state machine would resolve them:
      //   ک init · و fina · ر isol · د isol · س init · ت medi · ا fina · ن isol
      final buffer = seed('کوردستان');
      applyFeature(buffer, Tag.init, at: {0, 4});
      applyFeature(buffer, Tag.medi, at: {5});
      applyFeature(buffer, Tag.fina, at: {1, 6});

      expect(
        buffer.infos[5].glyphId,
        gidTehMedi,
        reason: 'the plain medial teh, before any contextual alternate',
      );
      expect(buffer.infos[6].glyphId, gidAlefFina);

      expect(applyFeature(buffer, Tag.calt), isTrue);
      expect(
        buffer.infos[5].glyphId,
        gidTehMediLong,
        reason:
            'the .long alternate is reached only because a chaining rule saw '
            'the alef-final in the LOOKAHEAD',
      );

      final calt = lookupsOf(Tag.calt);
      expect(calt.map(gsub.lookupType), contains(6));
    });
  });

  group('the driver', () {
    test('only the masked glyphs are substituted', () {
      final buffer = seed('ڵب');
      for (final info in buffer.infos) {
        info.mask = 0;
      }
      for (final lookup in lookupsOf(Tag.init)) {
        expect(
          gsub.applyLookup(lookup, buffer, mask: kMask, gdef: gdef),
          isFalse,
        );
      }
      expect(buffer.infos[0].glyphId, gidLamV);
    });

    test('lookupFlag reports the font\'s real flags', () {
      // Vazirmatn's joining lookups are RightToLeft + IgnoreMarks; if they were
      // not, the shadda test above would be proving nothing.
      for (final lookup in lookupsOf(Tag.fina)) {
        expect(gsub.lookupFlag(lookup) & LookupFlag.ignoreMarks, isNot(0));
      }
    });

    test('collectOutputGlyphs closes over nested lookups', () {
      final init = <int>{};
      for (final lookup in lookupsOf(Tag.init)) {
        gsub.collectOutputGlyphs(lookup, init);
      }
      expect(init, contains(gidLamVInit));

      final rlig = <int>{};
      for (final lookup in lookupsOf(Tag.rlig)) {
        gsub.collectOutputGlyphs(lookup, rlig);
      }
      expect(rlig, contains(gidLamVAlef));

      // The .long alternates are NOT outputs of the calt lookup itself — the
      // chaining rule only names another lookup to run. A subsetter that
      // stopped at the direct outputs would drop them and export tofu.
      final calt = <int>{};
      for (final lookup in lookupsOf(Tag.calt)) {
        gsub.collectOutputGlyphs(lookup, calt);
      }
      expect(calt, contains(gidTehMediLong));
    });

    test('every lookup in the font parses and reports a real type', () {
      for (var i = 0; i < gsub.lookupCount; i++) {
        expect(gsub.lookupType(i), inInclusiveRange(1, 8));
        expect(
          gsub.lookupType(i),
          isNot(7),
          reason: 'extensions must be resolved away at parse time',
        );
      }
    });
  });

  // ── the types Vazirmatn does not ship ───────────────────────────────────────

  group('synthetic subtables', () {
    test('Multiple keeps the source cluster on every output glyph', () {
      final subtable = parseGsubSubtable(
        2,
        _table([
          1, 8, 1, 14, // format, coverageOffset, sequenceCount, offset
          1, 1, 5, //     coverage: format 1, one glyph, gid 5
          3, 10, 11, 12, // sequence: three glyphs
        ]),
      );
      final buffer = _buffer([5]);
      buffer.infos[0].cluster = 7;
      final ctx = _context(buffer);

      expect(subtable.apply(ctx), isTrue);
      expect([for (final i in buffer.infos) i.glyphId], [10, 11, 12]);
      expect(
        [for (final i in buffer.infos) i.cluster],
        [7, 7, 7],
        reason:
            'a decomposition is still one character — ToUnicode depends '
            'on every piece pointing back at it',
      );
      expect(buffer.positions.length, 3);
      expect(ctx.index, 3);
    });

    test('Alternate picks by index', () {
      ByteReader bytes() => _table([1, 8, 1, 14, 1, 1, 5, 2, 20, 21]);

      final first = _buffer([5]);
      expect(parseGsubSubtable(3, bytes()).apply(_context(first)), isTrue);
      expect(first.infos[0].glyphId, 20);

      final second = _buffer([5]);
      expect(
        parseGsubSubtable(
          3,
          bytes(),
        ).apply(_context(second, alternateIndex: 1)),
        isTrue,
      );
      expect(second.infos[0].glyphId, 21);

      final missing = _buffer([5]);
      expect(
        parseGsubSubtable(
          3,
          bytes(),
        ).apply(_context(missing, alternateIndex: 9)),
        isFalse,
      );
    });

    test('sequenceIndex counts non-skipped positions, not buffer slots', () {
      // Context format 3: input is [gid 5, gid 7], one record at sequenceIndex
      // 1. The buffer puts a mark BETWEEN them and the lookup ignores marks, so
      // the record must land on buffer index 2.
      final subtable = parseGsubSubtable(
        5,
        _table([
          3, 2, 1, // format, glyphCount, seqLookupCount
          14, 20, // coverageOffsets
          1, 99, // record: sequenceIndex 1 → lookup 99
          1, 1, 5, // coverage A
          1, 1, 7, // coverage B
        ]),
      );
      final buffer = _buffer(
        [5, 400, 7],
        classes: [GlyphClass.base, GlyphClass.mark, GlyphClass.base],
      );

      final seen = <(int, int)>[];
      final ctx = _context(
        buffer,
        lookupFlag: LookupFlag.ignoreMarks,
        recurse: (ctx, lookupIndex) {
          seen.add((ctx.index, lookupIndex));
          return true;
        },
      );

      expect(subtable.apply(ctx), isTrue);
      expect(seen, [
        (2, 99),
      ], reason: 'raw indexing would have run the lookup on the mark at 1');
      expect(ctx.index, 3, reason: 'the cursor sits past the whole match');
    });

    test('backtrack arrays are read nearest-first', () {
      // Input gid 9 at the end; backtrack must be [8, 7] — the glyph nearest
      // the input FIRST. Written the other way round, the rule never fires.
      ByteReader chain(int firstBacktrack, int secondBacktrack) => _table([
        3, // format
        2, 20, 26, // backtrackGlyphCount, two coverage offsets
        1, 32, //     inputGlyphCount, one coverage offset
        0, //         lookaheadGlyphCount
        1, 0, 99, //  seqLookupCount, record
        1, 1, firstBacktrack, // coverage at byte 20
        1, 1, secondBacktrack, // coverage at byte 26
        1, 1, 9, //             coverage at byte 32
      ]);

      GsubContext run(ByteReader table, List<(int, int)> seen) {
        final buffer = _buffer([7, 8, 9]);
        final ctx = _context(
          buffer,
          recurse: (ctx, lookupIndex) {
            seen.add((ctx.index, lookupIndex));
            return true;
          },
        )..index = 2;
        expect(parseGsubSubtable(6, table).apply(ctx), seen.isNotEmpty);
        return ctx;
      }

      final nearestFirst = <(int, int)>[];
      run(chain(8, 7), nearestFirst);
      expect(nearestFirst, [(2, 99)]);

      final reversed = <(int, int)>[];
      final buffer = _buffer([7, 8, 9]);
      final ctx = _context(
        buffer,
        recurse: (ctx, lookupIndex) {
          reversed.add((ctx.index, lookupIndex));
          return true;
        },
      )..index = 2;
      expect(
        parseGsubSubtable(6, chain(7, 8)).apply(ctx),
        isFalse,
        reason: 'furthest-first is the classic bug and it must not match',
      );
      expect(reversed, isEmpty);
    });

    test('Reverse chaining substitutes one glyph and reads its lookahead', () {
      ByteReader bytes() => _table([
        1, 14, // format, coverageOffset
        0, //     backtrackGlyphCount
        1, 20, // lookaheadGlyphCount, offset
        1, 42, // glyphCount, substitute
        1, 1, 5, // coverage at byte 14
        1, 1, 7, // lookahead coverage at byte 20
      ]);

      final matching = _buffer([5, 7]);
      expect(parseGsubSubtable(8, bytes()).apply(_context(matching)), isTrue);
      expect([for (final i in matching.infos) i.glyphId], [42, 7]);

      final notMatching = _buffer([5, 8]);
      expect(
        parseGsubSubtable(8, bytes()).apply(_context(notMatching)),
        isFalse,
      );

      // Nested is illegal by spec: its lookahead is supposed to see glyphs the
      // same pass already rewrote, which only holds in its own backward pass.
      final nested = _buffer([5, 7]);
      expect(
        parseGsubSubtable(8, bytes()).apply(_context(nested)..depth = 1),
        isFalse,
      );
    });
  });
}

/// Builds a subtable out of big-endian uint16 words. Byte offsets in the tables
/// above are therefore twice the word index, which is why every offset in these
/// literals is even.
ByteReader _table(List<int> words) {
  final data = ByteData(words.length * 2);
  for (var i = 0; i < words.length; i++) {
    data.setUint16(i * 2, words[i]);
  }
  return ByteReader(data);
}

GlyphBuffer _buffer(List<int> glyphIds, {List<int>? classes}) {
  final buffer = GlyphBuffer();
  for (var i = 0; i < glyphIds.length; i++) {
    buffer.infos.add(
      GlyphInfo(
        glyphId: glyphIds[i],
        codepoint: 0x600 + i,
        cluster: i,
        glyphClass: classes?[i] ?? GlyphClass.base,
        mask: kMask,
      ),
    );
    buffer.positions.add(GlyphPosition());
  }
  return buffer;
}

GsubContext _context(
  GlyphBuffer buffer, {
  int lookupFlag = 0,
  int alternateIndex = 0,
  GsubRecurseCallback? recurse,
}) => GsubContext(
  buffer,
  lookupMask: kMask,
  alternateIndex: alternateIndex,
  recurse: recurse ?? (ctx, lookupIndex) => false,
)..setLookup(lookupFlag, 0);
