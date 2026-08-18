/// The PDF object model — the eight basic types of ISO 32000-1 §7.3, and
/// nothing above them.
///
/// Deliberately ignorant of fonts, pages and glyphs. The font subsystem builds
/// a `CIDFontType2` descriptor out of [PdfDict] and [PdfStream] the same way a
/// caller builds an annotation: by naming keys. That is what stops the writer
/// growing a font-shaped hole in it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'writer.dart';

/// Decimal places kept when a real number is serialised.
///
/// PDF reals are documented as carrying about five significant decimal digits
/// (§C.2); asking for more writes bytes no reader honours. At a 2048-unit em
/// scaled to points this still resolves well under a thousandth of a pixel.
const int _realPrecision = 5;

/// Formats [value] the way PDF requires: a plain decimal, never scientific.
///
/// This is the one piece of PDF syntax a Dart port gets wrong by default.
/// `0.0000001.toString()` is `1e-7`, and `1e-7` is not a number in PDF — it is
/// a syntax error that most readers report as a corrupt page rather than a bad
/// number, which is a miserable thing to debug.
String pdfFormatNumber(num value) {
  // `value is int` alone is TRUE for every integral double on dart2js and
  // dart2wasm, where one JavaScript number backs both types — so on the web it
  // swallowed doubles, the branches below became dead code, and the two targets
  // stopped agreeing on the bytes. `1e21` came out `1e+21`, which PDF has no
  // syntax for, and `-0.0` came out `-0.0` against the VM's `0`, which broke
  // the writer's promise that the same document serialises to the same bytes
  // and the same `/ID`. Asking for "int AND not double" is the one test that
  // means the same thing on both: on the VM only a real int passes, on the web
  // nothing does and every number takes the double path — which handles
  // integers exactly anyway.
  if (value is int && value is! double) return value.toString();
  final d = value.toDouble();
  if (d.isNaN || d.isInfinite) {
    throw ArgumentError.value(value, 'value', 'PDF has no syntax for $d');
  }
  if (d == d.roundToDouble()) {
    // Also normalises -0.0, which would otherwise serialise as "-0".
    if (d.abs() < 9007199254740992.0) {
      final i = d.toInt();
      return i == 0 ? '0' : i.toString();
    }
    // Past 2^53 `toInt()` is lossy on the web and `toStringAsFixed` gives up
    // entirely — it returns "1e+21" for 1e21, which is a PDF syntax error, not
    // a number. BigInt is exact and always plain decimal. No page coordinate
    // is ever this large, but a writer that can emit an exponent has a latent
    // corruption bug, and "no caller would do that" is not a guarantee.
    return BigInt.from(d).toString();
  }
  // Every non-integral double is below 2^53 by construction, so the fixed
  // formatter below is always in range.
  final fixed = d.toStringAsFixed(_realPrecision);
  var end = fixed.length;
  while (end > 0 && fixed.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && fixed.codeUnitAt(end - 1) == 0x2E) end--;
  final trimmed = fixed.substring(0, end);
  return trimmed.isEmpty || trimmed == '-0' ? '0' : trimmed;
}

/// Encodes [text] as the bytes of a PDF *text string* (§7.9.2.2).
///
/// Pure ASCII passes through as-is; anything else becomes UTF-16BE behind a
/// U+FEFF byte-order mark, because the alternative encoding a reader assumes —
/// PDFDocEncoding — has no Arabic script at all. Skip the BOM and a Kurdish
/// document title comes out as Latin-1 mojibake in every reader's title bar.
Uint8List encodePdfTextString(String text) {
  var ascii = true;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) > 0x7E || text.codeUnitAt(i) < 0x20) {
      ascii = false;
      break;
    }
  }
  if (ascii) return Uint8List.fromList(latin1.encode(text));

  final units = text.codeUnits;
  final out = Uint8List(2 + units.length * 2);
  out[0] = 0xFE;
  out[1] = 0xFF;
  for (var i = 0; i < units.length; i++) {
    out[2 + i * 2] = (units[i] >> 8) & 0xFF;
    out[3 + i * 2] = units[i] & 0xFF;
  }
  return out;
}

/// Any value that can appear in a PDF file body.
sealed class PdfObject {
  const PdfObject();

  void write(PdfSink out);

  /// The object's own serialisation, for tests and error messages. Not a
  /// serialisation path — [write] is.
  @override
  String toString() {
    final sink = PdfSink();
    write(sink);
    return String.fromCharCodes(sink.toBytes());
  }
}

final class PdfNull extends PdfObject {
  const PdfNull();

  @override
  void write(PdfSink out) => out.writeAscii('null');
}

final class PdfBool extends PdfObject {
  const PdfBool(this.value);

  static const PdfBool yes = PdfBool(true);
  static const PdfBool no = PdfBool(false);

  final bool value;

  @override
  void write(PdfSink out) => out.writeAscii(value ? 'true' : 'false');
}

final class PdfNumber extends PdfObject {
  const PdfNumber(this.value);

