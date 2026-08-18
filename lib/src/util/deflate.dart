/// DEFLATE (RFC 1951) and its zlib wrapper (RFC 1950), in pure Dart.
///
/// PDF's `/FlateDecode` is zlib, and there is no zlib in Dart that reaches
/// every target: `dart:io`'s `ZLibCodec` is native-only, so a PDF built on the
/// web would come out uncompressed — or not at all, once a `dart:io` import
/// makes the library unloadable there. `package:archive` would fix it and cost
/// this package its zero-dependency promise. So the encoder lives here.
///
/// It is a real encoder, not a stored-block stub: hash-chain LZ77 with lazy
/// matching, and every block costed three ways (stored, fixed-Huffman,
/// dynamic-Huffman) with the cheapest kept. Dynamic code lengths come out of
/// package-merge rather than zlib's build-a-tree-then-repair-the-overflow,
/// because package-merge is optimal *and* respects the 15-bit ceiling by
/// construction — there is no second pass left to get subtly wrong.
///
/// Everything here stays inside 32-bit integer arithmetic. That is not
/// tidiness: on the web an `int` is a double, `<<` and `>>>` truncate to 32
/// bits, and a checksum built with `(s2 << 16) | s1` silently goes negative.
/// The adler32 below multiplies instead, for that reason.
library;

import 'dart:typed_data';

/// Compresses [input] into a zlib stream — the exact bytes `/FlateDecode`
/// expects.
///
/// [level] is 0 (store only) to 9 (slowest, smallest); 6 matches zlib's
/// default trade-off.
Uint8List zlibDeflate(Uint8List input, {int level = 6}) {
  if (level < 0 || level > 9) {
    throw ArgumentError.value(level, 'level', 'must be 0..9');
  }
  final body = rawDeflate(input, level: level);
  final out = Uint8List(body.length + 6);

  // CM=8 (deflate), CINFO=7 (32K window). Any other CINFO is legal but no
  // encoder emits one, and a few readers assume 0x78.
  const cmf = 0x78;
  final flevel = level <= 1
      ? 0
      : level <= 5
      ? 1
      : level == 6
      ? 2
      : 3;
  var flg = flevel << 6;
  flg += 31 - (cmf * 256 + flg) % 31; // FCHECK: the pair must divide by 31.

  out[0] = cmf;
  out[1] = flg;
  out.setRange(2, 2 + body.length, body);

  final sum = adler32(input);
  final p = 2 + body.length;
  out[p] = (sum ~/ 16777216) & 0xFF;
  out[p + 1] = (sum ~/ 65536) & 0xFF;
  out[p + 2] = (sum ~/ 256) & 0xFF;
  out[p + 3] = sum & 0xFF;
  return out;
}

/// Raw DEFLATE — no zlib header, no checksum.
///
/// PDF never wants this on its own, but PNG `IDAT` and WOFF table data do, and
/// it is the shared core either way.
Uint8List rawDeflate(Uint8List input, {int level = 6}) {
  if (level < 0 || level > 9) {
    throw ArgumentError.value(level, 'level', 'must be 0..9');
  }
  return _Deflater(input, level).run();
}

/// Adler-32 (RFC 1950 §9), the zlib trailer checksum.
///
/// Returned as a plain integer built by multiplication, never `s2 << 16` —
/// see the library comment.
int adler32(Uint8List data, [int seed = 1]) {
  var s1 = seed & 0xFFFF;
  var s2 = (seed ~/ 65536) & 0xFFFF;
  var i = 0;
  final n = data.length;
  while (i < n) {
    // 5552 is the most bytes that can accumulate before s2 could exceed the
    // 32-bit range; deferring the modulo that long is the whole speed trick.
    var end = i + 5552;
    if (end > n) end = n;
    while (i < end) {
      s1 += data[i++];
      s2 += s1;
    }
    s1 %= 65521;
    s2 %= 65521;
  }
  return s2 * 65536 + s1;
}

// ── LZ77 + Huffman encoder ────────────────────────────────────────────────────

