/// [TextEngine] — shaped text onto a PDF page.
///
/// The whole path from a Dart [String] to ink:
///
///     text
///       → scalars, bidi levels, script runs
///       → Shaper, once per (direction, script) run
///       → runs laid out in VISUAL order along the baseline
///       → a positioned program of glyph ids, held until the subset exists
///       → at save: CIDs from the embedder, then BT / Tf / Tm / TJ / ET
///
/// Three invariants in here are worth more than the rest of the file, because
/// each looks like a bug to anyone who has not measured it:
///
///  1. **RTL glyphs go into the content stream in VISUAL order.** Every
///     extractor — pdftotext, mutool, pypdf, Acrobat — assumes a PDF stores
///     glyphs visually and runs its OWN bidi pass over what it finds. Store
///     logical order and the reader who copies their Kurdish out of a receipt
///     gets it backwards. The shaper already reverses an RTL run and
///     `BidiResult.visualRuns` already orders the runs, so this file's job is
///     to not "helpfully" put either back. What that pass CANNOT reconstruct is
///     a glyph standing for several characters — it reverses the ligature's two
///     letters with the rest of the line — so those glyphs carry an
///     `/ActualText` span as well, and its text is written in visual order for
///     the very same reason. See [TextEngine._program].
///
///  2. **`x` is the START of the line, not its left edge** — left for LTR,
///     RIGHT for RTL. That is what lets one bilingual template place a label at
///     `x: margin` and its Kurdish translation at `x: width - margin` with no
///     conditional anywhere else.
///
///  3. **Nothing is written until [embedFonts].** A glyph's code is its id in
///     the FINAL subset, and the subset is a function of every glyph the whole
///     document drew — so it is not decided until the last page is. Text is
///     therefore laid out eagerly (a caller's [TextMetrics] is exact the moment
///     they ask) and *written* at save. See [_deferred] for what that costs.
library;

import 'dart:typed_data';

import '../api/text_style.dart';
import '../font/open_type_font.dart';
import '../pdf/cid_font.dart';
import '../pdf/document.dart';
import '../pdf/font_descriptor.dart' show pdfUnitsPerEm, scaleToPdfGlyphSpace;
import '../pdf/page.dart';
import '../shaping/glyph_buffer.dart';
import '../shaping/shaper.dart';
import '../text/bidi.dart';
import '../text/script_itemizer.dart';
import '../text/unicode.dart';
import '../util/tag.dart';
import 'line_breaker.dart';
import 'paragraph.dart';

/// The seam between layout and font embedding.
///
/// The layout engine knows glyph ids; a PDF content stream wants CIDs and a
/// resource name. This is the whole of what one needs from the other, and it is
/// an interface rather than a direct call so the two halves can be tested
/// apart: a fake encoder makes every assertion in
/// `test/layout/text_engine_test.dart` about *layout* and not about subsetting.
///
/// [CidFontEmbedder] is the real implementation, and
/// [TextEngine.encoderFactory] is where a different one is installed.
abstract interface class GlyphEncoder {
  /// Registers [font] in [page]'s `/Font` resources and returns the name to
  /// pass to `Tf`. Idempotent per page.
  ///
  /// [font] is the [PayvFont], not the raw face, because it carries the
  /// variation instance with it — and a PDF cannot hold a variable font, so
  /// the encoder must instance before it embeds or every document silently
  /// prints at the default weight.
  String attach(PdfPage page, PayvFont font);

  /// Records that [glyphId] is drawn, and what text it came from.
  ///
  /// [codepoints] is the glyph's whole source cluster — both letters of a
  /// ligature, so copying it out loses neither — and EMPTY for the second and
  /// later glyphs of one cluster, so extraction does not repeat the text once
  /// per glyph.
  void use(PayvFont font, int glyphId, List<int> codepoints);

