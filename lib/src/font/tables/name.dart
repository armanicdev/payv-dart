/// `name` — the human-readable strings.
///
/// Matters more than it looks: a PDF's `/BaseFont` name and the licence notice
/// an embedding document has to carry both come out of here, and a font ships the same
/// string several times over in several encodings. Picking the wrong record
/// gives a `/BaseFont` full of mojibake, which some viewers refuse to load.
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// One `name` record, already decoded.
class NameRecord {
  const NameRecord({
    required this.platformId,
    required this.encodingId,
    required this.languageId,
    required this.nameId,
    required this.value,
  });

  final int platformId;
  final int encodingId;
  final int languageId;
  final int nameId;
  final String value;

  @override
  String toString() =>
      'NameRecord($nameId @ $platformId/$encodingId/$languageId: "$value")';
}

/// The parsed `name` table.
class NameTable {
  const NameTable._(this.records);

  static NameTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 6)) {
      throw const FontFormatException('name is too short to hold a header');
    }
    final format = r.uint16At(base);
    final count = r.uint16At(base + 2);
    final storage = base + r.uint16At(base + 4);

    if (!r.canRead(base + 6, count * 12)) {
      throw FontFormatException(
        'name claims $count records it does not contain',
      );
    }

    final records = <NameRecord>[];
    for (var i = 0; i < count; i++) {
      final at = base + 6 + i * 12;
      final platformId = r.uint16At(at);
      final encodingId = r.uint16At(at + 2);
      final languageId = r.uint16At(at + 4);
      final nameId = r.uint16At(at + 6);
      final length = r.uint16At(at + 8);
      final offset = storage + r.uint16At(at + 10);

      // A record whose string runs off the end is dropped, not fatal. Fonts
      // with one truncated copyright record are common and the rest of the
      // table is still perfectly usable.
      if (!r.canRead(offset, length)) continue;

      records.add(
        NameRecord(
          platformId: platformId,
          encodingId: encodingId,
          languageId: languageId,
          nameId: nameId,
          value: _decode(r.bytesAt(offset, length), platformId),
        ),
      );
    }

    // Format 1 appends a language-tag array after the records. Nothing here
    // reads it — those tags only name languages for records with languageId
    // >= 0x8000, and every id this table exposes is a language-neutral one.
    assert(format == 0 || format == 1);

    return NameTable._(List.unmodifiable(records));
  }

  /// Every decoded record, in file order.
  final List<NameRecord> records;

  /// The best record for [nameId], or null.
  ///
  /// "Best" is the Windows Unicode BMP record (3,1) first, then any Unicode
  /// platform record, then Macintosh — the order rasterisers use. Within a
  /// platform, English wins, because a `/BaseFont` name has to be ASCII-safe
  /// and the localised copies of nameId 1 are exactly what break that.
  ///
  /// [platformId] pins the search to one platform when a caller needs the
  /// Macintosh spelling specifically.
  String? get(int nameId, {int? platformId}) {
    NameRecord? best;
    var bestScore = 1 << 30;
    for (final rec in records) {
      if (rec.nameId != nameId) continue;
      if (platformId != null && rec.platformId != platformId) continue;
      final score = _score(rec);
      if (score < bestScore) {
        bestScore = score;
        best = rec;
      }
    }
    return best?.value;
  }

  /// nameId 6. The PDF `/BaseFont` value.
  String? get postScriptName => get(6);

  /// nameId 16 when present, else 1.
  ///
  /// A font family that splits into more than four styles has to lie in
  /// nameId 1 to stay compatible with old Windows menus — "Vazirmatn Medium"
  /// becomes its own family there — and states the truth in nameId 16. So 16
  /// wins whenever it exists.
  String? get familyName => get(16) ?? get(1);

  /// nameId 17 when present, else 2. Same reason as [familyName].
  String? get subfamilyName => get(17) ?? get(2);

  /// nameId 13 — the licence text. A document embedding a font is
  /// obliged to honour it, so it is surfaced rather than buried.
  String? get licenseDescription => get(13);

  /// nameId 14 — the licence URL.
  String? get licenseUrl => get(14);

  String? get copyright => get(0);

  String? get version => get(5);

  String? get manufacturer => get(8);

  String? get designer => get(9);

  /// Lower is better.
  static int _score(NameRecord r) {
    final platform = switch ((r.platformId, r.encodingId)) {
      (3, 1) => 0, // Windows, Unicode BMP
      (3, 10) => 1, // Windows, Unicode full
      (0, _) => 2, // Unicode platform, any encoding
      (3, _) => 3, // Windows, something else (symbol)
      (1, 0) => 4, // Macintosh Roman
      _ => 5,
    };
    // 0x0409 is Windows US English, 0 is Macintosh English.
    final english = switch ((r.platformId, r.languageId)) {
      (3, 0x0409) => 0,
      (1, 0) => 0,
      (0, _) => 0, // Unicode platform records carry no language
      _ => 1,
    };
    return platform * 2 + english;
  }

  /// Decodes a raw name string.
  ///
  /// Platforms 0 (Unicode) and 3 (Windows) are UTF-16BE, including Windows
  /// Symbol — that encoding changes what the code units *mean* to a rasteriser,
  /// not how they are stored.
  ///
  /// Platform 1 is Macintosh, whose encoding 0 is Mac Roman, not Latin-1. They
  /// agree on 0x00…0x7F and diverge above it, so decoding as Latin-1 is exact
  /// for the ASCII range every id this class exposes actually uses, and merely
  /// cosmetically wrong for an accented Mac-only copyright line. Shipping the
  /// full 128-entry Mac Roman table to fix that would be dead weight, because
  /// any font with a non-ASCII name also ships a platform 3 copy that outranks
  /// this one.
  static String _decode(Uint8List bytes, int platformId) {
    if (platformId == 1) return String.fromCharCodes(bytes);

    // Odd length cannot be UTF-16; treat the trailing byte as absent rather
    // than reading past the record.
    final units = bytes.length >> 1;
    final out = Uint16List(units);
    for (var i = 0; i < units; i++) {
      out[i] = (bytes[i * 2] << 8) | bytes[i * 2 + 1];
    }
    // Dart strings ARE UTF-16, so surrogate pairs pass through unchanged and
    // need no decoding step of their own.
    return String.fromCharCodes(out);
  }

  @override
  String toString() =>
      'NameTable(${records.length} records, family: $familyName)';
}
