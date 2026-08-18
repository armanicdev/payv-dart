/// `OS/2` — metrics, classification, and the embedding licence bits.
///
/// Two jobs here. The first is metrics the PDF font descriptor requires by
/// name: `CapHeight`, `XHeight`, `Ascent`, `Descent`, `StemV` inputs, the
/// symbolic/serif flags. The second is [fsType] — the foundry's machine-
/// readable answer to "may this file be embedded in a document at all", which
/// a tool that embeds fonts into PDFs is obliged to actually read.
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// The parsed `OS/2` table. Versions 0 through 5.
class Os2Table {
  const Os2Table._({
    required this.version,
    required this.xAvgCharWidth,
    required this.usWeightClass,
    required this.usWidthClass,
    required this.fsType,
    required this.ySubscriptXSize,
    required this.ySubscriptYSize,
    required this.ySubscriptXOffset,
    required this.ySubscriptYOffset,
    required this.ySuperscriptXSize,
    required this.ySuperscriptYSize,
    required this.ySuperscriptXOffset,
    required this.ySuperscriptYOffset,
    required this.yStrikeoutSize,
    required this.yStrikeoutPosition,
    required this.sFamilyClass,
    required this.panose,
    required this.ulUnicodeRange1,
    required this.ulUnicodeRange2,
    required this.ulUnicodeRange3,
    required this.ulUnicodeRange4,
    required this.achVendID,
    required this.fsSelection,
    required this.usFirstCharIndex,
    required this.usLastCharIndex,
    required this.sTypoAscender,
    required this.sTypoDescender,
    required this.sTypoLineGap,
    required this.usWinAscent,
    required this.usWinDescent,
    required this.ulCodePageRange1,
    required this.ulCodePageRange2,
    required this.sxHeight,
    required this.sCapHeight,
    required this.usDefaultChar,
    required this.usBreakChar,
    required this.usMaxContext,
    required this.usLowerOpticalPointSize,
    required this.usUpperOpticalPointSize,
  });

  /// Parses the table [r] is positioned at.
  ///
  /// [tableLength] is the length the SFNT directory records for `OS/2`
  /// (`SfntFile.record(Tag.os2)!.length`). PASS IT. Without it the version-tail
  /// guards below can only bound against the end of the FILE, and `OS/2` is
  /// never the last table in a real font — so every guard passes and a version
  /// word claiming more than the body holds reads the NEXT table's bytes as
  /// metrics. Measured on Vazirmatn with its version word flipped to 5:
  /// `usLowerOpticalPointSize` decoded to 908 out of `post`. `sCapHeight` and
  /// `sxHeight` go straight into the PDF font descriptor, so the fabrication
  /// reaches the page.
  static Os2Table parse(ByteReader r, {int? tableLength}) {
    final base = r.position;
    // How many bytes this table actually has: the directory's length when the
    // caller supplied it, otherwise everything to the end of the file.
    final toFileEnd = r.length - base;
    final available = tableLength == null || tableLength > toFileEnd
        ? toFileEnd
        : tableLength;

    // 78 bytes is the version 0 table, and every later version only appends.
    if (available < 78) {
      throw const FontFormatException(
        'OS/2 is shorter than its version 0 form',
      );
    }
    final version = r.uint16At(base);

    // Length is checked per version rather than trusted from the version word,
    // because fonts do ship a version 4 header over a version 1 body. Reading
    // the missing tail would silently produce a capHeight from whatever table
    // follows — and the PDF descriptor would carry it.
    final hasV1 = version >= 1 && available >= 86;
    final hasV2 = version >= 2 && available >= 96;
    final hasV5 = version >= 5 && available >= 100;

    return Os2Table._(
      version: version,
      xAvgCharWidth: r.int16At(base + 2),
      usWeightClass: r.uint16At(base + 4),
      usWidthClass: r.uint16At(base + 6),
      fsType: r.uint16At(base + 8),
      ySubscriptXSize: r.int16At(base + 10),
      ySubscriptYSize: r.int16At(base + 12),
      ySubscriptXOffset: r.int16At(base + 14),
      ySubscriptYOffset: r.int16At(base + 16),
      ySuperscriptXSize: r.int16At(base + 18),
      ySuperscriptYSize: r.int16At(base + 20),
      ySuperscriptXOffset: r.int16At(base + 22),
      ySuperscriptYOffset: r.int16At(base + 24),
      yStrikeoutSize: r.int16At(base + 26),
      yStrikeoutPosition: r.int16At(base + 28),
      sFamilyClass: r.int16At(base + 30),
      panose: r.bytesAt(base + 32, 10),
      ulUnicodeRange1: r.uint32At(base + 42),
      ulUnicodeRange2: r.uint32At(base + 46),
      ulUnicodeRange3: r.uint32At(base + 50),
      ulUnicodeRange4: r.uint32At(base + 54),
      achVendID: r.uint32At(base + 58),
      fsSelection: r.uint16At(base + 62),
      usFirstCharIndex: r.uint16At(base + 64),
      usLastCharIndex: r.uint16At(base + 66),
      sTypoAscender: r.int16At(base + 68),
      sTypoDescender: r.int16At(base + 70),
      sTypoLineGap: r.int16At(base + 72),
      usWinAscent: r.uint16At(base + 74),
      usWinDescent: r.uint16At(base + 76),
      ulCodePageRange1: hasV1 ? r.uint32At(base + 78) : 0,
      ulCodePageRange2: hasV1 ? r.uint32At(base + 82) : 0,
      sxHeight: hasV2 ? r.int16At(base + 86) : 0,
      sCapHeight: hasV2 ? r.int16At(base + 88) : 0,
      usDefaultChar: hasV2 ? r.uint16At(base + 90) : 0,
      usBreakChar: hasV2 ? r.uint16At(base + 92) : 0,
      usMaxContext: hasV2 ? r.uint16At(base + 94) : 0,
      usLowerOpticalPointSize: hasV5 ? r.uint16At(base + 96) : 0,
      usUpperOpticalPointSize: hasV5 ? r.uint16At(base + 98) : 0,
    );
  }

