/// The `/ToUnicode` CMap — the only thing that makes a shaped PDF readable
/// back out again.
///
/// With an `Identity-H` encoding the content stream says "draw glyph 474". That
/// is enough to PRINT the page and tells a reader nothing about what it SAYS.
/// Copy, search, screen readers, an archivist's text extractor and every
/// automated check an archive runs over its own documents all read this stream
/// and nothing else.
///
/// Which makes the many-to-one cases the whole job, not an edge:
///
///   * Vazirmatn's glyph 474 is the ڵ+ا ligature. It has no codepoint. If its
///     entry here lists only ڵ, someone who copies their address out of the
///     PDF loses a letter — silently, and only in Kurdish.
///   * Arabic positional forms are four glyphs for one letter. All four map
///     back to the same codepoint; anything else and the extracted text is in
///     the U+FE70 presentation block, which no search box will ever match.
///
/// The format is PostScript, because a CMap is a PostScript program. It is
/// written out verbatim below rather than assembled cleverly — this is one of
/// the places where matching the shape every reader was tested against matters
/// more than elegance.
library;

import 'dart:typed_data';

import 'writer.dart';

/// Maximum entries in one `bfchar` or `bfrange` section.
///
/// The CMap spec states the limit outright, and it is not decorative: sections
/// past 100 entries are rejected outright by some readers and silently
/// truncated by others, which loses the tail of the document's text with no
/// error anywhere.
const int _maxSectionEntries = 100;

/// Destination codepoints kept per CID.
///
/// A `bfchar` destination is a string, and the spec caps it at 512 bytes. No
/// real cluster is anywhere near that; the cap is here so a pathological
/// combining sequence cannot produce a CMap a reader refuses whole.
const int maxToUnicodeCodepoints = 16;

/// Builds the `/ToUnicode` CMap stream body for [cidToCodepoints].
///
/// Keys are CIDs in the FINAL subset numbering — the same two-byte codes the
/// content stream shows. A CID mapping to several codepoints gets them all, in
/// one hex string, which is what recovers a ligature intact.
///
/// CID 0 is dropped: it is `.notdef`, it means "this text had no glyph", and
/// mapping it to anything tells a reader that a hole in the document is a
/// character.
Uint8List buildToUnicodeCMap(Map<int, List<int>> cidToCodepoints) {
  final entries = <int, List<int>>{};
  for (final cid in cidToCodepoints.keys.toList()..sort()) {
    if (cid <= 0 || cid > 0xFFFF) continue;
    final codepoints = cidToCodepoints[cid]!;
    if (codepoints.isEmpty) continue;
    entries[cid] = codepoints.length > maxToUnicodeCodepoints
        ? codepoints.sublist(0, maxToUnicodeCodepoints)
        : codepoints;
  }

  final out = PdfSink();
  out.writeAscii(_preamble);

  final cids = entries.keys.toList();
  final ranges = <_BfRange>[];
  final chars = <int>[];
  _partition(cids, entries, ranges, chars);

  for (final chunk in _chunk(chars, _maxSectionEntries)) {
    out.writeAscii('${chunk.length} beginbfchar\n');
    for (final cid in chunk) {
      out.writeAscii('<${_hex16(cid)}> <${_utf16beHex(entries[cid]!)}>\n');
    }
    out.writeAscii('endbfchar\n');
  }

  for (final chunk in _chunk(ranges, _maxSectionEntries)) {
    out.writeAscii('${chunk.length} beginbfrange\n');
    for (final range in chunk) {
      out.writeAscii(
        '<${_hex16(range.first)}> <${_hex16(range.last)}> '
        '<${_utf16beHex(<int>[range.firstCodepoint])}>\n',
      );
    }
    out.writeAscii('endbfrange\n');
  }

  out.writeAscii(_epilogue);
  return out.toBytes();
}

/// A run of consecutive CIDs mapping to consecutive single codepoints.
class _BfRange {
  const _BfRange(this.first, this.last, this.firstCodepoint);

  final int first;
  final int last;
  final int firstCodepoint;
}

/// Splits [cids] into `bfrange` runs and leftover `bfchar` singles.
///
/// A range is only legal when the destination increments in its LAST BYTE — the
/// spec defines a `bfrange` that way, and a run crossing a `…FF` boundary would
/// be read by a conforming reader as wrapping rather than carrying. Digits and
/// the Arabic block are both dense enough that this saves real bytes; a run of
/// four is the point where a range costs less than the array entries it
/// replaces.
void _partition(
  List<int> cids,
  Map<int, List<int>> entries,
  List<_BfRange> ranges,
  List<int> chars,
) {
  const minimumRunLength = 4;
  var i = 0;
  while (i < cids.length) {
    final start = entries[cids[i]]!;
    var end = i;
    if (start.length == 1 && start.single <= 0xFFFF) {
      while (end + 1 < cids.length) {
        final next = entries[cids[end + 1]]!;
        if (cids[end + 1] != cids[end] + 1) break;
        if (next.length != 1) break;
        if (next.single != start.single + (end + 1 - i)) break;
        // The low-byte carry the format cannot express.
        if ((next.single & 0xFF) == 0) break;
        end++;
      }
    }
    if (end - i + 1 >= minimumRunLength) {
      ranges.add(_BfRange(cids[i], cids[end], start.single));
      i = end + 1;
    } else {
      chars.add(cids[i]);
      i++;
    }
  }
}

Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
  for (var i = 0; i < items.length; i += size) {
    yield items.sublist(i, i + size > items.length ? items.length : i + size);
  }
}

String _hex16(int value) =>
    value.toRadixString(16).toUpperCase().padLeft(4, '0');

/// The codepoints as UTF-16BE hex, surrogate pairs and all.
///
/// PDF text strings are UTF-16, not UTF-32: a codepoint above the BMP is two
/// code units here, and writing its scalar value as a single `<1F600>` produces
/// a hex string of odd length that readers pad with a zero nibble and then
/// decode as something else entirely.
String _utf16beHex(List<int> codepoints) {
  final buffer = StringBuffer();
  for (final cp in codepoints) {
    if (cp <= 0xFFFF) {
      buffer.write(_hex16(cp));
    } else {
      final v = cp - 0x10000;
      buffer.write(_hex16(0xD800 + (v >> 10)));
      buffer.write(_hex16(0xDC00 + (v & 0x3FF)));
    }
  }
  return buffer.toString();
}

/// `/Registry (Adobe) /Ordering (UCS)` — note that this is NOT the CIDFont's
/// own `Adobe-Identity-0` system info. A `ToUnicode` CMap always declares
/// itself as mapping into UCS; saying Identity here makes readers treat the
/// stream as a CID remapping and ignore it.
const String _preamble = '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
''';

const String _epilogue = '''
endcmap
CMapName currentdict /CMap defineresource pop
end
end
''';
