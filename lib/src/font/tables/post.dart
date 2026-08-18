/// `post` — PostScript metadata and glyph names.
///
/// [italicAngle], [underlinePosition] and [isFixedPitch] go straight into the
/// PDF font descriptor. [glyphName] is the interesting part: it is the only
/// place a `glyf` font records what its glyphs are called, and it is how
/// Vazirmatn's GSUB-only Sorani glyphs — `lamVabove_alef.isol`,
/// `uni06B5.init`, `uni06D5.fina` — can be named in a test failure instead of
/// appearing as a bare number nobody can check.
library;

import 'dart:typed_data';

import '../../util/byte_reader.dart';

/// The parsed `post` table.
class PostTable {
  const PostTable._({
    required this.version,
    required this.italicAngleFixed,
    required this.underlinePosition,
    required this.underlineThickness,
    required this.isFixedPitch,
    required this.minMemType42,
    required this.maxMemType42,
    required this.minMemType1,
    required this.maxMemType1,
    required this.glyphNameIndex,
    required this.customNames,
  });

  static PostTable parse(ByteReader r) {
    final base = r.position;
    if (!r.canRead(base, 32)) {
      throw const FontFormatException(
        'post is shorter than its 32-byte header',
      );
    }
    final version = r.uint32At(base);

    Uint16List? glyphNameIndex;
    var customNames = const <String>[];

    if (version == 0x00020000) {
      final result = _parseVersion2(r, base);
      glyphNameIndex = result.$1;
      customNames = result.$2;
    } else if (version == 0x00025000) {
      glyphNameIndex = _parseVersion25(r, base);
    }

    return PostTable._(
      version: version,
      italicAngleFixed: r.int32At(base + 4),
      underlinePosition: r.int16At(base + 8),
      underlineThickness: r.int16At(base + 10),
      isFixedPitch: r.uint32At(base + 12) != 0,
      minMemType42: r.uint32At(base + 16),
      maxMemType42: r.uint32At(base + 20),
      minMemType1: r.uint32At(base + 24),
      maxMemType1: r.uint32At(base + 28),
      glyphNameIndex: glyphNameIndex,
      customNames: customNames,
    );
  }

  /// Raw Fixed 16.16 version word: 0x00010000, 0x00020000, 0x00025000,
  /// 0x00030000 or 0x00040000.
  final int version;

  /// [italicAngle] as the raw Fixed word, for byte-exact round-tripping.
  final int italicAngleFixed;

  final int underlinePosition;
  final int underlineThickness;
  final bool isFixedPitch;

  final int minMemType42;
  final int maxMemType42;
  final int minMemType1;
  final int maxMemType1;

  /// Per-glyph index into [standardMacGlyphNames] (< 258) or into
  /// [customNames] (>= 258). Null for versions that carry no names.
  final Uint16List? glyphNameIndex;

  /// The Pascal strings that follow a version 2.0 name index.
  final List<String> customNames;

  /// Counter-clockwise italic angle in degrees. Negative for a normal
  /// right-leaning italic, which is the sign convention PDF's `/ItalicAngle`
  /// also uses — so it passes through unchanged.
  double get italicAngle => italicAngleFixed / 65536.0;

  /// True when this table can name glyphs at all. Version 1.0 counts: it has
  /// no index array precisely because every name is implied.
  bool get hasGlyphNames => version == 0x00010000 || glyphNameIndex != null;

  /// PostScript name of [glyphId], or null when the font does not record one.
  ///
  /// Version 3.0 is the common "no names" case and returns null for every
  /// glyph — that is not an error, it is the version most modern fonts ship to
  /// save space. Version 4.0 (Apple) stores character codes rather than names
  /// and also returns null.
  String? glyphName(int glyphId) {
    if (glyphId < 0) return null;

    if (version == 0x00010000) {
      // Version 1.0 means "the glyph order IS the standard Macintosh order",
      // so there is no index array at all — the glyph id is the index.
      return glyphId < standardMacGlyphNames.length
          ? standardMacGlyphNames[glyphId]
          : null;
    }

    final index = glyphNameIndex;
    if (index == null || glyphId >= index.length) return null;
    final i = index[glyphId];
    if (i < standardMacGlyphNames.length) return standardMacGlyphNames[i];
    final custom = i - standardMacGlyphNames.length;
    return custom < customNames.length ? customNames[custom] : null;
  }

  /// Version 2.0: a per-glyph index followed by a run of Pascal strings.
  ///
  /// The string run has no count of its own — it is read until the table ends.
  /// The table end is not knowable from this reader (it shares the whole file
  /// buffer), so the loop is bounded by the highest custom index the glyph
  /// array actually references. That is a tighter bound than the file, and it
  /// stops the parser from swallowing the next table as glyph names.
  static (Uint16List, List<String>) _parseVersion2(ByteReader r, int base) {
    if (!r.canRead(base + 32, 2)) {
      throw const FontFormatException('post 2.0 has no glyph count');
    }
    final numberOfGlyphs = r.uint16At(base + 32);
    if (!r.canRead(base + 34, numberOfGlyphs * 2)) {
      throw FontFormatException(
        'post 2.0 claims $numberOfGlyphs name indices it does not contain',
      );
    }
    final index = r.at(base + 34).readUint16List(numberOfGlyphs);

    var highest = -1;
    for (final i in index) {
      final custom = i - standardMacGlyphNames.length;
      if (custom > highest) highest = custom;
    }

    final names = <String>[];
    var p = base + 34 + numberOfGlyphs * 2;
    while (names.length <= highest && r.canRead(p, 1)) {
      final len = r.uint8At(p);
      if (!r.canRead(p + 1, len)) break;
      // Glyph names are ASCII by specification, so byte-per-character is exact.
      names.add(String.fromCharCodes(r.bytesAt(p + 1, len)));
      p += 1 + len;
    }

    return (index, names);
  }