  /// The advance the embedded font will DECLARE for [glyphId], in PDF glyph
  /// space (1000 to the em).
  ///
  /// Not the design-unit advance: the engine emits a `TJ` adjustment only for
  /// the difference between what the viewer will advance by on its own and
  /// what GPOS produced, so it has to ask for the number the `/W` array will
  /// actually carry, rounding and all.
  int declaredWidth(PayvFont font, int glyphId);

  /// Subsets, instances and writes every font used. After this — and only
  /// after it — [cidFor] answers.
  void finishAll();

  /// The final two-byte Identity-H code for [glyphId].
  int cidFor(PayvFont font, int glyphId);
}

/// A character the font could not draw.
class MissingGlyph {
  const MissingGlyph(this.codepoint);

  final int codepoint;

  String get character => String.fromCharCode(codepoint);

  String get label =>
      'U+${codepoint.toRadixString(16).toUpperCase().padLeft(4, "0")} '
      '($character)';

  @override
  String toString() => 'MissingGlyph($label)';
}

/// Thrown when text is drawn with a font that has no glyph for part of it.
///
/// Loud on purpose. The alternative every other library picks — substitute
/// `.notdef` and carry on — ships a receipt full of empty boxes, or worse, one
/// that silently drops a letter from someone's name. A caller who genuinely
/// wants to tolerate it sets [TextEngine.onMissingGlyph] and decides for
/// itself; there is no way to get the tolerant behaviour by accident.
class MissingGlyphException implements Exception {
  const MissingGlyphException(this.glyphs, this.text, this.font);

  final List<MissingGlyph> glyphs;

  /// The string being drawn when the gap was found.
  final String text;

  final PayvFont font;

  @override
  String toString() =>
      'MissingGlyphException: ${font.familyName ?? "the font"} has no glyph '
      'for ${glyphs.map((g) => g.label).join(", ")} in "$text". '
      'Set TextEngine.onMissingGlyph to draw .notdef instead.';
}

/// Lays shaped runs onto pages and owns the font embedding for a document.
class TextEngine {
  TextEngine(this.document);

  /// Swaps the font embedder out. Defaults to [CidFontEmbedder].
  ///
  /// A static hook rather than a constructor argument because `PayvDocument`
  /// builds its engine with nothing but a document, and that signature is
  /// public API.
  static GlyphEncoder Function(PdfDocument document)? encoderFactory;

  final PdfDocument document;

  /// Called for every character the font cannot draw. Installing a handler
  /// switches off [MissingGlyphException] and lets `.notdef` be drawn — an
  /// explicit choice, never a default.
  void Function(MissingGlyph glyph)? onMissingGlyph;

  GlyphEncoder? _encoder;
  final Map<OpenTypeFont, Shaper> _shapers = <OpenTypeFont, Shaper>{};

  /// Content-stream writes, held until [embedFonts].
  ///
  /// The cost of invariant 3 is here: text lands in a page's stream AFTER
  /// anything the caller drew through `PayvPage.graphics`, so text paints over
  /// raw graphics regardless of call order. That is the right way round for
  /// every real document — rules, bands and logos go under the words — but it
  /// is an ordering the caller did not ask for, so it is said out loud rather
  /// than discovered.
  final List<void Function()> _deferred = <void Function()>[];

  GlyphEncoder get _fonts =>
      _encoder ??= (encoderFactory ?? _cidEncoder)(document);

  /// Draws one line at a baseline origin. [x] is the START of the line — its
  /// left edge for LTR, its right edge for RTL.
  TextMetrics drawLine({
    required PdfPage page,
    required String text,
    required double x,
    required double y,
    required TextStyle style,
    required PayvTextDirection direction,
  }) {
    final level = _paragraphLevel(text, direction);
    final line = _layoutLine(text, style, level);
    _report(line.missing, text, style.font);

    if (line.glyphCount > 0) {
      final program = _program(
        page: page,
        line: line,
        style: style,
        // The one place invariant 2 lives. Everything downstream draws left to
        // right from here, because the runs are already in visual order.
        startX: level.isOdd ? x - line.width : x,
        baselineY: y,
        extraWordSpacing: 0,
      );
      _deferred.add(() => _write(program));
    }
    return _metricsOf(line, style);
  }

