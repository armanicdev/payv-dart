/// `head` — the font header.
///
/// Two of its fields gate the rest of the parse: [unitsPerEm] is the
/// denominator for every metric in the file, and [indexToLocFormat] decides
/// whether `loca` is an array of uint16s or uint32s. Get the second one wrong
/// and every glyph outline in the font reads from the wrong place, silently.
library;

import '../../util/byte_reader.dart';

/// The parsed `head` table. 54 bytes, so it is read eagerly and in full.
class HeadTable {
  const HeadTable._({
    required this.majorVersion,
    required this.minorVersion,
    required this.fontRevision,
    required this.checkSumAdjustment,
    required this.flags,
    required this.unitsPerEm,
    required this.createdSeconds,
    required this.modifiedSeconds,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
    required this.macStyle,
    required this.lowestRecPpem,
    required this.fontDirectionHint,
    required this.indexToLocFormat,
    required this.glyphDataFormat,
  });

  /// Parses the table [r] is positioned at.
  static HeadTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 54)) {
      throw const FontFormatException('head is shorter than its 54 bytes');
    }

    // The magic number is the one cheap structural check this parser gets. A
    // table directory can point `head` at arbitrary bytes and every field below
    // would still "parse"; the magic is what turns that into an exception
    // instead of a font with a unitsPerEm of 19023.
    final magic = r.uint32At(base + 12);
    if (magic != _magicNumber) {
      throw FontFormatException(
        'head.magicNumber is 0x${magic.toRadixString(16)}, not 0x5F0F3CF5',
      );
    }

    final unitsPerEm = r.uint16At(base + 18);
    // Spec range. Zero in particular has to die here: it reaches the shaper as
    // a division and produces infinities all the way into the PDF.
    if (unitsPerEm < 16 || unitsPerEm > 16384) {
      throw FontFormatException(
        'head.unitsPerEm $unitsPerEm is outside the legal 16…16384',
      );
    }

    final indexToLocFormat = r.int16At(base + 50);
    if (indexToLocFormat != 0 && indexToLocFormat != 1) {
      throw FontFormatException(
        'head.indexToLocFormat $indexToLocFormat is neither short nor long',
      );
    }

    return HeadTable._(
      majorVersion: r.uint16At(base),
      minorVersion: r.uint16At(base + 2),
      fontRevision: r.uint32At(base + 4),
      checkSumAdjustment: r.uint32At(base + 8),
      flags: r.uint16At(base + 16),
      unitsPerEm: unitsPerEm,
      createdSeconds: _longDateTime(r, base + 20),
      modifiedSeconds: _longDateTime(r, base + 28),
      xMin: r.int16At(base + 36),
      yMin: r.int16At(base + 38),
      xMax: r.int16At(base + 40),
      yMax: r.int16At(base + 42),
      macStyle: r.uint16At(base + 44),
      lowestRecPpem: r.uint16At(base + 46),
      fontDirectionHint: r.int16At(base + 48),
      indexToLocFormat: indexToLocFormat,
      glyphDataFormat: r.int16At(base + 52),
    );
  }

  final int majorVersion;
  final int minorVersion;

  /// `fontRevision`, kept as the raw Fixed 16.16 word. The PDF writer stamps it
  /// into the font descriptor verbatim, and rounding it through a double first
  /// would make two builds of the same font compare unequal.
  final int fontRevision;

  final int checkSumAdjustment;

  /// Bit 0 says the baseline is at y=0, bit 1 that the left sidebearing is at
  /// x=0 — the two the outline pipeline actually branches on.
  final int flags;

  /// Design units per em. Every unscaled number in `payv` is in these.
  final int unitsPerEm;

  /// Seconds since 1904-01-01 UTC, per `LONGDATETIME`.
  final int createdSeconds;
  final int modifiedSeconds;

  final int xMin;
  final int yMin;
  final int xMax;
  final int yMax;

  final int macStyle;
  final int lowestRecPpem;
  final int fontDirectionHint;

  /// 0 = `loca` holds uint16 half-offsets, 1 = uint32 byte offsets.
  final int indexToLocFormat;

  final int glyphDataFormat;

  /// [fontRevision] as the human number a foundry writes ("33.005").
  double get fontRevisionValue => fontRevision / 65536.0;

  bool get isBold => macStyle & 0x0001 != 0;

  bool get isItalic => macStyle & 0x0002 != 0;

  bool get baselineAtY0 => flags & 0x0001 != 0;

  DateTime get created => _epoch.add(Duration(seconds: createdSeconds));

  DateTime get modified => _epoch.add(Duration(seconds: modifiedSeconds));

  /// Reads a `LONGDATETIME` without ever touching a 64-bit integer.
  ///
  /// `payv` compiles to JavaScript, where `int` is a double and
  /// `ByteData.getInt64` does not exist at all. Splitting the read into two
  /// uint32s and recombining with a multiply keeps the value exact for every
  /// timestamp under 2^53 seconds — i.e. every date a font will ever carry —
  /// and keeps this file running on the web target.
  static int _longDateTime(ByteReader r, int offset) {
    final high = r.uint32At(offset);
    final low = r.uint32At(offset + 4);
    return high * 4294967296 + low;
  }

  static const int _magicNumber = 0x5F0F3CF5;

  /// 1904-01-01T00:00:00Z, the Mac epoch `LONGDATETIME` counts from.
  static final DateTime _epoch = DateTime.utc(1904);

  @override
  String toString() =>
      'HeadTable(unitsPerEm: $unitsPerEm, loca: '
      '${indexToLocFormat == 0 ? "short" : "long"}, '
      'bbox: $xMin $yMin $xMax $yMax)';
}