  final num value;

  @override
  void write(PdfSink out) => out.writeAscii(pdfFormatNumber(value));
}

/// A literal string — `(like this)`.
final class PdfString extends PdfObject {
  /// Encodes [text] as a text string; see [encodePdfTextString].
  factory PdfString(String text) => PdfString.bytes(encodePdfTextString(text));

  const PdfString.bytes(this.bytes);

  /// A PDF date string, `D:YYYYMMDDHHmmSSOHH'mm'` (§7.9.4).
  ///
  /// The offset is written from [when]'s own zone, so a document created at
  /// 09:00 in Erbil says so rather than silently claiming UTC.
  factory PdfString.date(DateTime when) {
    final b = StringBuffer('D:');
    String two(int v) => v.toString().padLeft(2, '0');
    b.write(when.year.toString().padLeft(4, '0'));
    b.write(two(when.month));
    b.write(two(when.day));
    b.write(two(when.hour));
    b.write(two(when.minute));
    b.write(two(when.second));
    if (when.isUtc) {
      b.write('Z00\'00\'');
    } else {
      final offset = when.timeZoneOffset;
      b.write(offset.isNegative ? '-' : '+');
      final mins = offset.inMinutes.abs();
      b.write(two(mins ~/ 60));
      b.write('\'');
      b.write(two(mins % 60));
      b.write('\'');
    }
    return PdfString.bytes(Uint8List.fromList(latin1.encode(b.toString())));
  }

  final Uint8List bytes;

  @override
  void write(PdfSink out) {
    out.writeByte(0x28); // (
    for (final b in bytes) {
      switch (b) {
        case 0x28: // (
        case 0x29: // )
        case 0x5C: // backslash
          out.writeByte(0x5C);
          out.writeByte(b);
        case 0x0A:
          out.writeAscii(r'\n');
        case 0x0D:
          out.writeAscii(r'\r');
        case 0x09:
          out.writeAscii(r'\t');
        case 0x08:
          out.writeAscii(r'\b');
        case 0x0C:
          out.writeAscii(r'\f');
        default:
          if (b < 0x20 || b > 0x7E) {
            // Octal rather than raw: a UTF-16BE title is full of NUL bytes,
            // and a raw NUL inside a literal string survives no text pipeline.
            out.writeAscii('\\${b.toRadixString(8).padLeft(3, '0')}');
          } else {
            out.writeByte(b);
          }
      }
    }
    out.writeByte(0x29); // )
  }
}

/// A hexadecimal string — `<48656C6C6F>`.
///
/// The right choice for anything binary: CID codes in a `Tj`, an
/// `/ActualText` span, a file identifier. A literal string would escape most
/// of those bytes to octal and triple the size.
final class PdfHexString extends PdfObject {
  const PdfHexString(this.bytes);

  factory PdfHexString.text(String text) =>
      PdfHexString(encodePdfTextString(text));

  final Uint8List bytes;

  @override
  void write(PdfSink out) {
    out.writeByte(0x3C); // <
    for (final b in bytes) {
      out.writeByte(_hexDigits[(b >> 4) & 0xF]);
      out.writeByte(_hexDigits[b & 0xF]);
    }
    out.writeByte(0x3E); // >
  }

  static const List<int> _hexDigits = [
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, //
    0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
  ];
}

/// A name object — `/Type`, `/FlateDecode`, `/F1`.
final class PdfName extends PdfObject {
  const PdfName(this.name);

  final String name;

  @override
  void write(PdfSink out) {
    out.writeByte(0x2F); // /
    for (final b in utf8.encode(name)) {
      // §7.3.5: everything outside the regular character set, and `#` itself,
      // must be written as #XX. A resource name is generated here and is
      // always tame, but a caller naming an OCG after a Kurdish layer is not.
      if (b < 0x21 || b > 0x7E || _delimiters.contains(b)) {
        out.writeByte(0x23); // #
        out.writeAscii(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      } else {
        out.writeByte(b);
      }
    }
  }

  static const Set<int> _delimiters = {
    0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25, 0x23, //
  };
}

final class PdfArray extends PdfObject {
  PdfArray([List<PdfObject>? items]) : items = items ?? <PdfObject>[];

  factory PdfArray.numbers(List<num> values) =>
      PdfArray(values.map(PdfNumber.new).toList());

  factory PdfArray.names(List<String> values) =>
      PdfArray(values.map(PdfName.new).toList());

  final List<PdfObject> items;

  void add(PdfObject item) => items.add(item);

  int get length => items.length;

  bool get isEmpty => items.isEmpty;

  bool get isNotEmpty => items.isNotEmpty;

  @override
  void write(PdfSink out) {
    out.writeByte(0x5B); // [
    for (var i = 0; i < items.length; i++) {
      if (i != 0) out.writeByte(0x20);
      items[i].write(out);
    }
    out.writeByte(0x5D); // ]
  }
}

/// A dictionary. Keys are given as bare names (`'Type'`, not `'/Type'`).
///
/// Backed by an insertion-ordered map, so the same document written twice
/// produces the same bytes — which is what makes a golden-file test of a PDF
/// possible at all.
final class PdfDict extends PdfObject {
  PdfDict([Map<String, PdfObject>? entries])
    : entries = <String, PdfObject>{...?entries};