  /// Wraps [text] inside [rect]. Returns what did not fit, or null.
  String? drawBox({
    required PdfPage page,
    required String text,
    required PdfRect rect,
    required TextStyle style,
    required PayvTextAlign align,
    required PayvTextDirection direction,
    required bool clip,
  }) {
    if (text.isEmpty) return null;

    // The paragraph direction is resolved ONCE, over the whole text, and then
    // imposed on every line. UAX #9 specifies P2/P3 per paragraph and the
    // reordering per line, which is exactly this; resolving per line instead
    // would let a wrapped line that happens to start with a Latin word flip
    // direction in the middle of a paragraph.
    final level = _paragraphLevel(text, direction);
    final rtl = level.isOdd;
    final metrics = LineMetrics.forStyle(style);

    final cache = <(int, int), _LaidLine>{};
    _LaidLine laid(int start, int end) => cache.putIfAbsent((
      start,
      end,
    ), () => _layoutLine(text.substring(start, end), style, level));

    final lines = Paragraph.breakLines(
      text: text,
      maxWidth: rect.width,
      measure: (start, end) => laid(start, end).width,
    );
    final fit = Paragraph.fitInBox(lines: lines, rect: rect, metrics: metrics);

    // Reported once for the whole box: the same missing character reached
    // through several candidate line breaks is one defect, not five.
    final missing = <int>{};
    for (final line in cache.values) {
      missing.addAll(line.missing);
    }
    _report(missing, text, style.font);

    final content = page.content;
    if (clip) {
      _deferred.add(() {
        content.save();
        content.rect(rect.left, rect.bottom, rect.width, rect.height);
        content.clip();
      });
    }

    for (final placed in fit.placed) {
      final line = laid(placed.line.start, placed.line.end);
      if (line.glyphCount == 0) continue;

      final free = rect.width - line.width;
      var resolved = _resolveAlign(align, rtl: rtl);
      var extraWordSpacing = 0.0;
      if (resolved == PayvTextAlign.justify) {
        // Justify by opening the WORD spaces. True Arabic justification
        // stretches the joining strokes themselves (kashida), which needs the
        // font's `jalt`/`stch` machinery and a justification pass this package
        // does not have — see doc/DESIGN.md §4. Word spacing is the honest
        // subset, and it is what a Latin-script line wants anyway.
        if (placed.line.endsParagraph ||
            line.justifiableSpaces == 0 ||
            free <= 0) {
          resolved = rtl ? PayvTextAlign.right : PayvTextAlign.left;
        } else {
          extraWordSpacing = free / line.justifiableSpaces;
        }
      }

      final startX = switch (resolved) {
        PayvTextAlign.right => rect.right - line.width,
        PayvTextAlign.center => rect.left + free / 2,
        _ => rect.left,
      };

      final program = _program(
        page: page,
        line: line,
        style: style,
        startX: startX,
        baselineY: placed.baseline,
        extraWordSpacing: extraWordSpacing,
      );
      _deferred.add(() => _write(program));
    }

    if (clip) _deferred.add(content.restore);

    final overflow = fit.overflowFrom;
    return overflow == null ? null : text.substring(overflow);
  }

  /// Measures without drawing, through the same shaping path as [drawLine].
  ///
  /// Does not throw on a missing glyph — a measurement is a question, not an
  /// act. The draw call that follows it will.
  TextMetrics measure({
    required String text,
    required TextStyle style,
    required PayvTextDirection direction,
  }) => _metricsOf(
    _layoutLine(text, style, _paragraphLevel(text, direction)),
    style,
  );

  /// Subsets and embeds every font used, then writes the text that was waiting
  /// on the subset numbering. Called by `PayvDocument.save`.
  void embedFonts() {
    final fonts = _encoder;
    if (fonts == null) return;
    fonts.finishAll();
    for (final write in _deferred) {
      write();
    }
    _deferred.clear();
  }