const int _minMatch = 3;
const int _maxMatch = 258;
const int _windowSize = 32768;
const int _windowMask = _windowSize - 1;
const int _hashBits = 15;
const int _hashSize = 1 << _hashBits;
const int _hashMask = _hashSize - 1;

/// Tokens buffered before a block is costed and flushed. Larger blocks give the
/// dynamic tree more to amortise over; past ~16K the tree stops improving and
/// the memory does not.
const int _blockTokens = 16384;

/// Per-level tuning, indexed 0..9. Values are zlib's, which are the result of
/// far more measurement than this package will ever do.
const List<int> _goodLength = [0, 4, 4, 4, 4, 8, 8, 8, 32, 32];
const List<int> _maxLazy = [0, 4, 5, 6, 4, 16, 16, 32, 128, 258];
const List<int> _niceLength = [0, 8, 16, 32, 16, 32, 128, 128, 258, 258];
const List<int> _maxChain = [0, 4, 8, 32, 16, 32, 128, 256, 1024, 4096];

class _Deflater {
  _Deflater(this.data, this.level)
    : _goodMatch = _goodLength[level],
      _lazyMatch = _maxLazy[level],
      _nice = _niceLength[level],
      _chainLimit = _maxChain[level];

  final Uint8List data;
  final int level;

  final int _goodMatch;
  final int _lazyMatch;
  final int _nice;
  final int _chainLimit;

  final _ByteSink _out = _ByteSink();
  int _bitBuf = 0;
  int _bitCount = 0;

  late final Int32List _head = Int32List(_hashSize)
    ..fillRange(0, _hashSize, -1);
  late final Int32List _prev = Int32List(_windowSize)
    ..fillRange(0, _windowSize, -1);

  final Uint16List _tokenLit = Uint16List(_blockTokens);
  final Uint16List _tokenDist = Uint16List(_blockTokens);
  int _tokenCount = 0;
  int _blockStart = 0;
  int _blockBytes = 0;

  int _matchLen = 0;
  int _matchDist = 0;

  Uint8List run() {
    if (level == 0) {
      _storeAll();
    } else if (level < 4) {
      _compressFast();
    } else {
      _compressLazy();
    }
    _alignToByte();
    return _out.takeBytes();
  }

  // ── block assembly ──────────────────────────────────────────────────────────

  void _literal(int byte) {
    _tokenLit[_tokenCount] = byte;
    _tokenDist[_tokenCount] = 0;
    _tokenCount++;
    _blockBytes++;
    if (_tokenCount == _blockTokens) _flushBlock(false);
  }

  void _match(int length, int distance) {
    _tokenLit[_tokenCount] = length;
    _tokenDist[_tokenCount] = distance;
    _tokenCount++;
    _blockBytes += length;
    if (_tokenCount == _blockTokens) _flushBlock(false);
  }

  /// Level 0: no matching at all, just stored blocks. Used when a caller knows
  /// the payload is already compressed (a JPEG, a flate stream re-embedded)
  /// and wants the framing without the wasted CPU.
  void _storeAll() {
    var pos = 0;
    if (data.isEmpty) {
      _writeStored(0, 0, true);
      return;
    }
    while (pos < data.length) {
      var len = data.length - pos;
      if (len > 65535) len = 65535;
      _writeStored(pos, len, pos + len >= data.length);
      pos += len;
    }
  }

  void _compressFast() {
    final n = data.length;
    var pos = 0;
    while (pos < n) {
      final head = _insert(pos);
      if (head >= 0) {
        _longestMatch(pos, head, _minMatch - 1);
      } else {
        _matchLen = 0;
      }
      if (_matchLen >= _minMatch) {
        final len = _matchLen;
        _match(len, _matchDist);
        // Every position the match covers still has to enter the hash chains,
        // or the next match search cannot see through it.
        final insertEnd = pos + len;
        final maxInsert = n - _minMatch;
        for (var i = pos + 1; i < insertEnd; i++) {
          if (i > maxInsert) break;
          _insert(i);
        }
        pos = insertEnd;
      } else {
        _literal(data[pos]);
        pos++;
      }
    }
    _flushBlock(true);
  }

