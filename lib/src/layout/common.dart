/// The value structures GSUB and GPOS share: ValueRecord, Device, Anchor, and
/// the extension-subtable indirection both tables use to break the 64 KB
/// offset ceiling.
///
/// This file is also the barrel for the layout-common module — importing it
/// brings in [Coverage], [ClassDef], [LookupFlag]/[SkippyIterator],
/// [LayoutTable] and [GdefTable] — so a GSUB or GPOS subtable parser needs one
/// import to reach everything below the lookup level.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';

export 'class_def.dart';
export 'coverage.dart';
export 'gdef.dart';
export 'lookup_flags.dart';
export 'script_list.dart';

/// Bit flags of a GPOS ValueFormat.
///
/// The order of these bits IS the order the fields appear on disk — a
/// ValueRecord has no fixed layout, it is whichever of these eight fields the
/// format says are present, in bit order. That is why parsing one needs the
/// format up front and why [ValueRecord.parse] must report its own size.
abstract final class ValueFormat {
  static const int xPlacement = 0x0001;
  static const int yPlacement = 0x0002;
  static const int xAdvance = 0x0004;
  static const int yAdvance = 0x0008;
  static const int xPlacementDevice = 0x0010;
  static const int yPlacementDevice = 0x0020;
  static const int xAdvanceDevice = 0x0040;
  static const int yAdvanceDevice = 0x0080;

  /// Every device bit — the four that need an ItemVariationStore or a Device
  /// table to mean anything.
  static const int deviceMask = 0x00F0;
}

/// A GPOS ValueRecord: up to four positioning deltas plus up to four Device or
/// VariationIndex offsets.
///
/// Values are in font design units and are NOT device-resolved here. The device
/// offsets stay raw because they are relative to the enclosing subtable, which
/// this class deliberately does not know about; the GPOS subtable that owns the
/// record resolves them against its own base.
class ValueRecord {
  ValueRecord({
    this.xPlacement = 0,
    this.yPlacement = 0,
    this.xAdvance = 0,
    this.yAdvance = 0,
    this.xPlaDeviceOffset,
    this.yPlaDeviceOffset,
    this.xAdvDeviceOffset,
    this.yAdvDeviceOffset,
  });

  /// Reads the record at absolute [offset] under the given ValueFormat
  /// [format], returning it with the number of bytes it occupied.
  ///
  /// The byte count is not derivable by the caller from the record alone (a
  /// zero field and an absent field look identical), and PairPos format 1 walks
  /// a packed array of these, so the size has to come back out with the value.
  static (ValueRecord, int) parse(ByteReader r, int offset, int format) {
    var p = offset;

    int nextValue() {
      final v = r.int16At(p);
      p += 2;
      return v;
    }

    // A device offset of 0 is the spec's NULL, so it collapses to null here —
    // callers should never have to distinguish "absent bit" from "present bit,
    // NULL offset". They mean the same thing: no device adjustment.
    int? nextOffset() {
      final v = r.uint16At(p);
      p += 2;
      return v == 0 ? null : v;
    }

    final record = ValueRecord();
    if (format & ValueFormat.xPlacement != 0) record.xPlacement = nextValue();
    if (format & ValueFormat.yPlacement != 0) record.yPlacement = nextValue();
    if (format & ValueFormat.xAdvance != 0) record.xAdvance = nextValue();
    if (format & ValueFormat.yAdvance != 0) record.yAdvance = nextValue();
    if (format & ValueFormat.xPlacementDevice != 0) {
      record.xPlaDeviceOffset = nextOffset();
    }
    if (format & ValueFormat.yPlacementDevice != 0) {
      record.yPlaDeviceOffset = nextOffset();
    }
    if (format & ValueFormat.xAdvanceDevice != 0) {
      record.xAdvDeviceOffset = nextOffset();
    }
    if (format & ValueFormat.yAdvanceDevice != 0) {
      record.yAdvDeviceOffset = nextOffset();
    }
    return (record, p - offset);
  }

  int xPlacement;
  int yPlacement;
  int xAdvance;
  int yAdvance;

  /// Offsets to Device/VariationIndex tables, relative to the GPOS subtable
  /// that contains this record. Null when absent or NULL.
  int? xPlaDeviceOffset;
  int? yPlaDeviceOffset;
  int? xAdvDeviceOffset;
  int? yAdvDeviceOffset;

  bool get isZero =>
      xPlacement == 0 && yPlacement == 0 && xAdvance == 0 && yAdvance == 0;

  bool get hasDevices =>
      xPlaDeviceOffset != null ||
      yPlaDeviceOffset != null ||
      xAdvDeviceOffset != null ||
      yAdvDeviceOffset != null;

  /// On-disk size of a record with this ValueFormat: two bytes per set bit.
  static int sizeOf(int format) {
    // Sixteen-bit popcount. This is called per pair in a PairPos format 1
    // array, so it stays branchless rather than looping the bits.
    var v = format & 0xFFFF;
    v = v - ((v >> 1) & 0x5555);
    v = (v & 0x3333) + ((v >> 2) & 0x3333);
    v = (v + (v >> 4)) & 0x0F0F;
    return ((v * 0x0101) >> 8 & 0xFF) * 2;
  }

  @override
  String toString() =>
      'ValueRecord($xPlacement,$yPlacement +$xAdvance,$yAdvance)';
}

/// A Device table, or the VariationIndex table that shares its shape.
///
/// The two are the same struct with a different third field, which is how a
/// variable font retrofits variation deltas into every place the 2003 spec put
/// a hinting delta. [isVariationIndex] tells them apart; the caller must, since
/// a VariationIndex carries no ppem deltas at all — it carries a pointer into
/// an ItemVariationStore that only the font (not this table) can resolve.
class Device {
  Device._(this._first, this._second, this.deltaFormat, this._deltas);