  // ── layout ──────────────────────────────────────────────────────────────────

  int _paragraphLevel(String text, PayvTextDirection direction) =>
      switch (direction) {
        PayvTextDirection.ltr => 0,
        PayvTextDirection.rtl => 1,
        PayvTextDirection.auto => Bidi.autoParagraphLevel(toScalars(text).$1),
      };

  /// Shapes one line into segments already in visual (left-to-right) order.
  _LaidLine _layoutLine(String text, TextStyle style, int paragraphLevel) {
    if (text.isEmpty) return _LaidLine.empty;

    final (scalars, _) = toScalars(text);
    final bidi = Bidi.resolve(scalars, paragraphLevel: paragraphLevel);
    final scripts = ScriptItemizer.itemize(scalars);
    final shaper = _shapers.putIfAbsent(
      style.font.raw,
      () => Shaper(style.font.raw),
    );
    final language = _languageTag(style.language);
    final scale = style.size / style.font.raw.unitsPerEm;

    final segments = <_Segment>[];
    final missing = <int>{};
    var width = 0.0;
    var glyphCount = 0;
    var justifiableSpaces = 0;

    for (final run in bidi.visualRuns) {
      final rtl = run.direction == TextDirection.rtl;
      final slices = _sliceByScript(run, scripts);
      // Within one RTL bidi run a later script run sits FURTHER LEFT. The
      // shaper reverses the glyphs inside a run; nothing else reverses the runs
      // themselves, so it has to happen here.
      final ordered = rtl ? slices.reversed.toList() : slices;

      for (final (start, end, script) in ordered) {
        final shaped = shaper.shapeScalars(
          scalars.sublist(start, end),
          script: script,
          language: language,
          direction: run.direction,
          features: style.features,
          clusterBase: start,
        );
        if (shaped.length == 0) continue;

        for (var i = 0; i < shaped.length; i++) {
          final info = shaped.infos[i];
          if (info.glyphId == 0 && _shouldHaveDrawn(info.codepoint)) {
            missing.add(info.codepoint);
          }
          width += _advanceOf(info, shaped.positions[i], scale, style, 0);
          if (LineBreaker.isJustifiableSpace(info.codepoint)) {
            justifiableSpaces++;
          }
        }
        glyphCount += shaped.length;

        segments.add(
          _Segment(
            shaped,
            _clusterSources(shaped, scalars: scalars, sliceEnd: end, rtl: rtl),
          ),
        );
      }
    }

    return _LaidLine(
      segments: segments,
      width: width,
      glyphCount: glyphCount,
      justifiableSpaces: justifiableSpaces,
      scale: scale,
      missing: missing,
    );
  }

  /// Cuts one bidi run at every script boundary inside it, in LOGICAL order.
  static List<(int, int, int)> _sliceByScript(
    BidiRun run,
    List<ScriptRun> scripts,
  ) {
    final out = <(int, int, int)>[];
    for (final script in scripts) {
      final start = run.start > script.start ? run.start : script.start;
      final end = run.end < script.end ? run.end : script.end;
      if (start < end) out.add((start, end, script.scriptTag));
    }
    return out;
  }