  /// Version 2.5: deprecated in 1998 and still in the wild. Each glyph carries
  /// a signed delta from its own id into the standard order, which lets a font
  /// permute the Macintosh order without spelling any name out.
  static Uint16List? _parseVersion25(ByteReader r, int base) {
    if (!r.canRead(base + 32, 2)) return null;
    final numberOfGlyphs = r.uint16At(base + 32);
    if (!r.canRead(base + 34, numberOfGlyphs)) return null;

    final index = Uint16List(numberOfGlyphs);
    for (var g = 0; g < numberOfGlyphs; g++) {
      final resolved = g + r.int8At(base + 34 + g);
      // Out-of-range deltas exist in broken fonts; .notdef is the safe answer.
      index[g] = resolved >= 0 && resolved < standardMacGlyphNames.length
          ? resolved
          : 0;
    }
    return index;
  }

  @override
  String toString() =>
      'PostTable(v0x${version.toRadixString(16)}, '
      'italic $italicAngle, names: $hasGlyphNames)';

  /// The 258 standard Macintosh glyph names, in order.
  ///
  /// A `post` 2.0 index below 258 refers into this list rather than spelling
  /// the name out, which is why every parser has to carry it verbatim. The
  /// order is normative — it is a fixed list from the 1990s, not the Mac Roman
  /// codepage — so it is written out rather than derived from anything.
  // dart format off
  static const List<String> standardMacGlyphNames = <String>[
    '.notdef', '.null', 'nonmarkingreturn', 'space', 'exclam', 'quotedbl',
    'numbersign', 'dollar', 'percent', 'ampersand', 'quotesingle', 'parenleft',
    'parenright', 'asterisk', 'plus', 'comma', 'hyphen', 'period', 'slash',
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'colon', 'semicolon', 'less', 'equal', 'greater', 'question', 'at',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'bracketleft',
    'backslash', 'bracketright', 'asciicircum', 'underscore', 'grave', 'a',
    'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p',
    'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'braceleft', 'bar',
    'braceright', 'asciitilde', 'Adieresis', 'Aring', 'Ccedilla', 'Eacute',
    'Ntilde', 'Odieresis', 'Udieresis', 'aacute', 'agrave', 'acircumflex',
    'adieresis', 'atilde', 'aring', 'ccedilla', 'eacute', 'egrave',
    'ecircumflex', 'edieresis', 'iacute', 'igrave', 'icircumflex', 'idieresis',
    'ntilde', 'oacute', 'ograve', 'ocircumflex', 'odieresis', 'otilde',
    'uacute', 'ugrave', 'ucircumflex', 'udieresis', 'dagger', 'degree', 'cent',
    'sterling', 'section', 'bullet', 'paragraph', 'germandbls', 'registered',
    'copyright', 'trademark', 'acute', 'dieresis', 'notequal', 'AE', 'Oslash',
    'infinity', 'plusminus', 'lessequal', 'greaterequal', 'yen', 'mu',
    'partialdiff', 'summation', 'product', 'pi', 'integral', 'ordfeminine',
    'ordmasculine', 'Omega', 'ae', 'oslash', 'questiondown', 'exclamdown',
    'logicalnot', 'radical', 'florin', 'approxequal', 'Delta', 'guillemotleft',
    'guillemotright', 'ellipsis', 'nonbreakingspace', 'Agrave', 'Atilde',
    'Otilde', 'OE', 'oe', 'endash', 'emdash', 'quotedblleft', 'quotedblright',
    'quoteleft', 'quoteright', 'divide', 'lozenge', 'ydieresis', 'Ydieresis',
    'fraction', 'currency', 'guilsinglleft', 'guilsinglright', 'fi', 'fl',
    'daggerdbl', 'periodcentered', 'quotesinglbase', 'quotedblbase',
    'perthousand', 'Acircumflex', 'Ecircumflex', 'Aacute', 'Edieresis',
    'Egrave', 'Iacute', 'Icircumflex', 'Idieresis', 'Igrave', 'Oacute',
    'Ocircumflex', 'apple', 'Ograve', 'Uacute', 'Ucircumflex', 'Ugrave',
    'dotlessi', 'circumflex', 'tilde', 'macron', 'breve', 'dotaccent', 'ring',
    'cedilla', 'hungarumlaut', 'ogonek', 'caron', 'Lslash', 'lslash', 'Scaron',
    'scaron', 'Zcaron', 'zcaron', 'brokenbar', 'Eth', 'eth', 'Yacute',
    'yacute', 'Thorn', 'thorn', 'minus', 'multiply', 'onesuperior',
    'twosuperior', 'threesuperior', 'onehalf', 'onequarter', 'threequarters',
    'franc', 'Gbreve', 'gbreve', 'Idotaccent', 'Scedilla', 'scedilla',
    'Cacute', 'cacute', 'Ccaron', 'ccaron', 'dcroat',
  ];
  // dart format on
}