  /// Lazy matching, structured exactly like zlib's `deflate_slow`: a match
  /// found at `pos` is held back one byte to see whether `pos + 1` starts a
  /// longer one. The deferred literal is what makes the two branches below
  /// look off-by-one — they are not, the emitted match begins at `pos - 1`.
  void _compressLazy() {
    final n = data.length;
    final maxInsert = n - _minMatch;
    var pos = 0;
    var matchAvailable = false;
    var prevLen = _minMatch - 1;
    var prevDist = 0;

    while (pos < n) {
      final head = _insert(pos);
      final priorLen = prevLen;
      final priorDist = prevDist;

      prevLen = _minMatch - 1;
      prevDist = 0;
      if (head >= 0 && priorLen < _lazyMatch) {
        _longestMatch(pos, head, priorLen);
        if (_matchLen >= _minMatch) {
          prevLen = _matchLen;
          prevDist = _matchDist;
          // zlib's TOO_FAR: a 3-byte match far back costs more in distance
          // bits than the three literals it replaces.
          if (prevLen == _minMatch && prevDist > 4096) {
            prevLen = _minMatch - 1;
            prevDist = 0;
          }
        }
      }

      if (priorLen >= _minMatch && prevLen <= priorLen) {
        _match(priorLen, priorDist);
        // The match started at pos-1 and runs priorLen bytes, so it ends at
        // pos-2+priorLen; insert everything it swallowed except that last
        // byte, which the next iteration inserts itself.
        var remaining = priorLen - 2;
        while (remaining-- > 0) {
          pos++;
          if (pos <= maxInsert) _insert(pos);
        }
        pos++;
        matchAvailable = false;
        prevLen = _minMatch - 1;
        prevDist = 0;
      } else if (matchAvailable) {
        _literal(data[pos - 1]);
        pos++;
      } else {
        matchAvailable = true;
        pos++;
      }
    }
    if (matchAvailable) _literal(data[n - 1]);
    _flushBlock(true);
  }

  // ── match finding ───────────────────────────────────────────────────────────

  /// Links [pos] into its hash chain and returns the previous occupant, or -1.
  ///
  /// `_prev` is indexed by `pos & _windowMask` rather than by `pos`. That is
  /// safe precisely because the chain is only ever walked back 32768 bytes: a
  /// slot can only be overwritten by a position 32768 further on, which has not
  /// been inserted yet when we walk it.
  int _insert(int pos) {
    if (pos + _minMatch > data.length) return -1;
    final h =
        ((data[pos] << 10) ^ (data[pos + 1] << 5) ^ data[pos + 2]) & _hashMask;
    final prevHead = _head[h];
    _prev[pos & _windowMask] = prevHead;
    _head[h] = pos;
    return prevHead;
  }

  /// Walks the chain from [head], leaving the best find in [_matchLen] /
  /// [_matchDist] (length 0 when nothing reached [_minMatch]).
  void _longestMatch(int pos, int head, int priorLen) {
    final n = data.length;
    var maxLen = n - pos;
    if (maxLen > _maxMatch) maxLen = _maxMatch;
    if (maxLen < _minMatch) {
      _matchLen = 0;
      return;
    }

    // A long match already in hand means the chain is unlikely to beat it;
    // zlib cuts the search to a quarter rather than paying for the whole walk.
    var chain = _chainLimit;
    if (priorLen >= _goodMatch) chain >>= 2;

    final minPos = pos - _windowSize;
    var best = _minMatch - 1;
    var bestDist = 0;
    var cand = head;

    while (cand >= 0 && cand >= minPos && chain-- > 0) {
      // Check the byte that would extend the current best first: it rejects
      // almost every candidate in one compare.
      if (data[cand + best] == data[pos + best] && data[cand] == data[pos]) {
        var len = 0;
        while (len < maxLen && data[cand + len] == data[pos + len]) {
          len++;
        }
        if (len > best) {
          best = len;
          bestDist = pos - cand;
          if (len >= _nice || best >= maxLen) break;
        }
      }
      cand = _prev[cand & _windowMask];
    }

    if (best >= _minMatch) {
      _matchLen = best;
      _matchDist = bestDist;
    } else {
      _matchLen = 0;
      _matchDist = 0;
    }
  }

