/// Big-endian binary reader for SFNT data.
///
/// Every OpenType structure is big-endian and addressed by an offset that is
/// relative to *some* enclosing table, so the whole parser is written as a
/// [ByteReader] over one shared [ByteData] plus an absolute `base`. Slicing the
/// bytes per table would copy megabytes and lose the ability to follow an
/// offset that points backwards into a parent — which real fonts do.
library;

import 'dart:typed_data';

/// Reads big-endian primitives out of [data] at absolute byte offsets.
///
/// This is deliberately a *cursorless* reader for random access ([uint16At]),
/// plus a cursor ([position]) for sequential reads. OpenType needs both: arrays
/// are sequential, offsets are random.
class ByteReader {
  ByteReader(this.data, [this.position = 0]);

  /// Wraps a whole [Uint8List], respecting any view offset it carries.
  factory ByteReader.fromBytes(Uint8List bytes, [int position = 0]) =>
      ByteReader(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        position,
      );

  final ByteData data;

  /// Cursor for the sequential `read*` family. Absolute, not table-relative.
  int position;

  int get length => data.lengthInBytes;

  bool get isAtEnd => position >= length;

  /// True when [count] more bytes can be read from [offset] without overrunning.
  ///
  /// Bounds are checked everywhere rather than trusted: this parser is fed
  /// fonts that arrive over a network, and a malformed offset table must throw
  /// a [FontFormatException], never read adjacent heap.
  bool canRead(int offset, int count) =>
      offset >= 0 && count >= 0 && offset + count <= length;

  // ── random access ───────────────────────────────────────────────────────────

  int uint8At(int offset) {
    _check(offset, 1);
    return data.getUint8(offset);
  }

  int int8At(int offset) {
    _check(offset, 1);
    return data.getInt8(offset);
  }

  int uint16At(int offset) {
    _check(offset, 2);
    return data.getUint16(offset);
  }

  int int16At(int offset) {
    _check(offset, 2);
    return data.getInt16(offset);
  }

  int uint24At(int offset) {
    _check(offset, 3);
    return (data.getUint8(offset) << 16) |
        (data.getUint8(offset + 1) << 8) |
        data.getUint8(offset + 2);
  }

  int uint32At(int offset) {
    _check(offset, 4);
    return data.getUint32(offset);
  }

  int int32At(int offset) {
    _check(offset, 4);
    return data.getInt32(offset);
  }

  /// F2Dot14 — a signed 2.14 fixed-point number, used for variation axis
  /// coordinates and for the anchor scalars in `gvar`.
  double f2dot14At(int offset) => int16At(offset) / 16384.0;

  /// Fixed — a signed 16.16 fixed-point number.
  double fixedAt(int offset) => int32At(offset) / 65536.0;

  /// A 4-byte tag as its packed uint32. Compare against [Tag] constants rather
  /// than building strings — tag comparison happens once per lookup per glyph.
  int tagAt(int offset) => uint32At(offset);

  Uint8List bytesAt(int offset, int count) {
    _check(offset, count);
    return Uint8List.view(data.buffer, data.offsetInBytes + offset, count);
  }

  /// A reader over the same buffer, positioned at [offset]. Shares the buffer —
  /// no copy.
  ByteReader at(int offset) => ByteReader(data, offset);

  // ── sequential access ───────────────────────────────────────────────────────

  int readUint8() => uint8At(position++);

  int readInt8() => int8At(position++);

  int readUint16() {
    final v = uint16At(position);
    position += 2;
    return v;
  }

  int readInt16() {
    final v = int16At(position);
    position += 2;
    return v;
  }

  int readUint24() {
    final v = uint24At(position);
    position += 3;
    return v;
  }

  int readUint32() {
    final v = uint32At(position);
    position += 4;
    return v;
  }

  int readInt32() {
    final v = int32At(position);
    position += 4;
    return v;
  }

  double readF2Dot14() {
    final v = f2dot14At(position);
    position += 2;
    return v;
  }

  double readFixed() {
    final v = fixedAt(position);
    position += 4;
    return v;
  }

  int readTag() => readUint32();

  Uint8List readBytes(int count) {
    final v = bytesAt(position, count);
    position += count;
    return v;
  }

  /// Reads [count] big-endian uint16s. Hot path — `Coverage` and `ClassDef`
  /// arrays are read this way for binary search.
  Uint16List readUint16List(int count) {
    _check(position, count * 2);
    final out = Uint16List(count);
    for (var i = 0; i < count; i++) {
      out[i] = data.getUint16(position + i * 2);
    }
    position += count * 2;
    return out;
  }

  void skip(int count) => position += count;

  void _check(int offset, int count) {
    if (!canRead(offset, count)) {
      throw FontFormatException(
        'read of $count byte(s) at $offset overruns a $length-byte font',
      );
    }
  }
}

/// Thrown when font data is structurally invalid.
///
/// A [FontFormatException] always means "this file is not a font we can parse",
/// never "this font lacks a feature" — a font with no `GSUB` is legal and
/// parses fine, it simply shapes without substitution.
class FontFormatException implements Exception {
  const FontFormatException(this.message);

  final String message;

  @override
  String toString() => 'FontFormatException: $message';
}
