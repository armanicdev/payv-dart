/// Byte sink and file assembler — everything that turns objects into a file.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../util/deflate.dart';
import 'object.dart';

/// A growable byte buffer with the two writes PDF syntax needs.
///
/// Not `BytesBuilder`: this package holds itself to zero dependencies and to
/// running wherever Dart runs, and a buffer is twenty lines.
class PdfSink {
  Uint8List _buf = Uint8List(4096);
  int _length = 0;

  int get length => _length;

  void writeByte(int byte) {
    if (_length == _buf.length) _grow(_length + 1);
    _buf[_length++] = byte & 0xFF;
  }

  void writeBytes(List<int> bytes) {
    if (_length + bytes.length > _buf.length) _grow(_length + bytes.length);
    _buf.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
  }

  /// Writes [s] as one byte per code unit.
  ///
  /// Every caller in this package passes PDF syntax, which is ASCII by
  /// definition; non-ASCII text reaches a file only through [PdfString] or
  /// [PdfHexString], which encode it properly first.
  void writeAscii(String s) {
    if (_length + s.length > _buf.length) _grow(_length + s.length);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      assert(c <= 0x7F, 'writeAscii got a non-ASCII code unit: $c');
      _buf[_length++] = c & 0xFF;
    }
  }

  /// A copy of what has been written. Copied, not viewed: the caller usually
  /// keeps this after the sink is discarded.
  Uint8List toBytes() => _buf.sublist(0, _length);

  /// A zero-copy view, valid only until the next write. For internal readers
  /// that consume the bytes immediately — hashing the body for a file
  /// identifier copies a whole document otherwise.
  Uint8List viewBytes() => Uint8List.sublistView(_buf, 0, _length);

  void _grow(int needed) {
    var capacity = _buf.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final next = Uint8List(capacity);
    next.setRange(0, _length, _buf);
    _buf = next;
  }
}

/// Collects indirect objects and serialises them into a PDF file.
///
/// Object numbers are handed out in allocation order and the file body is
/// written in that same order, so numbering is always contiguous from 1. That
/// is not required by the spec, but it makes the cross-reference table a flat
/// array and makes a malformed file obvious on sight.
class PdfWriter {
  PdfWriter({this.compress = true});

  /// Whether unfiltered streams get `/FlateDecode` at build time.
  final bool compress;

  final List<PdfObject?> _objects = <PdfObject?>[];
  bool _built = false;

  /// How many object numbers have been handed out.
  int get objectCount => _objects.length;

  /// Adds [object] to the file body and returns its reference.
  PdfRef add(PdfObject object) {
    _objects.add(object);
    return PdfRef(_objects.length);
  }

  /// Allocates an object number now and takes the object later.
  ///
  /// The page tree needs this in both directions at once — a page names its
  /// `/Parent` and the parent lists its `/Kids` — and one of the two has to be
  /// referable before it exists.
  PdfRef reserve() {
    _objects.add(null);
    return PdfRef(_objects.length);
  }

  /// Supplies the object for a reference from [reserve].
  void fill(PdfRef ref, PdfObject object) {
    final index = ref.objectNumber - 1;
    if (index < 0 || index >= _objects.length) {
      throw ArgumentError.value(
        ref.objectNumber,
        'ref',
        'no such object in this writer',
      );
    }
    _objects[index] = object;
  }

