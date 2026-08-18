/// `payv` — a pure-Dart OpenType shaping engine and vector PDF writer.
///
/// Renders complex scripts by executing the font's own `GSUB`/`GPOS` tables,
/// which is what lets it reach glyphs that have no Unicode codepoint at all —
/// the Kurdish Sorani letters ڕ ڵ ە ێ and the ڵ+ا ligature, none of which any
/// presentation-form-based library can produce. See `doc/DESIGN.md`.
///
/// ```dart
/// final font = PayvFont.load(await File('Vazirmatn.ttf').readAsBytes());
/// final doc = PayvDocument(language: 'ckb');
/// final page = doc.addPage();
///
/// page.text(
///   'ژمارەی ناسنامە',
///   x: page.width - 40,
///   y: page.height - 80,
///   style: TextStyle(font: font.weight(600), size: 14),
/// );
///
/// await File('out.pdf').writeAsBytes(doc.save());
/// ```
///
/// Zero runtime dependencies, no FFI, no platform channels — it runs in a
/// Flutter app, on a server, in a CLI and on the web.
// The exports below are grouped by LAYER — everyday API, shaping, font
// engineering — with a heading on each. That grouping is the point of the file:
// it tells a reader which third of the package they need. Alphabetising across
// the groups would flatten it into one undifferentiated list.
// ignore_for_file: directives_ordering
library;

// ── the everyday API ──────────────────────────────────────────────────────────
export 'src/api/document.dart' show PageFormat, PayvDocument, PayvPage;
export 'src/api/text_style.dart'
    show
        FontFeature,
        PdfRect,
        PayvFont,
        PayvTextAlign,
        PayvTextDirection,
        TextMetrics,
        TextRenderMode,
        TextStyle;
export 'src/pdf/graphics_state.dart' show PdfColor;

// ── the shaping layer ─────────────────────────────────────────────────────────
//
// Exported because this package is meant to be built on. If you want shaped
// glyphs for a canvas, a printer driver or your own layout engine, take them —
// you should not have to fork this to avoid the PDF half.
export 'src/font/glyph_path.dart' show GlyphPath, PathCommand;
export 'src/font/open_type_font.dart' show OpenTypeFont;
export 'src/font/sfnt.dart' show SfntFile, TableRecord;
export 'src/shaping/glyph_buffer.dart'
    show GlyphBuffer, GlyphInfo, GlyphPosition, TextDirection;
export 'src/shaping/shaper.dart' show ShapedRun, Shaper;
export 'src/text/bidi.dart' show Bidi, BidiResult, BidiRun;
export 'src/text/script_itemizer.dart' show ScriptItemizer, ScriptRun;
export 'src/util/byte_reader.dart' show FontFormatException;
export 'src/util/tag.dart' show Tag;

// ── the font-engineering layer ────────────────────────────────────────────────
export 'src/font/instancer.dart' show Instancer;
export 'src/font/subset.dart' show FontSubset, Subsetter;
export 'src/layout/text_engine.dart' show MissingGlyph, MissingGlyphException;
export 'src/pdf/cid_font.dart'
    show CidFontEmbedder, EmbeddedFont, FontEmbeddingNotPermittedException;