  /// The source codepoints each glyph carries into the `ToUnicode` CMap.
  ///
  /// One cluster's characters go on ONE glyph — the logically first, which in
  /// an RTL run is the LAST of the (already reversed) array. Give them to every
  /// glyph of the cluster and a two-glyph cluster extracts as its text twice;
  /// give them to none and the word is unsearchable.
  static List<List<int>> _clusterSources(
    ShapedRun run, {
    required List<int> scalars,
    required int sliceEnd,
    required bool rtl,
  }) {
    final carrier = <int, int>{}; // cluster → the glyph that carries it
    for (var i = 0; i < run.length; i++) {
      final cluster = run.infos[i].cluster;
      // LTR keeps the first sighting, RTL the last: both are the glyph that
      // came first in logical order.
      if (rtl || !carrier.containsKey(cluster)) carrier[cluster] = i;
    }

    final clusters = carrier.keys.toList()..sort();
    final out = List<List<int>>.filled(run.length, const <int>[]);
    for (var c = 0; c < clusters.length; c++) {
      final from = clusters[c];
      final to = c + 1 < clusters.length ? clusters[c + 1] : sliceEnd;
      // Default-ignorables are stripped, and doing so is load-bearing rather
      // than tidy.
      //
      // The shaper hides a surviving joiner or isolate by pointing it at the
      // SPACE glyph with a zero advance (see `Shaper._hideJoiners` — HarfBuzz
      // does the same). That makes one glyph id serve two meanings, and the
      // `ToUnicode` CMap is keyed by glyph id. Let a U+2066 register first and
      // it claims the space glyph for the whole font: every real space in the
      // document then extracts as U+2066, so `Paid in full` comes back as
      // `Paid<U+2066>in<U+2066>full` — including on lines that contain no isolate at all.
      //
      // Stripping them here is also just correct on its own terms: a joiner is
      // a shaping instruction, not text, and it has no business in what a
      // reader copies out of a receipt.
      final source = <int>[];
      for (var s = from; s < to; s++) {
        if (!isDefaultIgnorable(scalars[s])) source.add(scalars[s]);
      }
      out[carrier[from]!] = source;
    }
    return out;
  }

  /// The pen advance of one glyph, in points.
  ///
  /// The single definition of it. Measurement and emission both call this, so a
  /// line cannot measure one width and draw another — which is the failure that
  /// puts a right-aligned total a hair off its column.
  static double _advanceOf(
    GlyphInfo info,
    GlyphPosition position,
    double scale,
    TextStyle style,
    double extraWordSpacing,
  ) {
    var advance = position.xAdvance * scale + style.letterSpacing;
    if (LineBreaker.isJustifiableSpace(info.codepoint)) {
      advance += style.wordSpacing + extraWordSpacing;
    }
    return advance;
  }

  TextMetrics _metricsOf(_LaidLine line, TextStyle style) {
    final metrics = LineMetrics.forStyle(style);
    return TextMetrics(
      width: line.width,
      ascent: metrics.ascent,
      descent: metrics.descent,
      lineHeight: metrics.lineHeight,
      glyphCount: line.glyphCount,
    );
  }

  // ── emission ────────────────────────────────────────────────────────────────