  // ── block emission ──────────────────────────────────────────────────────────

  void _flushBlock(bool last) {
    final litFreq = Uint32List(286);
    final distFreq = Uint32List(30);
    litFreq[256] = 1; // end-of-block, always present

    for (var i = 0; i < _tokenCount; i++) {
      final d = _tokenDist[i];
      if (d == 0) {
        litFreq[_tokenLit[i]]++;
      } else {
        litFreq[257 + _lengthCodeOf[_tokenLit[i]]]++;
        distFreq[_distCodeOf(d)]++;
      }
    }

    _forceTwoCodes(litFreq);
    _forceTwoCodes(distFreq);

    final dynLitLen = _packageMerge(litFreq, 15);
    final dynDistLen = _packageMerge(distFreq, 15);

    var numLit = 286;
    while (numLit > 257 && dynLitLen[numLit - 1] == 0) {
      numLit--;
    }
    var numDist = 30;
    while (numDist > 1 && dynDistLen[numDist - 1] == 0) {
      numDist--;
    }

    final tree = _CodeLengthTree.build(dynLitLen, numLit, dynDistLen, numDist);

    final dynamicCost = 3 + tree.headerBits + _tokenBits(dynLitLen, dynDistLen);
    final fixedCost = 3 + _tokenBits(_fixedLitLengths, _fixedDistLengths);

    // Stored has to fit one 16-bit LEN field; a token block can cover far more
    // input than that, so it is simply not a candidate when it does not.
    var storedCost = 1 << 30;
    if (_blockBytes <= 65535) {
      storedCost = 3 + ((8 - ((_bitCount + 3) & 7)) & 7) + 32 + 8 * _blockBytes;
    }

    if (storedCost <= dynamicCost && storedCost <= fixedCost) {
      _writeStored(_blockStart, _blockBytes, last);
    } else if (fixedCost <= dynamicCost) {
      _writeBits(last ? 1 : 0, 1);
      _writeBits(1, 2);
      _writeTokens(
        _fixedLitCodes,
        _fixedLitLengths,
        _fixedDistCodes,
        _fixedDistLengths,
      );
    } else {
      _writeBits(last ? 1 : 0, 1);
      _writeBits(2, 2);
      tree.write(this);
      _writeTokens(
        _canonicalCodes(dynLitLen),
        dynLitLen,
        _canonicalCodes(dynDistLen),
        dynDistLen,
      );
    }

    _tokenCount = 0;
    _blockStart += _blockBytes;
    _blockBytes = 0;
  }

  int _tokenBits(Uint8List litLen, Uint8List distLen) {
    var bits = litLen[256]; // one end-of-block marker
    for (var i = 0; i < _tokenCount; i++) {
      final d = _tokenDist[i];
      if (d == 0) {
        bits += litLen[_tokenLit[i]];
      } else {
        final lc = _lengthCodeOf[_tokenLit[i]];
        bits += litLen[257 + lc] + _lengthExtraBits[lc];
        final dc = _distCodeOf(d);
        bits += distLen[dc] + _distExtraBits[dc];
      }
    }
    return bits;
  }

  void _writeTokens(
    Uint16List litCodes,
    Uint8List litLen,
    Uint16List distCodes,
    Uint8List distLen,
  ) {
    for (var i = 0; i < _tokenCount; i++) {
      final d = _tokenDist[i];
      if (d == 0) {
        final b = _tokenLit[i];
        _writeBits(litCodes[b], litLen[b]);
      } else {
        final len = _tokenLit[i];
        final lc = _lengthCodeOf[len];
        _writeBits(litCodes[257 + lc], litLen[257 + lc]);
        final lx = _lengthExtraBits[lc];
        if (lx > 0) _writeBits(len - _lengthBase[lc], lx);
        final dc = _distCodeOf(d);
        _writeBits(distCodes[dc], distLen[dc]);
        final dx = _distExtraBits[dc];
        if (dx > 0) _writeBits(d - _distBase[dc], dx);
      }
    }
    _writeBits(litCodes[256], litLen[256]);
  }

