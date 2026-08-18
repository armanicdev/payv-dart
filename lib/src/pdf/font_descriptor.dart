/// The `/FontDescriptor` — the font's metrics as PDF wants them stated.
///
/// Everything a reader needs to lay out, substitute or hint the face when it
/// cannot use the embedded program itself: the bounding box, the ascent and
/// descent, the stem weight, and the classification flags.
///
/// One rule governs this whole file, and getting it wrong is THE classic
/// composite-font bug: **every number here is in PDF glyph space, 1000 units
/// per em**, regardless of what the font's own `head.unitsPerEm` says.
/// Vazirmatn is a 2048-unit face, so its numbers are all scaled by 1000/2048 on
/// the way in. Mix the two spaces and nothing throws — the text simply comes
/// out subtly the wrong size, or a reader clips the ascenders, and the cause is
/// four files away from the symptom.
library;

import '../font/open_type_font.dart';
import 'object.dart';

/// PDF's glyph space for a composite font: 1000 units to the em, always
/// (ISO 32000-1 §9.7.4.3). The `/FontMatrix` that could change it does not
/// exist for a `CIDFontType2`.
const int pdfUnitsPerEm = 1000;

/// Converts [value] from a font's design units into PDF glyph space.
///
/// Rounded, not truncated. A half-unit at this scale is a thousandth of an em —
/// invisible — but truncation biases every metric in the same direction, and a
/// column of widths that all lean one way is a visible drift by the end of a
/// line.
int scaleToPdfGlyphSpace(num value, int unitsPerEm) =>
    (value * pdfUnitsPerEm / unitsPerEm).round();

/// `/Flags` bits, ISO 32000-1 Table 123.
///
/// The spec numbers these from 1, which is why [symbolic] — "bit 3" in every
/// piece of prose about it — has the value 4 and not 8. Writing the shifts out
/// here is the cheapest way to stop that off-by-one reaching a file.
abstract final class PdfFontFlags {
  /// Bit 1. Every glyph the same width.
  static const int fixedPitch = 1 << 0; // 1

  /// Bit 2.
  static const int serif = 1 << 1; // 2

  /// Bit 3. The font's encoding is its own, not a standard Latin one.
  ///
  /// Mutually exclusive with [nonsymbolic], and it is this one that an
  /// `Identity-H` composite font wants: the codes in the content stream are
  /// glyph indices, which by definition are not StandardEncoding characters.
  static const int symbolic = 1 << 2; // 4

  /// Bit 4. Cursive/handwritten design.
  static const int script = 1 << 3; // 8

  /// Bit 6. Mutually exclusive with [symbolic].
  static const int nonsymbolic = 1 << 5; // 32

  /// Bit 7.
  static const int italic = 1 << 6; // 64

  /// Bit 17.
  static const int allCap = 1 << 16;

  /// Bit 18.
  static const int smallCap = 1 << 17;

  /// Bit 19.
  static const int forceBold = 1 << 18;
}

/// The classification flags for [font].
///
/// [symbolic] is always set and [nonsymbolic] never is — see the note on
/// [PdfFontFlags.symbolic]. A reader that sees Nonsymbolic on an `Identity-H`
/// font is entitled to go looking for a Latin encoding that is not there.
int fontDescriptorFlags(OpenTypeFont font) {
  var flags = PdfFontFlags.symbolic;
  if (font.post?.isFixedPitch ?? false) flags |= PdfFontFlags.fixedPitch;
  if (_isSerif(font)) flags |= PdfFontFlags.serif;
  if (_isItalic(font)) flags |= PdfFontFlags.italic;
  return flags;
}

/// Whether the face reads as a serif design.
///
/// Taken from PANOSE, which is the only machine-readable answer OpenType has.
/// Byte 0 is the family kind and byte 1 the serif style; serif styles run 2…10
/// and the sans ones start at 11. Only meaningful when byte 0 says Latin Text
/// (2) — for a decorative or symbol family the byte means something else
/// entirely, and reading it anyway is how an Arabic face gets flagged serif.
bool _isSerif(OpenTypeFont font) {
  final panose = font.os2?.panose;
  if (panose == null || panose.length < 2) return false;
  if (panose[0] != 2) return false;
  return panose[1] >= 2 && panose[1] <= 10;
}

/// Three independent places record italic and fonts disagree among them, so
/// any one of them saying so is enough.
bool _isItalic(OpenTypeFont font) {
  if (font.os2?.isItalic ?? false) return true;
  if (font.head.macStyle & 0x0002 != 0) return true;
  return (font.post?.italicAngle ?? 0) != 0;
}

/// The dominant vertical stem width, in PDF glyph space.
///
/// OpenType does not record this — there is no `StemV` field in any table — so
/// every PDF producer estimates it, and this is the long-standing estimate from
/// the weight class: it puts a 400 face at 88 and a 700 face at 166, against
/// Adobe's own 88 for Helvetica and 140 for Helvetica-Bold.
///
/// Note it is NOT scaled by [scaleToPdfGlyphSpace]: the formula is defined in
/// 1000-unit space already. Scaling it again would report a 2048-unit face's
/// stems at half their weight, which is exactly the kind of silent halving this
/// file exists to prevent.
int estimateStemV(int usWeightClass) {
  final weight = usWeightClass <= 0 ? 400 : usWeightClass;
  final t = weight / 65.0;
  return 50 + (t * t).round();
}

