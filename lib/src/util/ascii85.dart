/// ASCII85 — PDF's `/ASCII85Decode` filter.
///
/// Not on the fast path: a real document compresses with `/FlateDecode` and
/// stores the result as binary. This exists for the case where a PDF has to
/// survive a 7-bit or line-ending-rewriting channel — pasted into a bug
/// report, mailed through an old gateway — and for reading back a stream that
/// arrived that way. It costs 25% over the raw bytes, against base64's 33%.
///
/// PDF's variant, not Adobe's `<~ ~>` framing: the leading `<~` is not part of
/// the filter, only the `~>` terminator is (§7.4.3).
library;

import 'dart:typed_data';

/// Encodes [bytes], terminated with `~>`.
///
/// [lineWidth] wraps the output; 0 leaves it on one line. Wrapping matters for
/// the only reason this filter is here — some channels break a line longer
/// than a few hundred characters, and a broken line breaks the stream.
String ascii85Encode(Uint8List bytes, {int lineWidth = 75}) {
  final out = StringBuffer();
  var column = 0;

  void emit(String chunk) {
    if (lineWidth <= 0) {
      out.write(chunk);
      return;
    }
    for (var i = 0; i < chunk.length; i++) {
      if (column == lineWidth) {
        out.write('\n');
        column = 0;
      }
      out.write(chunk[i]);
      column++;
    }
  }

  final full = bytes.length ~/ 4;
  for (var group = 0; group < full; group++) {
    final i = group * 4;
    // Built by multiplication, not `<<`: a group starting with a byte >= 0x80
    // exceeds 2^31 and would come back negative from a 32-bit shift on the web.
    final value =
        bytes[i] * 16777216 +
        bytes[i + 1] * 65536 +
        bytes[i + 2] * 256 +
        bytes[i + 3];
    if (value == 0) {
      // The 'z' shorthand for four zero bytes. Legal only for a *whole* group,
      // which is why the partial tail below never uses it.
      emit('z');
    } else {
      emit(_encodeGroup(value, 5));
    }
  }

  final remaining = bytes.length - full * 4;
  if (remaining > 0) {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final index = full * 4 + i;
      value = value * 256 + (index < bytes.length ? bytes[index] : 0);
    }
    // n leftover bytes encode as n+1 characters: the zero padding contributes
    // to the arithmetic but its characters are dropped, and the decoder pads
    // with 'u' to undo exactly that.
    emit(_encodeGroup(value, 5).substring(0, remaining + 1));
  }

  // The terminator goes on whole or on the next line. Splitting `~` from `>`
  // is legal — white space may fall anywhere — but it defeats every decoder
  // that looks for the two-character sequence, including some in the wild.
  if (lineWidth > 0 && column + 2 > lineWidth) out.write('\n');
  out.write('~>');
  return out.toString();
}

String _encodeGroup(int value, int count) {
  final chars = List<int>.filled(count, 0);
  var v = value;
  for (var i = count - 1; i >= 0; i--) {
    chars[i] = 0x21 + v % 85;
    v ~/= 85;
  }
  return String.fromCharCodes(chars);
}

/// Decodes an ASCII85 stream, stopping at `~>` or the end of [text].
///
/// Throws [FormatException] on a character outside the alphabet. Silently
/// skipping junk is how a corrupted stream turns into a plausible-looking but
/// wrong image.
Uint8List ascii85Decode(String text) {
  final out = <int>[];
  var value = 0;
  var count = 0;

  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);

    if (c == 0x7E) {
      // '~' — only '~>' is legal here, but white space may sit between the
      // two, because a wrapping encoder is entitled to break anywhere.
      var j = i + 1;
      while (j < text.length && _isWhitespace(text.codeUnitAt(j))) {
        j++;
      }
      if (j >= text.length || text.codeUnitAt(j) != 0x3E) {
        throw const FormatException("ASCII85: '~' not followed by '>'");
      }
      break;
    }
    if (_isWhitespace(c)) continue; // PDF white space is not data
    if (c == 0x7A) {
      // 'z'
      if (count != 0) {
        throw const FormatException("ASCII85: 'z' inside a partial group");
      }
      out.addAll(const <int>[0, 0, 0, 0]);
      continue;
    }
    if (c < 0x21 || c > 0x75) {
      throw FormatException(
        'ASCII85: character 0x${c.toRadixString(16)} is outside the alphabet',
      );
    }

    value = value * 85 + (c - 0x21);
    count++;
    if (count == 5) {
      _emitGroup(out, value, 4);
      value = 0;
      count = 0;
    }
  }

  if (count == 1) {
    throw const FormatException(
      'ASCII85: a group of one character cannot '
      'encode any byte',
    );
  }
  if (count > 1) {
    // Pad with 'u' (the highest digit) so the truncated group rounds back to
    // the bytes that produced it.
    for (var i = count; i < 5; i++) {
      value = value * 85 + 84;
    }
    _emitGroup(out, value, count - 1);
  }
  return Uint8List.fromList(out);
}

/// The six characters §7.2.3 calls white space.
bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

void _emitGroup(List<int> out, int value, int byteCount) {
  // Five base-85 digits can express 85^5 − 1 = 4437053124, which is 142085829
  // more than four bytes can hold. §7.4.3 makes that an error and the decoder's
  // own doc comment promises to throw on one; masking it with `& 0xFF` instead
  // turned `uuuuu~>` into the four plausible bytes [8, 120, 14, 196], which is
  // exactly the "corrupted stream becomes a wrong image" failure the comment
  // above is about. Legal input cannot reach here: a partial group padded with
  // 'u' stays under the limit, because the digits the padding replaces were at
  // most 84 anyway.
  if (value > 0xFFFFFFFF) {
    throw FormatException(
      'ASCII85: group value $value exceeds the 32 bits four bytes hold',
    );
  }
  final bytes = <int>[
    (value ~/ 16777216) & 0xFF,
    (value ~/ 65536) & 0xFF,
    (value ~/ 256) & 0xFF,
    value & 0xFF,
  ];
  for (var i = 0; i < byteCount; i++) {
    out.add(bytes[i]);
  }
}