  void _writeStored(int start, int length, bool last) {
    _writeBits(last ? 1 : 0, 1);
    _writeBits(0, 2);
    _alignToByte();
    _out.addByte(length & 0xFF);
    _out.addByte((length >> 8) & 0xFF);
    _out.addByte((length ^ 0xFFFF) & 0xFF);
    _out.addByte(((length ^ 0xFFFF) >> 8) & 0xFF);
    if (length > 0) _out.addRange(data, start, start + length);
  }

  // ── bit output ──────────────────────────────────────────────────────────────

  /// DEFLATE packs bits least-significant-first within a byte, but Huffman
  /// codes are defined most-significant-first. The code tables therefore hold
  /// pre-reversed codes so both can go through this one path.
  void _writeBits(int value, int count) {
    if (count == 0) return;
    _bitBuf |= value << _bitCount;
    _bitCount += count;
    while (_bitCount >= 8) {
      _out.addByte(_bitBuf & 0xFF);
      _bitBuf >>= 8;
      _bitCount -= 8;
    }
  }

  void _alignToByte() {
    if (_bitCount > 0) {
      _out.addByte(_bitBuf & 0xFF);
      _bitBuf = 0;
      _bitCount = 0;
    }
  }
}

/// The dynamic block's own header: the run-length-encoded list of code lengths
/// for the literal and distance trees, plus the Huffman code that encodes
/// *that* list.
class _CodeLengthTree {
  _CodeLengthTree._(
    this._symbols,
    this._extra,
    this._extraBits,
    this._lengths,
    this._codes,
    this._hclen,
    this.headerBits,
    this._numLit,
    this._numDist,
  );

  static const List<int> _order = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, //
  ];

  final Uint8List _symbols;
  final Uint8List _extra;
  final Uint8List _extraBits;
  final Uint8List _lengths;
  final Uint16List _codes;
  final int _hclen;
  final int headerBits;
  final int _numLit;
  final int _numDist;

  static _CodeLengthTree build(
    Uint8List litLen,
    int numLit,
    Uint8List distLen,
    int numDist,
  ) {
    final all = Uint8List(numLit + numDist);
    all.setRange(0, numLit, litLen);
    all.setRange(numLit, numLit + numDist, distLen);

    final symbols = <int>[];
    final extra = <int>[];
    final extraBits = <int>[];
    var i = 0;
    while (i < all.length) {
      final len = all[i];
      var runEnd = i + 1;
      while (runEnd < all.length && all[runEnd] == len) {
        runEnd++;
      }
      var count = runEnd - i;
      if (len == 0) {
        while (count >= 11) {
          final r = count < 138 ? count : 138;
          symbols.add(18);
          extra.add(r - 11);
          extraBits.add(7);
          count -= r;
        }
        while (count >= 3) {
          final r = count < 10 ? count : 10;
          symbols.add(17);
          extra.add(r - 3);
          extraBits.add(3);
          count -= r;
        }
      } else {
        symbols.add(len);
        extra.add(0);
        extraBits.add(0);
        count--;
        while (count >= 3) {
          final r = count < 6 ? count : 6;
          symbols.add(16);
          extra.add(r - 3);
          extraBits.add(2);
          count -= r;
        }
      }
      while (count > 0) {
        symbols.add(len);
        extra.add(0);
        extraBits.add(0);
        count--;
      }
      i = runEnd;
    }

    final freq = Uint32List(19);
    for (final s in symbols) {
      freq[s]++;
    }
    _forceTwoCodes(freq);
    final lengths = _packageMerge(freq, 7);
    final codes = _canonicalCodes(lengths);

    var hclen = 19;
    while (hclen > 4 && lengths[_order[hclen - 1]] == 0) {
      hclen--;
    }

    var bits = 5 + 5 + 4 + 3 * hclen;
    for (var k = 0; k < symbols.length; k++) {
      bits += lengths[symbols[k]] + extraBits[k];
    }

    return _CodeLengthTree._(
      Uint8List.fromList(symbols),
      Uint8List.fromList(extra),
      Uint8List.fromList(extraBits),
      lengths,
      codes,
      hclen,
      bits,
      numLit,
      numDist,
    );
  }

  void write(_Deflater d) {
    d._writeBits(_numLit - 257, 5);
    d._writeBits(_numDist - 1, 5);
    d._writeBits(_hclen - 4, 4);
    for (var k = 0; k < _hclen; k++) {
      d._writeBits(_lengths[_order[k]], 3);
    }
    for (var k = 0; k < _symbols.length; k++) {
      final s = _symbols[k];
      d._writeBits(_codes[s], _lengths[s]);
      if (_extraBits[k] > 0) d._writeBits(_extra[k], _extraBits[k]);
    }
  }
}