  /// Turns a laid-out line into a positioned program of glyph ids.
  ///
  /// Everything except the glyph CODES is decided here, at draw time: the
  /// pen arithmetic needs the font's declared widths, which are known, and not
  /// the subset numbering, which is not.
  ///
  /// The program is one `TJ` wherever it can be, with numeric adjustments only
  /// where a GPOS offset, a kern or a word space demands one. A `Tm` per glyph
  /// would also work and roughly triples the size of a page of text; on a
  /// billing run of ten thousand invoices a month that is 10 KB a page against
  /// 30 KB, for nothing.
  _TextProgram _program({
    required PdfPage page,
    required _LaidLine line,
    required TextStyle style,
    required double startX,
    required double baselineY,
    required double extraWordSpacing,
  }) {
    final size = style.size;
    final scale = line.scale;
    final font = style.font;
    final program = _TextProgram(
      page: page,
      style: style,
      resource: _fonts.attach(page, font),
      startX: startX,
      baselineY: baselineY,
    );

    // Where the next glyph belongs, and where the PDF's own pen will be. They
    // diverge whenever GPOS disagrees with the declared width, and the gap
    // between them is exactly what a `TJ` number carries.
    var pen = 0.0;
    var emitted = 0.0;
    var rise = 0.0;

    for (final segment in line.segments) {
      final run = segment.run;
      for (var i = 0; i < run.length; i++) {
        final info = run.infos[i];
        final position = run.positions[i];
        _fonts.use(font, info.glyphId, segment.sources[i]);

        // A GPOS y-offset is a mark, and Arabic diacritics are almost entirely
        // this. `Ts` is a text-state operator so it cannot live inside a `TJ`
        // array — the run has to be broken around it. Skip this and every
        // fatha, damma and shadda in the document stacks on the baseline.
        final wantRise = position.yOffset * scale;
        if ((wantRise - rise).abs() > _epsilon) {
          program.ops.add(_Rise(wantRise));
          rise = wantRise;
        }

        // A glyph carrying MORE THAN ONE codepoint gets an `/ActualText` span
        // of its own. `ToUnicode` alone is not enough for it: the expansion is
        // correct in the file and still comes back reversed, because an
        // extractor reordering a visual RTL line to logical order reverses the
        // ligature's two characters along with the rest of the line. One
        // codepoint cannot be reversed against itself, so wrapping those too
        // would cost bytes on every glyph in the document and buy nothing.
        //
        // And the span's text goes in VISUAL order — reversed for an RTL run —
        // which is invariant 1 again and reads like a bug until it is measured.
        // A reader does not treat `/ActualText` as finished logical text; it
        // spreads those characters across the span's box left to right and then
        // runs the SAME bidi pass it runs over glyphs. Written logically they
        // are reversed a second time. Measured over pdftotext 26.06, mutool
        // 1.28.2 and macOS PDFKit on five lines — `ڵا · ڵا ژمارە · ژمارە ڵا ·
        // پاڵاوتن · ڵاو` — visual order is right in 14 of 15, logical order in
        // 6 — which is what emitting no span at all scores. The one cell that
        // stays wrong is mutool on a line holding NOTHING but the ligature:
        // MuPDF finds no other glyph to tell it the line is RTL, skips its
        // reversal and returns what we wrote, while poppler reverses that same
        // line unconditionally. No byte sequence satisfies both, so it is a
        // choice, and 14 beats 6. See test/pdf/actual_text_test.dart, which
        // pins every cell of that table including the losing one.
        final sources = segment.sources[i];
        final actualText = sources.length > 1
            ? String.fromCharCodes(
                run.direction == TextDirection.rtl ? sources.reversed : sources,
              )
            : null;
        if (actualText != null) program.ops.add(_SpanStart(actualText));

        final origin = pen + position.xOffset * scale;
        final delta = origin - emitted;
        if (delta.abs() > _epsilon) {
          // `TJ` SUBTRACTS its number, scaled by size/1000, from the
          // displacement — so moving the pen forward takes a negative one.
          program.ops.add(-delta * 1000 / size);
        }
        program.ops.add(info.glyphId);
        if (actualText != null) program.ops.add(const _SpanEnd());

        // What the viewer will advance by on its own: the width the embedded
        // font declares — rounded into 1000-unit glyph space exactly as the
        // `/W` array rounds it — plus the `Tc` set once for the line.
        emitted =
            origin +
            _fonts.declaredWidth(font, info.glyphId) * size / pdfUnitsPerEm +
            style.letterSpacing;
        pen += _advanceOf(info, position, scale, style, extraWordSpacing);
      }
    }
    return program;
  }

