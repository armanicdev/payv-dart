/// The SFNT container — the table directory that every other table hangs off.
library;

import 'dart:typed_data';

import '../util/byte_reader.dart';
import '../util/tag.dart';

/// One entry in the SFNT table directory.
class TableRecord {
  const TableRecord({
    required this.tag,
    required this.checksum,
    required this.offset,
    required this.length,
  });

  final int tag;
  final int checksum;
  final int offset;
  final int length;

  @override
  String toString() => '${Tag(tag).asString}@$offset+$length';
}

/// A parsed SFNT file: the table directory plus the shared byte buffer.
///
/// Holds no parsed tables itself. `OpenTypeFont` layers the typed tables on
/// top, lazily, so that a caller who only wants `name` records never pays to
/// parse `GSUB`.
class SfntFile {
  SfntFile._(this.reader, this.sfntVersion, this._tables);

  /// Parses the table directory of a single font.
  ///
  /// [fontIndex] selects a face inside a TrueType Collection (`ttcf`). A plain
  /// font ignores it.
  factory SfntFile.parse(Uint8List bytes, {int fontIndex = 0}) {
    final reader = ByteReader.fromBytes(bytes);
    if (reader.length < 12) {
      throw const FontFormatException('too short to hold an SFNT header');
    }

    var base = 0;
    var version = reader.uint32At(0);

    // TrueType Collection — the real font offsets live behind a directory.
    if (version == _ttcfTag) {
      final numFonts = reader.uint32At(8);
      if (fontIndex < 0 || fontIndex >= numFonts) {
        throw FontFormatException(
          'font index $fontIndex out of range in a $numFonts-font collection',
        );
      }
      base = reader.uint32At(12 + fontIndex * 4);
      version = reader.uint32At(base);
    }

    if (version != 0x00010000 && // TrueType outlines
        version != _trueTag && // legacy Apple 'true'
        version != _otoTag) {
      // 'OTTO' — CFF outlines
      throw FontFormatException(
        'unrecognised sfntVersion 0x${version.toRadixString(16).padLeft(8, "0")}',
      );
    }

    final numTables = reader.uint16At(base + 4);
    final tables = <int, TableRecord>{};
    for (var i = 0; i < numTables; i++) {
      final rec = base + 12 + i * 16;
      final tag = reader.uint32At(rec);
      final offset = reader.uint32At(rec + 8);
      final length = reader.uint32At(rec + 12);

      // A record that points outside the file is a corrupt font, but a record
      // whose *length* overruns is common in the wild (fonts padded wrong by
      // old tooling). Clamp the length, reject the offset.
      if (offset >= reader.length) {
        throw FontFormatException(
          'table ${Tag(tag).asString} starts at $offset, past the '
          '${reader.length}-byte file',
        );
      }
      final clamped = offset + length > reader.length
          ? reader.length - offset
          : length;

      tables[tag] = TableRecord(
        tag: tag,
        checksum: reader.uint32At(rec + 4),
        offset: offset,
        length: clamped,
      );
    }

    return SfntFile._(reader, version, tables);
  }

  /// How many faces a TrueType Collection holds. 1 for a plain font.
  static int faceCount(Uint8List bytes) {
    final reader = ByteReader.fromBytes(bytes);
    if (reader.length < 12) return 0;
    return reader.uint32At(0) == _ttcfTag ? reader.uint32At(8) : 1;
  }

  final ByteReader reader;
  final int sfntVersion;
  final Map<int, TableRecord> _tables;

  /// True when outlines live in `CFF `/`CFF2` rather than `glyf`.
  bool get hasCffOutlines => sfntVersion == _otoTag || has(Tag.cff);

  Iterable<int> get tableTags => _tables.keys;

  bool has(int tag) => _tables.containsKey(tag);

  TableRecord? record(int tag) => _tables[tag];

  /// A reader positioned at the start of [tag], or null when absent.
  ///
  /// The reader shares the whole file buffer, so an offset inside the table is
  /// `table.position + relativeOffset` — which is exactly how the OpenType spec
  /// expresses every subtable offset.
  ByteReader? table(int tag) {
    final rec = _tables[tag];
    return rec == null ? null : reader.at(rec.offset);
  }

  /// The raw bytes of [tag], or null when absent. Used by the subsetter, which
  /// copies tables it does not need to understand.
  Uint8List? tableBytes(int tag) {
    final rec = _tables[tag];
    return rec == null ? null : reader.bytesAt(rec.offset, rec.length);
  }

  /// Throws rather than returning null — for tables a font cannot legally omit.
  ByteReader requireTable(int tag) {
    final t = table(tag);
    if (t == null) {
      throw FontFormatException('font has no ${Tag(tag).asString} table');
    }
    return t;
  }

  static const int _ttcfTag = 0x74746366; // 'ttcf'
  static const int _trueTag = 0x74727565; // 'true'
  static const int _otoTag = 0x4F54544F; // 'OTTO'
}
