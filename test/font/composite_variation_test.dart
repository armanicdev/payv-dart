// A component pinned by point matching must not be moved by a `gvar` delta.
//
// Vazirmatn has no point-matched composites, so the real-font suites cannot
// reach this and a parity run against it comes back clean either way. The font
// below is therefore built here, byte by byte, small enough to read: two glyphs
// that are the same 100×100 square, and two composites that place the second
// square to the right of the first — one by an x/y OFFSET, one by MATCHING a
// point. `gvar` moves component 1 by +50 in x at the axis extreme.
//
// The offset composite must follow that delta (its offset is what the delta
// addresses). The point-matched one must ignore it: its position is defined by
// an anchor point in the composite assembled so far, and that anchor has
// already moved on its own. FreeType guards this with `ARGS_ARE_XY_VALUES`,
// fontTools drops the delta, HarfBuzz cancels it against the anchor.
library;

import 'dart:typed_data';

import 'package:payv/src/font/tables/glyf.dart';
import 'package:payv/src/font/variations/gvar.dart';
import 'package:payv/src/util/byte_reader.dart';
import 'package:test/test.dart';

const int gidSquare = 1;
const int gidMatched = 2; // second component positioned by point matching
const int gidOffset = 3; // second component positioned by an x/y offset

/// One 100×100 square: four on-curve points, one contour. 34 bytes, padded to
/// 36 so the glyph after it starts on a 4-byte boundary.
Uint8List _square() {
  final out = Uint8List(36);
  final v = ByteData.view(out.buffer);
  v.setInt16(0, 1); // numberOfContours
  v.setInt16(2, 0); // xMin
  v.setInt16(4, 0); // yMin
  v.setInt16(6, 100); // xMax
  v.setInt16(8, 100); // yMax
  v.setUint16(10, 3); // endPtsOfContours[0]
  v.setUint16(12, 0); // instructionLength
  for (var i = 0; i < 4; i++) {
    out[14 + i] = 0x01; // ON_CURVE, both coordinates as int16 deltas
  }
  const xs = <int>[0, 100, 0, -100];
  const ys = <int>[0, 0, 100, 0];
  for (var i = 0; i < 4; i++) {
    v.setInt16(18 + i * 2, xs[i]);
    v.setInt16(26 + i * 2, ys[i]);
  }
  return out;
}

/// A composite of two [gidSquare]s. 26 bytes, padded to 28.
///
/// When [pointMatched] the second component names point 1 of the composite so
/// far — the first square's (100, 0) corner — and point 0 of itself, so it
/// lands exactly to the right of it. Otherwise it carries the same placement as
/// a literal (100, 0) offset.
Uint8List _composite({required bool pointMatched}) {
  const argsAreWords = 0x0001;
  const argsAreXy = 0x0002;
  const moreComponents = 0x0020;

  final out = Uint8List(28);
  final v = ByteData.view(out.buffer);
  v.setInt16(0, -1); // numberOfContours < 0 marks a composite
  v.setInt16(2, 0);
  v.setInt16(4, 0);
  v.setInt16(6, 200);
  v.setInt16(8, 100);

  v.setUint16(10, argsAreWords | argsAreXy | moreComponents);
  v.setUint16(12, gidSquare);
  v.setInt16(14, 0); // dx
  v.setInt16(16, 0); // dy

  v.setUint16(18, pointMatched ? argsAreWords : argsAreWords | argsAreXy);
  v.setUint16(20, gidSquare);
  if (pointMatched) {
    v.setUint16(22, 1); // point 1 of the composite so far — (100, 0)
    v.setUint16(24, 0); // point 0 of this component — (0, 0)
  } else {
    v.setInt16(22, 100); // dx
    v.setInt16(24, 0); // dy
  }
  return out;
}

/// `glyf` and a long `loca` over glyphs `[empty, square, matched, offset]`.
(Uint8List, Uint8List) _glyfAndLoca() {
  final square = _square();
  final matched = _composite(pointMatched: true);
  final offset = _composite(pointMatched: false);

  final glyf = Uint8List(square.length + matched.length + offset.length)
    ..setRange(0, square.length, square)
    ..setRange(square.length, square.length + matched.length, matched)
    ..setRange(square.length + matched.length, 92, offset);

  // Glyph 0 is empty — loca[0] == loca[1] — which is how the format spells it.
  const ends = <int>[0, 0, 36, 64, 92];
  final loca = Uint8List(ends.length * 4);
  final v = ByteData.view(loca.buffer);
  for (var i = 0; i < ends.length; i++) {
    v.setUint32(i * 4, ends[i]);
  }
  return (glyf, loca);
}