  /// Writes a program into its page, now that the CIDs exist.
  void _write(_TextProgram program) {
    final style = program.style;
    final content = program.page.content;

    // q/Q around the text object so letter spacing, rise, colour and render
    // mode cannot leak into whatever the caller drew next: the text state is
    // part of the graphics state, so one `Q` undoes all of them. The operators
    // below are written even at their PDF defaults — the stream tracks state as
    // "unknown" rather than "default", and a caller who set `Tc` outside this
    // block would otherwise have it apply to our text.
    content.save();
    content.setFillColor(style.color);
    content.beginText();
    content.setTextRenderMode(style.renderMode.value);
    content.setCharacterSpacing(style.letterSpacing);
    content.setFontRaw(program.resource, style.size);
    content.setTextMatrix(1, 0, 0, 1, program.startX, program.baselineY);

    final parts = <Object>[];
    final codes = BytesBuilder();

    void flushCodes() {
      if (codes.isEmpty) return;
      parts.add(codes.takeBytes());
    }

    void flushText() {
      flushCodes();
      if (parts.isEmpty) return;
      content.showTextAdjustedRaw(List<Object>.of(parts));
      parts.clear();
    }

    for (final op in program.ops) {
      switch (op) {
        case final int glyphId:
          final cid = _fonts.cidFor(style.font, glyphId);
          codes
            ..addByte((cid >> 8) & 0xFF)
            ..addByte(cid & 0xFF);
        case final double adjustment:
          flushCodes();
          parts.add(adjustment);
        case final _Rise rise:
          flushText();
          content.setTextRise(rise.points);
        // A `TJ` array may not straddle a `BDC`, so both ends flush first —
        // and it is `flushText`, not `flushCodes`: the pending parts have to
        // reach the page as a finished operator, not sit in the list waiting
        // to be emitted on the far side of the span boundary.
        case final _SpanStart span:
          flushText();
          content.beginActualText(span.text);
        case _SpanEnd():
          flushText();
          content.endMarkedContent();
      }
    }

    flushText();
    content.endText();
    content.restore();
  }

  // ── reporting ───────────────────────────────────────────────────────────────

  void _report(Set<int> missing, String text, PayvFont font) {
    if (missing.isEmpty) return;
    final glyphs = (missing.toList()..sort())
        .map(MissingGlyph.new)
        .toList(growable: false);
    final handler = onMissingGlyph;
    if (handler == null) throw MissingGlyphException(glyphs, text, font);
    for (final glyph in glyphs) {
      handler(glyph);
    }
  }

  /// True for a character whose absence from the font is a real defect.
  ///
  /// Controls, joiners and the other default-ignorables resolve to glyph 0 by
  /// design — the shaper has already made them invisible — and reporting them
  /// would drown the real answer in noise the first time a document contains a
  /// ZWJ, which for Kurdish is immediately.
  static bool _shouldHaveDrawn(int codepoint) =>
      codepoint > 0x001F &&
      codepoint != 0x007F &&
      !isDefaultIgnorable(codepoint);

  /// BCP-47 → OpenType language system tag.
  ///
  /// Short on purpose, and the entries earn their place: a font's `locl`
  /// feature substitutes different glyphs for Kurdish than for Arabic or
  /// Persian at the SAME codepoint, so getting `ckb` onto `KUR ` is the
  /// difference between Kurdish typography and Arabic typography with Kurdish
  /// letters in it. Anything unlisted resolves to `DFLT`, the font's default
  /// language system — correct, just not localised.
  static int _languageTag(String? bcp47) {
    if (bcp47 == null || bcp47.isEmpty) return Tag.dflt;
    final primary = bcp47.split(RegExp('[-_]')).first.toLowerCase();
    return _languageTags[primary] ?? Tag.dflt;
  }

  static final Map<String, int> _languageTags = <String, int>{
    'ckb': Tag.parse('KUR'),
    'ku': Tag.parse('KUR'),
    'kmr': Tag.parse('KUR'),
    'sdh': Tag.parse('KUR'),
    'ar': Tag.parse('ARA'),
    'fa': Tag.parse('FAR'),
    'ur': Tag.parse('URD'),
    'ps': Tag.parse('PAS'),
    'syr': Tag.parse('SYR'),
    'he': Tag.parse('IWR'),
    'en': Tag.parse('ENG'),
    'tr': Tag.parse('TRK'),
    'de': Tag.parse('DEU'),
    'fr': Tag.parse('FRA'),
    'ru': Tag.parse('RUS'),
  };

  /// A millionth of a point. Below this a `TJ` adjustment would format to zero
  /// anyway, and emitting it would only cost bytes and break a run.
  static const double _epsilon = 1e-6;