  final int version;

  final int xAvgCharWidth;
  final int usWeightClass;
  final int usWidthClass;

  /// The embedding licence bitfield. See [allowsEmbedding].
  final int fsType;

  final int ySubscriptXSize;
  final int ySubscriptYSize;
  final int ySubscriptXOffset;
  final int ySubscriptYOffset;
  final int ySuperscriptXSize;
  final int ySuperscriptYSize;
  final int ySuperscriptXOffset;
  final int ySuperscriptYOffset;
  final int yStrikeoutSize;
  final int yStrikeoutPosition;

  final int sFamilyClass;

  /// The 10 PANOSE classification bytes. Byte 0 is the family kind and byte 1
  /// the serif style — the PDF descriptor's `/Flags` serif bit reads them.
  final Uint8List panose;

  final int ulUnicodeRange1;
  final int ulUnicodeRange2;
  final int ulUnicodeRange3;
  final int ulUnicodeRange4;

  /// Four-character foundry tag, packed. Space-filled when unregistered.
  final int achVendID;

  final int fsSelection;
  final int usFirstCharIndex;
  final int usLastCharIndex;

  /// The typographic metrics. Prefer these over `hhea` when [useTypoMetrics]
  /// is set — that bit is the font telling you its `hhea` values exist only to
  /// keep old Windows clipping behaviour and are not its real line box.
  final int sTypoAscender;
  final int sTypoDescender;
  final int sTypoLineGap;

  /// Windows clipping bounds. Positive numbers, both of them — [usWinDescent]
  /// is a distance below the baseline, not a negative coordinate, which is the
  /// opposite sign convention to [sTypoDescender].
  final int usWinAscent;
  final int usWinDescent;

  final int ulCodePageRange1;
  final int ulCodePageRange2;

  /// Version 2+ only; 0 when the font predates it. The PDF font descriptor
  /// wants both, and 0 is the value it treats as "unknown".
  final int sxHeight;
  final int sCapHeight;

  final int usDefaultChar;
  final int usBreakChar;
  final int usMaxContext;

  final int usLowerOpticalPointSize;
  final int usUpperOpticalPointSize;

  /// True when the font permits being embedded in a document.
  ///
  /// fsType is a bitfield, not an enum, and reading it as one is the usual
  /// mistake. The rule that matters:
  ///
  ///  * 0 — installable. Anything goes.
  ///  * bit 1 (0x0002) — restricted. No embedding of any kind. This is the
  ///    only value that forbids it outright.
  ///  * bit 2 (0x0004) preview-and-print and bit 3 (0x0008) editable both
  ///    permit embedding into a document; they constrain what the *reader* may
  ///    then do with it, which is the viewer's business, not ours.
  ///  * bit 9 (0x0200) — bitmap embedding only. `payv` embeds outlines and
  ///    nothing else, so this is a refusal for us specifically even though a
  ///    bitmap-capable tool could proceed.
  bool get allowsEmbedding =>
      fsType & _restrictedLicense == 0 && fsType & _bitmapEmbeddingOnly == 0;

  /// True when the font permits shipping a subset rather than the whole file.
  ///
  /// Bit 8 (0x0100) is "no subsetting". Note the number: the OpenType spec
  /// assigns 0x0100 to no-subsetting and 0x0200 to bitmap-only, and swapping
  /// the two — an easy slip — would let a font that forbids subsetting be
  /// subset into a public document.
  bool get allowsSubsetting => allowsEmbedding && fsType & _noSubsetting == 0;

  /// True when the foundry asks that [sTypoAscender] and friends drive line
  /// layout instead of the `hhea` values. fsSelection bit 7.
  bool get useTypoMetrics => fsSelection & 0x0080 != 0;

  bool get isItalic => fsSelection & 0x0001 != 0;

  bool get isBold => fsSelection & 0x0020 != 0;

  bool get isRegular => fsSelection & 0x0040 != 0;

  bool get isOblique => fsSelection & 0x0200 != 0;

  /// [achVendID] as its four characters, for diagnostics.
  String get vendorId => String.fromCharCodes([
    (achVendID >> 24) & 0xFF,
    (achVendID >> 16) & 0xFF,
    (achVendID >> 8) & 0xFF,
    achVendID & 0xFF,
  ]);

  static const int _restrictedLicense = 0x0002;
  static const int _noSubsetting = 0x0100;
  static const int _bitmapEmbeddingOnly = 0x0200;

  @override
  String toString() =>
      'Os2Table(v$version, weight $usWeightClass, fsType $fsType, '
      'cap $sCapHeight, x $sxHeight)';
}
