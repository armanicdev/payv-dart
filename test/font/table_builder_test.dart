// `SfntBuilder` — the container every subsetted and instanced font leaves
// through, and until now the only module in the font stack with no test.
//
// Its own header names three failure modes, and they share a shape: each one
// produces a font that OPENS. A viewer that trusts the directory order, a
// checksum nobody verifies, a `checkSumAdjustment` computed in the wrong order —
// all of it renders on the machine the font was built on, and is rejected by a
// validator or a stricter loader somewhere else. So the tests below do not ask
// "does it parse", they recompute each field independently and compare.
library;

import 'dart:typed_data';

import 'package:payv/src/font/sfnt.dart';
import 'package:payv/src/font/table_builder.dart';
import 'package:payv/src/util/tag.dart';
import 'package:test/test.dart';

/// A `head` with recognisable bytes everywhere except the four the builder
/// owns, so a stray write shows up as a changed byte rather than as a plausible
/// number.
Uint8List _head({int checkSumAdjustment = 0xDEADBEEF}) {
  final out = Uint8List(54);
  final v = ByteData.view(out.buffer);
  v.setUint32(0, 0x00010000); // version
  v.setUint32(4, 0x00010000); // fontRevision
  v.setUint32(8, checkSumAdjustment);
  v.setUint32(12, 0x5F0F3CF5); // magicNumber
  v.setUint16(18, 2048); // unitsPerEm
  v.setInt16(50, 0); // indexToLocFormat
  return out;
}

Uint8List _filled(int length, int byte) =>
    Uint8List(length)..fillRange(0, length, byte);