/// Guarantees at least two used symbols in a tree.
///
/// A one-symbol Huffman code is an *incomplete* code, which inflate accepts
/// only in one narrow case. Rather than depend on that, force a second symbol
/// exactly as zlib does; the cost is two wasted bits in the header.
void _forceTwoCodes(Uint32List freq) {
  var used = 0;
  for (var i = 0; i < freq.length; i++) {
    if (freq[i] != 0) used++;
    if (used >= 2) return;
  }
  for (var i = 0; i < freq.length && used < 2; i++) {
    if (freq[i] == 0) {
      freq[i] = 1;
      used++;
    }
  }
}

/// Optimal length-limited Huffman code lengths, by package-merge
/// (Larmore–Hirschberg, in Katajainen's coin-collector formulation).
///
/// The alternative — build an unconstrained tree and then flatten whatever
/// exceeded [maxBits] — is what zlib does, and it is where hand-rolled
/// deflaters usually break: the repair step has to give back exactly the right
/// amount of Kraft weight, and a stream whose code lengths do not sum to 1
/// fails in the decoder, not here. Package-merge cannot produce one.
Uint8List _packageMerge(Uint32List freq, int maxBits) {
  final lengths = Uint8List(freq.length);

  final syms = <int>[];
  for (var i = 0; i < freq.length; i++) {
    if (freq[i] != 0) syms.add(i);
  }
  if (syms.isEmpty) return lengths;
  if (syms.length == 1) {
    lengths[syms[0]] = 1;
    return lengths;
  }

  syms.sort((a, b) {
    final d = freq[a] - freq[b];
    return d != 0 ? d : a - b;
  });

  final leaves = List<_Coin>.generate(
    syms.length,
    (i) => _Coin(freq[syms[i]], syms[i], null, null),
    growable: false,
  );

  var list = leaves;
  for (var level = 1; level < maxBits; level++) {
    final packages = <_Coin>[];
    for (var i = 0; i + 1 < list.length; i += 2) {
      packages.add(
        _Coin(list[i].weight + list[i + 1].weight, -1, list[i], list[i + 1]),
      );
    }
    list = _mergeSorted(leaves, packages);
  }

  // A complete code over n symbols is exactly 2n-2 coins deep; each time a
  // symbol appears among them it gains one bit.
  final take = 2 * leaves.length - 2;
  final stack = <_Coin>[];
  for (var i = 0; i < take; i++) {
    stack.add(list[i]);
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node.symbol >= 0) {
        lengths[node.symbol]++;
      } else {
        stack.add(node.a!);
        stack.add(node.b!);
      }
    }
  }
  return lengths;
}

List<_Coin> _mergeSorted(List<_Coin> a, List<_Coin> b) {
  final out = List<_Coin>.filled(a.length + b.length, a.isEmpty ? b[0] : a[0]);
  var i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) {
    out[k++] = a[i].weight <= b[j].weight ? a[i++] : b[j++];
  }
  while (i < a.length) {
    out[k++] = a[i++];
  }
  while (j < b.length) {
    out[k++] = b[j++];
  }
  return out;
}

class _Coin {
  _Coin(this.weight, this.symbol, this.a, this.b);
  final int weight;

  /// -1 for a package, otherwise the symbol this coin belongs to.
  final int symbol;
  final _Coin? a;
  final _Coin? b;
}

