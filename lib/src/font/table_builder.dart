/// Assembling an SFNT container out of finished tables.
///
/// Both the subsetter and the instancer end here. It is a small file guarding a
/// disproportionate amount of pain: the three rules below are each individually
/// ignorable — the resulting font opens fine in most viewers — and each one is
/// the difference between a PDF that prints at a service counter and one that
/// a validator rejects with no useful message.
///
///   1. The table *directory* must be sorted by tag. The table *data* need not
///      be, but sorting both keeps the output byte-reproducible, which is what
///      makes a subsetter testable at all.
///   2. Table data is padded to a 4-byte boundary with ZERO bytes, and the
///      padding is inside the table's checksum. Padding with anything else
///      still "works" until something verifies.
///   3. `head.checkSumAdjustment` is 0xB1B0AFBA minus the checksum of the whole
///      finished file — computed with that same field already zeroed. Compute
///      it in the wrong order and you get a font that some validators accept
///      and others reject, which is the worst kind of bug to be handed.
library;

import 'dart:typed_data';

import '../util/tag.dart';

/// Collects tables and emits a valid SFNT.
///
/// Deliberately dumb about table *contents*: it never parses what it is given.
/// The subsetter and the instancer own the semantics; this owns the container.
class SfntBuilder {
  final Map<int, Uint8List> _tables = <int, Uint8List>{};

  /// Tags currently staged, in no particular order. [build] sorts.
  Iterable<int> get tags => _tables.keys;

  bool has(int tag) => _tables.containsKey(tag);

  Uint8List? table(int tag) => _tables[tag];

  /// Stages [bytes] under [tag], replacing anything already there.
  ///
  /// The bytes are kept by reference — [build] copies into the output and never
  /// mutates the input, so a caller may hand over a view into the source font.
  void setTable(int tag, Uint8List bytes) {
    _tables[tag] = bytes;
  }

  void removeTable(int tag) {
    _tables.remove(tag);
  }

  /// Emits the font.
  ///
  /// [sfntVersion] is 0x00010000 for TrueType outlines and `'OTTO'` for CFF.
  Uint8List build({int sfntVersion = 0x00010000}) {
    final tags = _tables.keys.toList()..sort();
    if (tags.isEmpty) {
      throw StateError('cannot build an SFNT with no tables');
    }

    final directorySize = 12 + tags.length * 16;
    final offsets = <int, int>{};
    var total = directorySize;
    for (final tag in tags) {
      offsets[tag] = total;
      total += _align4(_tables[tag]!.length);
    }

    final out = Uint8List(total);
    final view = ByteData.view(out.buffer);

    // searchRange/entrySelector/rangeShift describe a binary search over the
    // directory. Nothing in this library reads them — but FreeType and several
    // OS loaders do sanity-check them, and a font with nonsense here is a font
    // that renders on the developer's Mac and not on the reader's phone.
    var entrySelector = 0;
    while (1 << (entrySelector + 1) <= tags.length) {
      entrySelector++;
    }
    final searchRange = (1 << entrySelector) * 16;
    view.setUint32(0, sfntVersion);
    view.setUint16(4, tags.length);
    view.setUint16(6, searchRange);
    view.setUint16(8, entrySelector);
    view.setUint16(10, tags.length * 16 - searchRange);

    var headOffset = -1;
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final offset = offsets[tag]!;
      var bytes = _tables[tag]!;

      if (tag == Tag.head) {
        if (bytes.length < 54) {
          throw ArgumentError.value(
            bytes.length,
            'head.length',
            'head must be at least 54 bytes',
          );
        }
        // Copy before zeroing checkSumAdjustment: the caller may have handed us
        // a view straight into the source font's buffer.
        bytes = Uint8List.fromList(bytes);
        bytes[8] = 0;
        bytes[9] = 0;
        bytes[10] = 0;
        bytes[11] = 0;
        headOffset = offset;
      }

      out.setRange(offset, offset + bytes.length, bytes);

      // Checksum spans the zero padding, not just the table's own length.
      final checksum = _checksum(out, offset, _align4(bytes.length));
      final record = 12 + i * 16;
      view.setUint32(record, tag);
      view.setUint32(record + 4, checksum);
      view.setUint32(record + 8, offset);
      view.setUint32(record + 12, bytes.length);
    }

    if (headOffset >= 0) {
      final fileChecksum = _checksum(out, 0, total);
      view.setUint32(headOffset + 8, (0xB1B0AFBA - fileChecksum) & 0xFFFFFFFF);
    }

    return out;
  }

  static int _align4(int n) => (n + 3) & ~3;

  /// The OpenType checksum: a uint32 sum with wraparound over a 4-byte-aligned
  /// span. [length] must already be a multiple of 4 — every caller here pads.
  static int _checksum(Uint8List bytes, int start, int length) {
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes + start,
      length,
    );
    var sum = 0;
    for (var i = 0; i < length; i += 4) {
      sum = (sum + view.getUint32(i)) & 0xFFFFFFFF;
    }
    return sum;
  }
}