/// The OpenType checksum, recomputed here rather than reused from the builder —
/// a test that calls the code under test to produce its own expectation proves
/// only that the function is deterministic.
int _checksum(Uint8List bytes, int start, int length) {
  var sum = 0;
  for (var i = 0; i < length; i += 4) {
    var word = 0;
    for (var b = 0; b < 4; b++) {
      final at = start + i + b;
      word = (word << 8) | (at < bytes.length ? bytes[at] : 0);
    }
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}

/// The directory as `(tag, checksum, offset, length)`, read back from the bytes.
List<(int, int, int, int)> _directory(Uint8List font) {
  final v = ByteData.view(font.buffer, font.offsetInBytes, font.lengthInBytes);
  final count = v.getUint16(4);
  return <(int, int, int, int)>[
    for (var i = 0; i < count; i++)
      (
        v.getUint32(12 + i * 16),
        v.getUint32(12 + i * 16 + 4),
        v.getUint32(12 + i * 16 + 8),
        v.getUint32(12 + i * 16 + 12),
      ),
  ];
}

void main() {
  /// Tags deliberately staged out of order, and one of them ('cmap') sorts
  /// before a tag added earlier — otherwise insertion order and sorted order
  /// would agree and the sort could not fail.
  SfntBuilder builder() => SfntBuilder()
    ..setTable(Tag.glyf, _filled(9, 0x11)) // length 9: not 4-byte aligned
    ..setTable(Tag.head, _head())
    ..setTable(Tag.cmap, _filled(20, 0x22))
    ..setTable(Tag.maxp, _filled(6, 0x33));

  group('the table directory', () {
    test('is sorted by tag, whatever order the tables were staged in', () {
      final font = builder().build();
      final tags = _directory(font).map((e) => e.$1).toList();
      expect(tags, List<int>.of(tags)..sort());
      expect(tags.map((t) => Tag(t).asString), <String>[
        'cmap',
        'glyf',
        'head',
        'maxp',
      ]);
    });

    test('records the real offset and the UNPADDED length', () {
      // The length field is the table's own length; the padding that follows is
      // not part of it. Writing the padded length is the classic slip, and it
      // makes every table look four bytes longer than it is.
      final font = builder().build();
      for (final (tag, _, offset, length) in _directory(font)) {
        expect(offset % 4, 0, reason: 'tables start 4-byte aligned');
        // `head` is the one table the builder rewrites — four bytes of
        // checkSumAdjustment — so it is compared in its own group below.
        if (tag == Tag.head) continue;
        expect(font.sublist(offset, offset + length), builder().table(tag));
      }
      final byTag = <int, int>{for (final e in _directory(font)) e.$1: e.$4};
      expect(byTag[Tag.glyf], 9);
      expect(byTag[Tag.maxp], 6);
    });

    test('carries a searchRange trio a loader can binary-search with', () {
      // Nothing in payv reads these. FreeType and several OS loaders do
      // sanity-check them, and nonsense here is a font that renders on the
      // developer's Mac and not on the reader's phone.
      final font = builder().build();
      final v = ByteData.view(font.buffer);
      expect(v.getUint16(4), 4, reason: 'numTables');
      expect(v.getUint16(6), 64, reason: 'searchRange = 2^floor(log2 n) * 16');
      expect(v.getUint16(8), 2, reason: 'entrySelector = floor(log2 n)');
      expect(v.getUint16(10), 0, reason: 'rangeShift = n*16 - searchRange');

      // Three tables is the case where the trio stops being trivial.
      final odd = SfntBuilder()
        ..setTable(Tag.head, _head())
        ..setTable(Tag.maxp, _filled(6, 1))
        ..setTable(Tag.cmap, _filled(6, 2));
      final w = ByteData.view(odd.build().buffer);
      expect(w.getUint16(6), 32);
      expect(w.getUint16(8), 1);
      expect(w.getUint16(10), 16);
    });

    test('a font with no tables is a build error, not an empty file', () {
      expect(SfntBuilder().build, throwsStateError);
    });

    test('a head shorter than 54 bytes is refused before it is written', () {
      final short = SfntBuilder()..setTable(Tag.head, _filled(20, 0));
      expect(short.build, throwsArgumentError);
    });
  });

  group('per-table checksums', () {
    test('span the zero padding, not just the table length', () {
      // `glyf` is 9 bytes here, so it is padded with three zeros. A checksum
      // over 9 bytes cannot even be computed as uint32 words — an implementation
      // that stops at the length either drops the tail byte or reads whatever
      // follows it. Both produce a font that opens.
      final font = builder().build();
      for (final (tag, checksum, offset, length) in _directory(font)) {
        if (tag == Tag.head) continue; // its checksum is over zeroed bytes
        final padded = (length + 3) & ~3;
        expect(
          checksum,
          _checksum(font, offset, padded),
          reason: '${Tag(tag).asString} checksum',
        );
      }
    });

    test('the padding really is zero, not whatever was in the buffer', () {
      final font = builder().build();
      final glyf = _directory(font).firstWhere((e) => e.$1 == Tag.glyf);
      expect(font.sublist(glyf.$3 + 9, glyf.$3 + 12), <int>[0, 0, 0]);
    });

    test('head is checksummed with checkSumAdjustment already zeroed', () {
      // The one table whose recorded checksum is NOT the checksum of the bytes
      // that end up in the file: the field is zeroed first, then filled in.
      final font = builder().build();
      final head = _directory(font).firstWhere((e) => e.$1 == Tag.head);
      final zeroed = Uint8List.fromList(font);
      for (var i = 0; i < 4; i++) {
        zeroed[head.$3 + 8 + i] = 0;
      }
      expect(head.$2, _checksum(zeroed, head.$3, (head.$4 + 3) & ~3));
      // And it is NOT the checksum of the file as written, which is the value a
      // naive implementation records.
      expect(head.$2, isNot(_checksum(font, head.$3, (head.$4 + 3) & ~3)));
    });
  });

  group('checkSumAdjustment', () {
    test('is 0xB1B0AFBA minus the checksum of the whole zeroed file', () {
      final font = builder().build();
      final head = _directory(font).firstWhere((e) => e.$1 == Tag.head);
      final written = ByteData.view(font.buffer).getUint32(head.$3 + 8);

      final zeroed = Uint8List.fromList(font);
      for (var i = 0; i < 4; i++) {
        zeroed[head.$3 + 8 + i] = 0;
      }
      expect(
        written,
        (0xB1B0AFBA - _checksum(zeroed, 0, font.length)) & 0xFFFFFFFF,
      );
      expect(written, isNot(0xDEADBEEF), reason: 'the input value is replaced');
    });

    test('makes the finished file sum to 0xB1B0AFBA — the property itself', () {
      // This is what a validator actually computes, and it is the reason the
      // ORDER matters: zero the field, sum the file, subtract. Compute the sum
      // before zeroing, or after writing, and this comes out wrong while every
      // individual step still looks right.
      final font = builder().build();
      expect(_checksum(font, 0, font.length), 0xB1B0AFBA);
    });

    test('holds when the tables push the file past one padding boundary', () {
      // A different total length exercises a different tail. If the whole-file
      // sum were computed over the wrong span this is where it shows.
      for (final length in <int>[1, 2, 3, 4, 5, 255, 256, 257]) {
        final font =
            (SfntBuilder()
                  ..setTable(Tag.head, _head())
                  ..setTable(Tag.glyf, _filled(length, 0x77)))
                .build();
        expect(
          _checksum(font, 0, font.length),
          0xB1B0AFBA,
          reason: 'glyf length $length',
        );
      }
    });

    test('is skipped entirely when the font carries no head', () {
      // The instancer stages tables incrementally; a build without `head` must
      // not write four bytes into whatever table happens to be first.
      final font = (SfntBuilder()..setTable(Tag.maxp, _filled(6, 0x44)))
          .build();
      expect(font.sublist(12 + 16, 12 + 16 + 6), _filled(6, 0x44));
    });
  });

  group('the output as a font', () {
    test('parses back through SfntFile with every table intact', () {
      final source = builder();
      final sfnt = SfntFile.parse(source.build());
      expect(sfnt.sfntVersion, 0x00010000);
      for (final tag in source.tags) {
        if (tag == Tag.head) continue; // rewritten on purpose; see above
        expect(
          sfnt.tableBytes(tag),
          source.table(tag),
          reason: Tag(tag).asString,
        );
      }
      // `head` survives byte for byte apart from the four the builder owns.
      final head = sfnt.tableBytes(Tag.head)!;
      expect(head.sublist(0, 8), _head().sublist(0, 8));
      expect(head.sublist(12), _head().sublist(12));
    });

    test("'OTTO' is written when the caller asks for CFF outlines", () {
      final font = builder().build(sfntVersion: 0x4F54544F);
      expect(SfntFile.parse(font).sfntVersion, 0x4F54544F);
    });

    test('the same input builds to the same bytes twice', () {
      // Byte-reproducibility is what makes a subsetter testable at all, and it
      // is why the data is sorted as well as the directory.
      expect(builder().build(), builder().build());
    });

    test('the caller\'s buffer is never mutated, head included', () {
      final head = _head();
      final before = Uint8List.fromList(head);
      (SfntBuilder()..setTable(Tag.head, head)).build();
      expect(head, before, reason: 'zeroing must happen on a copy');
    });

    test('a replaced table wins and a removed one is gone', () {
      final b = builder()
        ..setTable(Tag.maxp, _filled(8, 0x55))
        ..removeTable(Tag.cmap);
      expect(b.has(Tag.cmap), isFalse);
      final tags = _directory(b.build()).map((e) => e.$1);
      expect(tags, isNot(contains(Tag.cmap)));
      expect(b.table(Tag.maxp), _filled(8, 0x55));
    });
  });
}