/// Canonical codes (RFC 1951 §3.2.2), returned pre-reversed so they can be fed
/// straight to the LSB-first bit writer.
Uint16List _canonicalCodes(Uint8List lengths) {
  const maxBits = 15;
  final blCount = Uint32List(maxBits + 1);
  for (final l in lengths) {
    if (l != 0) blCount[l]++;
  }
  final nextCode = Uint32List(maxBits + 2);
  var code = 0;
  for (var bits = 1; bits <= maxBits; bits++) {
    code = (code + blCount[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  final codes = Uint16List(lengths.length);
  for (var i = 0; i < lengths.length; i++) {
    final l = lengths[i];
    if (l != 0) codes[i] = _reverseBits(nextCode[l]++, l);
  }
  return codes;
}

int _reverseBits(int value, int count) {
  var r = 0;
  for (var i = 0; i < count; i++) {
    r = (r << 1) | ((value >> i) & 1);
  }
  return r;
}

// ── static tables ─────────────────────────────────────────────────────────────

const List<int> _lengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const List<int> _lengthExtraBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const List<int> _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577,
];
const List<int> _distExtraBits = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];

/// Match length (3..258) to its length code index (0..28).
final Uint8List _lengthCodeOf = () {
  final t = Uint8List(_maxMatch + 1);
  for (var code = 0; code < 29; code++) {
    final base = _lengthBase[code];
    final span = code == 28 ? 1 : 1 << _lengthExtraBits[code];
    for (var l = base; l < base + span && l <= _maxMatch; l++) {
      t[l] = code;
    }
  }
  return t;
}();

/// Distance to its distance code, split at 256 the way zlib does: below that a
/// direct table, above it one entry per 128-byte span, which is exactly the
/// granularity the code boundaries fall on.
final Uint8List _distCodeLow = () {
  final t = Uint8List(256);
  for (var code = 0; code < 30; code++) {
    final base = _distBase[code] - 1;
    if (base >= 256) break;
    final span = 1 << _distExtraBits[code];
    for (var d = base; d < base + span && d < 256; d++) {
      t[d] = code;
    }
  }
  return t;
}();

final Uint8List _distCodeHigh = () {
  final t = Uint8List(256);
  for (var code = 0; code < 30; code++) {
    final base = _distBase[code] - 1;
    final span = 1 << _distExtraBits[code];
    for (var d = base; d < base + span; d++) {
      if (d >= 256 && (d >> 7) < 256) t[d >> 7] = code;
    }
  }
  return t;
}();

int _distCodeOf(int distance) {
  final d = distance - 1;
  return d < 256 ? _distCodeLow[d] : _distCodeHigh[d >> 7];
}

final Uint8List _fixedLitLengths = () {
  final t = Uint8List(288);
  for (var i = 0; i < 144; i++) {
    t[i] = 8;
  }
  for (var i = 144; i < 256; i++) {
    t[i] = 9;
  }
  for (var i = 256; i < 280; i++) {
    t[i] = 7;
  }
  for (var i = 280; i < 288; i++) {
    t[i] = 8;
  }
  return t;
}();

final Uint16List _fixedLitCodes = _canonicalCodes(_fixedLitLengths);

final Uint8List _fixedDistLengths = Uint8List(30)..fillRange(0, 30, 5);

final Uint16List _fixedDistCodes = _canonicalCodes(_fixedDistLengths);

// ── output buffer ─────────────────────────────────────────────────────────────

/// A growable byte buffer. `BytesBuilder` would do, but it lives in
/// `dart:typed_data` only on recent SDKs and this file is the one place in the
/// package that cannot afford a portability surprise.
class _ByteSink {
  Uint8List _buf = Uint8List(1024);
  int _length = 0;

  void addByte(int b) {
    if (_length == _buf.length) _grow(_length + 1);
    _buf[_length++] = b;
  }

  void addRange(Uint8List src, int start, int end) {
    final n = end - start;
    if (_length + n > _buf.length) _grow(_length + n);
    _buf.setRange(_length, _length + n, src, start);
    _length += n;
  }

  void _grow(int needed) {
    var cap = _buf.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    final next = Uint8List(cap);
    next.setRange(0, _length, _buf);
    _buf = next;
  }

  /// Copied, not a view: a view would keep the oversized backing store alive
  /// and would hand a caller a `buffer` full of trailing scratch bytes.
  Uint8List takeBytes() => _buf.sublist(0, _length);
}