/// One tuple moving component 1 by (+50, 0) at axis coordinate 1.0.
///
/// A composite's `gvar` "points" are its components plus the four phantoms, so
/// this glyph has six and only point 1 is referenced.
Uint8List _variationData() {
  final out = Uint8List(16);
  final v = ByteData.view(out.buffer);
  v.setUint16(0, 1); // tupleVariationCount: one tuple, no shared points
  v.setUint16(2, 10); // offset to the serialised data
  v.setUint16(4, 6); // variationDataSize
  v.setUint16(6, 0xA000); // EMBEDDED_PEAK_TUPLE | PRIVATE_POINT_NUMBERS
  v.setInt16(8, 16384); // peak = 1.0 in F2Dot14

  out[10] = 0x01; // one point number follows
  out[11] = 0x00; // a run of one, stored as a byte
  out[12] = 0x01; // point 1 — the second component
  out[13] = 0x00; // x deltas: a run of one, stored as a byte
  out[14] = 50;
  out[15] = 0x80; // y deltas: a run of one, all zero
  return out;
}

Uint8List _gvar() {
  final data = _variationData();
  const headerSize = 20;
  const offsetCount = 5; // glyphCount + 1
  final dataArrayAt = headerSize + offsetCount * 4;

  final out = Uint8List(dataArrayAt + data.length * 2);
  final v = ByteData.view(out.buffer);
  v.setUint16(0, 1); // majorVersion
  v.setUint16(2, 0); // minorVersion
  v.setUint16(4, 1); // axisCount
  v.setUint16(6, 0); // sharedTupleCount
  v.setUint32(8, 0); // sharedTuplesOffset
  v.setUint16(12, 4); // glyphCount
  v.setUint16(14, 1); // flags: long offsets
  v.setUint32(16, dataArrayAt);

  // Glyphs 0 and 1 do not vary; both composites carry the same tuple.
  const offsets = <int>[0, 0, 0, 16, 32];
  for (var i = 0; i < offsetCount; i++) {
    v.setUint32(headerSize + i * 4, offsets[i]);
  }
  out.setRange(dataArrayAt, dataArrayAt + data.length, data);
  out.setRange(dataArrayAt + data.length, out.length, data);
  return out;
}

void main() {
  late GlyfTable glyf;
  late GvarTable gvar;

  setUpAll(() {
    final (glyfBytes, locaBytes) = _glyfAndLoca();
    glyf = GlyfTable.parse(
      ByteReader.fromBytes(glyfBytes),
      loca: ByteReader.fromBytes(locaBytes),
      indexToLocFormat: 1,
      numGlyphs: 4,
    );
    gvar = GvarTable.parse(
      ByteReader.fromBytes(_gvar()),
      numGlyphs: 4,
      axisCount: 1,
    );
  });

  test('the synthetic font is the shape these expectations assume', () {
    expect(glyf.outline(0), isNull, reason: 'glyph 0 is empty');
    expect(glyf.outline(gidSquare)!.bounds.xMax, 100);
    // Both composites place the second square flush to the right of the first,
    // by different means — that is what makes them comparable.
    expect(glyf.outline(gidMatched)!.bounds.xMax, 200);
    expect(glyf.outline(gidOffset)!.bounds.xMax, 200);
    expect(gvar.deltas(gidMatched, const <double>[1], 6)![1], (50.0, 0.0));
  });

  test('a point-matched component ignores the delta and stays anchored', () {
    final varied = glyf.outline(
      gidMatched,
      coords: const <double>[1],
      gvar: gvar,
    )!;
    expect(
      varied.bounds.xMax,
      200,
      reason: 'adding the delta would slide the component to 250',
    );
    expect(varied.bounds, glyf.outline(gidMatched)!.bounds);
  });

  test('an x/y-offset component still follows the delta', () {
    // The control. Dropping the delta everywhere would also make the test above
    // pass, and would break every variable composite in a real font.
    final varied = glyf.outline(
      gidOffset,
      coords: const <double>[1],
      gvar: gvar,
    )!;
    expect(varied.bounds.xMax, 250);
    expect(varied.bounds.xMin, 0, reason: 'component 0 did not move');
  });

  test('the default instance is untouched either way', () {
    for (final gid in <int>[gidMatched, gidOffset]) {
      final atDefault = glyf.outline(
        gid,
        coords: const <double>[0],
        gvar: gvar,
      );
      expect(atDefault!.bounds, glyf.outline(gid)!.bounds);
    }
  });

  test('the delta scales with the axis, and only the offset form moves', () {
    final half = const <double>[0.5];
    expect(glyf.outline(gidOffset, coords: half, gvar: gvar)!.bounds.xMax, 225);
    expect(
      glyf.outline(gidMatched, coords: half, gvar: gvar)!.bounds.xMax,
      200,
    );
  });
}