  /// Serialises the whole file.
  ///
  /// Uses a classic cross-reference *table* rather than a cross-reference
  /// stream. A table is bigger and PDF 1.5 offers the alternative, but it is
  /// readable in a hex editor, it is what every reader ever written supports,
  /// and it costs a few hundred bytes on a document whose glyph outlines are
  /// measured in tens of kilobytes.
  Uint8List build({
    required PdfRef catalog,
    PdfDict? info,
    String? documentId,
  }) {
    // Building twice would append a second /Info object to the body and
    // re-walk streams that are already deflated. One writer, one file.
    if (_built) {
      throw StateError('this writer has already produced a file');
    }
    _built = true;

    // Table 15 requires `/Info` to be an indirect reference, so it has to join
    // the body before the body is written — not be slipped into the trailer.
    final infoRef = info == null ? null : add(info);

    final out = PdfSink();
    out.writeAscii('%PDF-1.7\n');

    // Four bytes above 0x7E on a comment line. It is how a file-transfer tool
    // that still sniffs text-vs-binary decides not to "helpfully" rewrite the
    // line endings inside a compressed stream (§7.5.2).
    out.writeBytes(const <int>[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = Uint32List(_objects.length + 1);
    for (var i = 0; i < _objects.length; i++) {
      final object = _objects[i];
      if (object == null) {
        throw StateError(
          'object ${i + 1} was reserved but never filled — some dictionary '
          'now points at nothing',
        );
      }
      if (compress && object is PdfStream) _deflateStream(object);

      offsets[i + 1] = out.length;
      out.writeAscii('${i + 1} 0 obj\n');
      object.write(out);
      out.writeAscii('\nendobj\n');
    }

    final xrefOffset = out.length;
    final size = _objects.length + 1;
    out.writeAscii('xref\n0 $size\n');

    // Entry 0 is mandatory, free, and carries generation 65535: it heads the
    // linked list of free entries. Readers that rebuild a damaged xref look
    // for exactly this shape.
    out.writeAscii('0000000000 65535 f \n');
    for (var i = 1; i < size; i++) {
      // Exactly 20 bytes: 10 digits, space, 5 digits, space, type, space, LF.
      out.writeAscii('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
    }

    final id = PdfHexString(_fileIdentifier(documentId, out));
    final trailer = PdfDict({
      'Size': PdfNumber(size),
      'Root': catalog,
      'Info': ?infoRef,
      'ID': PdfArray(<PdfObject>[id, id]),
    });

    out.writeAscii('trailer\n');
    trailer.write(out);
    out.writeAscii('\nstartxref\n$xrefOffset\n%%EOF\n');
    return out.toBytes();
  }

  void _deflateStream(PdfStream stream) {
    if (!stream.allowCompression) return;
    if (stream.filters.isNotEmpty) return; // already encoded; do not re-wrap
    // Below a few hundred bytes the zlib framing and the /Filter entry cost
    // more than the compression saves.
    if (stream.bytes.length < 256) return;
    final packed = zlibDeflate(stream.bytes);
    if (packed.length >= stream.bytes.length) return;
    stream.bytes = packed;
    stream.filters.add('FlateDecode');
  }

  /// The 16-byte `/ID` value.
  ///
  /// Derived from [seed] when given, otherwise from the bytes of the file
  /// itself. Never from a clock or a random source: two runs over the same
  /// input must produce byte-identical output, or no golden test of a PDF can
  /// exist and no build is reproducible.
  Uint8List _fileIdentifier(String? seed, PdfSink body) {
    final source = seed != null
        ? Uint8List.fromList(utf8.encode(seed))
        : body.viewBytes();
    final id = Uint8List(16);
    for (var lane = 0; lane < 4; lane++) {
      var h = 0x811C9DC5 ^ (lane * 0x9E3779B1);
      h &= 0xFFFFFFFF;
      for (var i = lane; i < source.length; i += 4) {
        h ^= source[i];
        h ^= (h << 13) & 0xFFFFFFFF;
        h ^= h >>> 17;
        h ^= (h << 5) & 0xFFFFFFFF;
        h &= 0xFFFFFFFF;
      }
      // Length matters too, or two files differing only by trailing padding
      // would share an identifier.
      h ^= source.length;
      id[lane * 4] = (h >>> 24) & 0xFF;
      id[lane * 4 + 1] = (h >>> 16) & 0xFF;
      id[lane * 4 + 2] = (h >>> 8) & 0xFF;
      id[lane * 4 + 3] = h & 0xFF;
    }
    return id;
  }
}