  static PayvTextAlign _resolveAlign(
    PayvTextAlign align, {
    required bool rtl,
  }) => switch (align) {
    PayvTextAlign.start => rtl ? PayvTextAlign.right : PayvTextAlign.left,
    PayvTextAlign.end => rtl ? PayvTextAlign.left : PayvTextAlign.right,
    _ => align,
  };
}

/// [CidFontEmbedder] behind the [GlyphEncoder] seam.
///
/// A thin adapter rather than an `implements` clause on the embedder itself:
/// the PDF half of this package does not depend on the layout half, and that
/// is worth keeping — it is what lets the font code serve a caller who brought
/// their own layout engine.
GlyphEncoder _cidEncoder(PdfDocument document) =>
    _CidGlyphEncoder(CidFontEmbedder(document));

class _CidGlyphEncoder implements GlyphEncoder {
  _CidGlyphEncoder(this.embedder);

  final CidFontEmbedder embedder;

  @override
  String attach(PdfPage page, PayvFont font) =>
      embedder.fontFor(font).attachTo(page);

  @override
  void use(PayvFont font, int glyphId, List<int> codepoints) =>
      embedder.fontFor(font).use(glyphId, codepoints: codepoints);

  @override
  int declaredWidth(PayvFont font, int glyphId) =>
      scaleToPdfGlyphSpace(font.raw.advanceWidth(glyphId), font.unitsPerEm);

  @override
  void finishAll() => embedder.finishAll();

  @override
  int cidFor(PayvFont font, int glyphId) =>
      embedder.fontFor(font).cidFor(glyphId);
}

/// A `Ts` in a text program. Distinct from a bare `double` so the walk in
/// [TextEngine._write] can tell a rise from a `TJ` adjustment.
class _Rise {
  const _Rise(this.points);

  final double points;
}

/// The `BDC` opening an `/ActualText` span in a text program.
class _SpanStart {
  const _SpanStart(this.text);

  /// What the glyphs inside the span say, in the order they are DRAWN — see
  /// the measurement in [TextEngine._program] for why that is not logical
  /// order.
  final String text;
}

/// The `EMC` closing one. Carries nothing; it exists so the walk in
/// [TextEngine._write] can tell the two ends apart by type alone.
class _SpanEnd {
  const _SpanEnd();
}

/// One text object, positioned and laid out, waiting only for its glyph codes.
class _TextProgram {
  _TextProgram({
    required this.page,
    required this.style,
    required this.resource,
    required this.startX,
    required this.baselineY,
  });

  final PdfPage page;
  final TextStyle style;

  /// The `/Font` resource name on [page].
  final String resource;

  final double startX;
  final double baselineY;

  /// `int` — a glyph id, to become a CID · `double` — a `TJ` adjustment ·
  /// [_Rise] — a `Ts` · [_SpanStart]/[_SpanEnd] — an `/ActualText` span.
  final List<Object> ops = <Object>[];
}

/// One shaped run, plus the source codepoints its glyphs carry into
/// `ToUnicode`.
class _Segment {
  const _Segment(this.run, this.sources);

  final ShapedRun run;
  final List<List<int>> sources;
}

/// One line, shaped and ordered, ready to emit or to measure.
class _LaidLine {
  const _LaidLine({
    required this.segments,
    required this.width,
    required this.glyphCount,
    required this.justifiableSpaces,
    required this.scale,
    required this.missing,
  });

  static const _LaidLine empty = _LaidLine(
    segments: <_Segment>[],
    width: 0,
    glyphCount: 0,
    justifiableSpaces: 0,
    scale: 0,
    missing: <int>{},
  );

  /// Left to right, whatever the paragraph direction.
  final List<_Segment> segments;

  final double width;
  final int glyphCount;

  /// U+0020 glyphs — what justification is allowed to stretch.
  final int justifiableSpaces;

  /// Font design units → points.
  final double scale;

  /// Codepoints the font had no glyph for.
  final Set<int> missing;
}