  /// Parses the Device/VariationIndex table at [r]'s current position.
  static Device parse(ByteReader r) {
    final base = r.position;
    final first = r.uint16At(base);
    final second = r.uint16At(base + 2);
    final format = r.uint16At(base + 4);

    if (format == variationIndexFormat) {
      return Device._(first, second, format, _noDeltas);
    }
    if (format < 1 || format > 3) {
      // Not leniency-worthy: the format is what says how many bits each packed
      // delta takes, so an unknown one means we cannot even know how many bytes
      // this table occupies, let alone what follows it.
      throw FontFormatException('unknown Device deltaFormat $format');
    }

    final count = second >= first ? second - first + 1 : 0;
    final perWord = 16 >> format; // fmt 1 → 8, fmt 2 → 4, fmt 3 → 2
    final words = (count + perWord - 1) ~/ perWord;
    return Device._(
      first,
      second,
      format,
      r.at(base + 6).readUint16List(words),
    );
  }

  /// DeltaFormat 0x8000 — a VariationIndex, not a hinting Device.
  static const int variationIndexFormat = 0x8000;

  static final Uint16List _noDeltas = Uint16List(0);

  final int _first;
  final int _second;
  final int deltaFormat;
  final Uint16List _deltas;

  bool get isVariationIndex => deltaFormat == variationIndexFormat;

  /// Smallest ppem this table has a delta for. Meaningless when
  /// [isVariationIndex] — the same two bytes are then [deltaSetOuter].
  int get startSize => _first;

  int get endSize => _second;

  int get deltaSetOuter => _first;

  int get deltaSetInner => _second;

  /// Hinting delta at [ppem], in device pixels. Zero outside the table's range,
  /// and zero for a VariationIndex — resolving one needs the
  /// ItemVariationStore, which lives on GDEF, not here.
  int valueAt(int ppem) {
    if (isVariationIndex) return 0;
    if (ppem < _first || ppem > _second) return 0;

    final bits = 1 << deltaFormat; // fmt 1 → 2, fmt 2 → 4, fmt 3 → 8
    final perWord = 16 ~/ bits;
    final i = ppem - _first;
    final word = i ~/ perWord;
    if (word >= _deltas.length) return 0;

    final shift = 16 - bits * (i % perWord + 1);
    final mask = (1 << bits) - 1;
    var v = (_deltas[word] >> shift) & mask;
    // The packed deltas are signed in `bits` bits; sign-extend by hand.
    if (v >= 1 << (bits - 1)) v -= 1 << bits;
    return v;
  }

  @override
  String toString() => isVariationIndex
      ? 'VariationIndex($_first/$_second)'
      : 'Device($_first…$_second, fmt $deltaFormat)';
}

/// A GPOS Anchor — one attachment point, in font design units.
///
/// Format 2's [contourPoint] is an outline point index, which this layer cannot
/// resolve: it needs the instanced `glyf` outline. Shapers that ignore it get
/// the format 1 coordinates, which every sane font ships as a usable fallback,
/// and that is what happens here unless the caller resolves the point itself.
class Anchor {
  Anchor({
    required this.x,
    required this.y,
    this.contourPoint,
    this.xDevice,
    this.yDevice,
  });

  /// Parses the Anchor table at [r]'s current position.
  static Anchor parse(ByteReader r) {
    final base = r.position;
    final format = r.uint16At(base);
    final x = r.int16At(base + 2);
    final y = r.int16At(base + 4);
    switch (format) {
      case 1:
        return Anchor(x: x, y: y);
      case 2:
        return Anchor(x: x, y: y, contourPoint: r.uint16At(base + 6));
      case 3:
        // Device offsets here are relative to the Anchor table itself, unlike
        // the ones in a ValueRecord — so they are resolved on the spot.
        final xOffset = r.uint16At(base + 6);
        final yOffset = r.uint16At(base + 8);
        return Anchor(
          x: x,
          y: y,
          xDevice: xOffset == 0 ? null : Device.parse(r.at(base + xOffset)),
          yDevice: yOffset == 0 ? null : Device.parse(r.at(base + yOffset)),
        );
      default:
        throw FontFormatException('unknown Anchor format $format');
    }
  }

  int x;
  int y;

  /// Outline point index for format 2 anchors; null otherwise.
  int? contourPoint;

  Device? xDevice;
  Device? yDevice;

  @override
  String toString() => 'Anchor($x,$y)';
}

/// Resolves an extension subtable (GSUB lookup type 7, GPOS lookup type 9) to
/// the real lookup type and a reader at the real subtable.
///
/// Extensions exist because subtable offsets in a LookupList are 16-bit: a font
/// with more than 64 KB of layout data — which every large Arabic family is —
/// cannot address its own tables without this indirection. Both GSUB and GPOS
/// need it, and neither should special-case it more than once, so the whole
/// mechanism is this one function.
///
/// Returns ([lookupType], [subtable]) unchanged when the lookup is not an
/// extension, so a caller can pipe every subtable through it unconditionally.
(int, ByteReader) resolveExtension(
  int lookupType,
  ByteReader subtable, {
  required int extensionType,
}) {
  if (lookupType != extensionType) return (lookupType, subtable);

  final base = subtable.position;
  final format = subtable.uint16At(base);
  if (format != 1) {
    throw FontFormatException('unknown extension subtable format $format');
  }
  final realType = subtable.uint16At(base + 2);
  if (realType == extensionType) {
    // The spec forbids it explicitly, and allowing it would let a hostile font
    // send this function into unbounded recursion.
    throw FontFormatException('extension subtable nests another extension');
  }
  final offset = subtable.uint32At(base + 4);
  return (realType, subtable.at(base + offset));
}