  final Map<String, PdfObject> entries;

  PdfObject? operator [](String key) => entries[key];

  void operator []=(String key, PdfObject value) => entries[key] = value;

  bool containsKey(String key) => entries.containsKey(key);

  PdfObject? remove(String key) => entries.remove(key);

  Iterable<String> get keys => entries.keys;

  bool get isEmpty => entries.isEmpty;

  bool get isNotEmpty => entries.isNotEmpty;

  /// The sub-dictionary at [key], created on first use. How `/Resources` grows
  /// a `/Font` branch without every caller re-checking whether it exists.
  PdfDict subDict(String key) {
    final existing = entries[key];
    if (existing is PdfDict) return existing;
    final made = PdfDict();
    entries[key] = made;
    return made;
  }

  @override
  void write(PdfSink out) {
    out.writeAscii('<<');
    var first = true;
    for (final entry in entries.entries) {
      if (!first) out.writeByte(0x20);
      first = false;
      PdfName(entry.key).write(out);
      out.writeByte(0x20);
      entry.value.write(out);
    }
    out.writeAscii('>>');
  }
}

/// A stream object: a dictionary followed by raw bytes.
///
/// [bytes] and [filters] are mutable because compression is applied late, by
/// [PdfWriter] at build time — only then is it known whether the document
/// wants compression at all and whether deflating this particular payload
/// actually made it smaller.
final class PdfStream extends PdfObject {
  PdfStream(this.dict, this.bytes, {List<String>? filters})
    // An explicitly empty list means "no filters"; only a null one is seeded.
    : filters = <String>[...?(filters ?? _filtersIn(dict))];

  /// The filter names a caller wrote into [dict] as `/Filter`.
  ///
  /// [write] recomputes `/Filter` from [filters] and skips the dict's own
  /// entry, so a declared filter used to be silently dropped — and
  /// `PdfWriter._deflateStream` reads only [filters], so it then saw an
  /// unfiltered stream and deflated it. A `/DCTDecode` JPEG was written as
  /// `/FlateDecode`: a reader inflates it and hands raw JPEG bytes to an
  /// XObject declared as uncompressed samples. Corrupt image, no error
  /// anywhere. Seeding rather than throwing, because `/Filter` in the dict is
  /// how the rest of the PDF world spells this and a caller who writes it means
  /// it — the defect was losing the intent, not receiving it.
  static List<String>? _filtersIn(PdfDict dict) => switch (dict['Filter']) {
    PdfName(:final name) => <String>[name],
    PdfArray(:final items) => <String>[
      for (final item in items)
        if (item is PdfName) item.name,
    ],
    _ => null,
  };

  final PdfDict dict;

  Uint8List bytes;

  /// Filter names already applied to [bytes], outermost first.
  final List<String> filters;

  /// Set false for a payload that is already compressed (a JPEG behind
  /// `/DCTDecode`), where a flate pass costs CPU and adds bytes.
  bool allowCompression = true;

  @override
  void write(PdfSink out) {
    out.writeAscii('<<');
    for (final entry in dict.entries.entries) {
      // /Length and /Filter are computed, never inherited — a stale one from
      // the caller is how a PDF ends up truncated at exactly the old length.
      if (entry.key == 'Length' || entry.key == 'Filter') continue;
      PdfName(entry.key).write(out);
      out.writeByte(0x20);
      entry.value.write(out);
      out.writeByte(0x20);
    }
    PdfName('Length').write(out);
    out.writeByte(0x20);
    out.writeAscii(bytes.length.toString());
    if (filters.isNotEmpty) {
      out.writeByte(0x20);
      PdfName('Filter').write(out);
      out.writeByte(0x20);
      if (filters.length == 1) {
        PdfName(filters.single).write(out);
      } else {
        PdfArray.names(filters).write(out);
      }
    }
    out.writeAscii('>>\nstream\n');
    out.writeBytes(bytes);
    out.writeAscii('\nendstream');
  }
}

/// An indirect reference — `12 0 R`.
final class PdfRef extends PdfObject {
  const PdfRef(this.objectNumber, [this.generation = 0]);

  final int objectNumber;
  final int generation;

  @override
  void write(PdfSink out) => out.writeAscii('$objectNumber $generation R');

  @override
  bool operator ==(Object other) =>
      other is PdfRef &&
      other.objectNumber == objectNumber &&
      other.generation == generation;

  @override
  int get hashCode => objectNumber * 65599 + generation;
}

/// A body entry: an object with the number the cross-reference table will
/// record it under.
class PdfIndirectObject {
  PdfIndirectObject(this.number, this.object, {this.generation = 0});

  int number;
  int generation;
  PdfObject object;

  PdfRef get ref => PdfRef(number, generation);
}