/// Vertical metrics in PDF glyph space: ascent above the baseline, descent
/// below it as a NEGATIVE number, and the cap height.
class PdfVerticalMetrics {
  const PdfVerticalMetrics({
    required this.ascent,
    required this.descent,
    required this.capHeight,
    required this.xHeight,
  });

  /// Reads the metrics [font] declares and scales them.
  ///
  /// Which pair to read is a real question, not a formality. `OS/2` carries two
  /// sets: the typographic ones (`sTypo*`), which are the designer's intended
  /// line box, and the Windows ones (`usWin*`), which are clipping bounds and
  /// on a face with tall Arabic marks are considerably larger. `fsSelection`
  /// bit 7 is the foundry saying "use the typographic set"; honour it when it
  /// is set and take the Windows bounds otherwise, because a descriptor whose
  /// ascent is smaller than the ink gets that ink clipped by some readers.
  ///
  /// Note the sign flip. `usWinDescent` is a positive distance below the
  /// baseline while `sTypoDescender` is already negative — the opposite
  /// convention, in the same table. PDF wants negative.
  factory PdfVerticalMetrics.of(OpenTypeFont font) {
    final upem = font.unitsPerEm;
    final os2 = font.os2;

    int ascent;
    int descent;
    if (os2 != null && os2.useTypoMetrics && os2.sTypoAscender != 0) {
      ascent = os2.sTypoAscender;
      descent = os2.sTypoDescender;
    } else if (os2 != null && os2.usWinAscent != 0) {
      ascent = os2.usWinAscent;
      descent = -os2.usWinDescent;
    } else {
      // No usable `OS/2`. The glyph bounding box is a poor line box but it is
      // never smaller than the ink, which is the property that matters.
      ascent = font.head.yMax;
      descent = font.head.yMin;
    }
    if (descent > 0) descent = -descent;

    // `sCapHeight` only exists from `OS/2` version 2. Falling back to the
    // typographic ascender overstates it slightly; falling back to zero would
    // make a reader synthesise small caps at the baseline.
    var capHeight = os2?.sCapHeight ?? 0;
    if (capHeight <= 0) capHeight = os2?.sTypoAscender ?? 0;
    if (capHeight <= 0) capHeight = font.head.yMax;

    return PdfVerticalMetrics(
      ascent: scaleToPdfGlyphSpace(ascent, upem),
      descent: scaleToPdfGlyphSpace(descent, upem),
      capHeight: scaleToPdfGlyphSpace(capHeight, upem),
      xHeight: (os2?.sxHeight ?? 0) > 0
          ? scaleToPdfGlyphSpace(os2!.sxHeight, upem)
          : null,
    );
  }

  final int ascent;

  /// Negative, per §9.8.1.
  final int descent;

  final int capHeight;

  /// Omitted from the descriptor when the font does not declare it.
  final int? xHeight;
}

/// The glyph bounding box, scaled — `[xMin yMin xMax yMax]`.
///
/// Read from `head`, which describes the DESIGN space of the face. For a
/// variable font instanced at a heavy weight the true box is a little larger,
/// and that is accepted: `/FontBBox` is advisory, readers use it to size a
/// substitute face and to decide what to repaint, and no glyph is clipped by it.
PdfArray fontBoundingBox(OpenTypeFont font) {
  final upem = font.unitsPerEm;
  final head = font.head;
  return PdfArray.numbers(<num>[
    scaleToPdfGlyphSpace(head.xMin, upem),
    scaleToPdfGlyphSpace(head.yMin, upem),
    scaleToPdfGlyphSpace(head.xMax, upem),
    scaleToPdfGlyphSpace(head.yMax, upem),
  ]);
}

/// Builds the `/FontDescriptor` for [font].
///
/// [baseFont] must already carry its six-letter subset tag — the descriptor's
/// `/FontName` and the font dictionaries' `/BaseFont` have to agree exactly, or
/// some readers decide the descriptor belongs to a different face and quietly
/// substitute one.
///
/// [fontFile2] is the stream holding the embedded TrueType program. It is
/// required rather than optional because this package embeds, always; a
/// descriptor without a font file describes a face the reader has to find on
/// its own, and on a document someone has to rely on, "whatever Kurdish font
/// this machine happens to have" is not an acceptable outcome.
PdfDict buildFontDescriptor({
  required OpenTypeFont font,
  required String baseFont,
  required PdfRef fontFile2,
}) {
  final metrics = PdfVerticalMetrics.of(font);
  final descriptor = PdfDict(<String, PdfObject>{
    'Type': const PdfName('FontDescriptor'),
    'FontName': PdfName(baseFont),
    'Flags': PdfNumber(fontDescriptorFlags(font)),
    'FontBBox': fontBoundingBox(font),
    'ItalicAngle': PdfNumber(font.post?.italicAngle ?? 0),
    'Ascent': PdfNumber(metrics.ascent),
    'Descent': PdfNumber(metrics.descent),
    'CapHeight': PdfNumber(metrics.capHeight),
    'StemV': PdfNumber(estimateStemV(font.os2?.usWeightClass ?? 400)),
  });
  final xHeight = metrics.xHeight;
  if (xHeight != null) descriptor['XHeight'] = PdfNumber(xHeight);
  descriptor['FontFile2'] = fontFile2;
  return descriptor;
}
