/// Four-character OpenType tags, packed into an `int`.
///
/// Tags are compared once per lookup per glyph during shaping, so they are
/// carried as packed uint32s and never as `String`. [Tag.toTagString] exists
/// only for diagnostics and test failure messages.
library;

extension type const Tag(int value) implements int {
  /// Packs a 4-character ASCII tag. Shorter tags are space-padded, which is
  /// what OpenType itself does (`'kern'`, but `'DFLT'` and `'ss01'`).
  factory Tag.parse(String s) {
    assert(s.length <= 4, 'OpenType tags are at most 4 characters: "$s"');
    var v = 0;
    for (var i = 0; i < 4; i++) {
      final c = i < s.length ? s.codeUnitAt(i) : 0x20;
      assert(c <= 0x7F, 'OpenType tags are ASCII: "$s"');
      v = (v << 8) | c;
    }
    return Tag(v);
  }

  String get asString => String.fromCharCodes([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);

  // ── SFNT tables ─────────────────────────────────────────────────────────────
  static const head = Tag(0x68656164);
  static const hhea = Tag(0x68686561);
  static const hmtx = Tag(0x686D7478);
  static const maxp = Tag(0x6D617870);
  static const cmap = Tag(0x636D6170);
  static const name = Tag(0x6E616D65);
  static const os2 = Tag(0x4F532F32); // 'OS/2'
  static const post = Tag(0x706F7374);
  static const loca = Tag(0x6C6F6361);
  static const glyf = Tag(0x676C7966);
  static const cff = Tag(0x43464620); // 'CFF '
  static const cff2 = Tag(0x43464632);
  static const gsub = Tag(0x47535542);
  static const gpos = Tag(0x47504F53);
  static const gdef = Tag(0x47444546);
  static const fvar = Tag(0x66766172);
  static const gvar = Tag(0x67766172);
  static const avar = Tag(0x61766172);
  static const hvar = Tag(0x48564152);
  static const mvar = Tag(0x4D564152);
  static const stat = Tag(0x53544154);
  static const vhea = Tag(0x76686561);
  static const vmtx = Tag(0x766D7478);
  static const prep = Tag(0x70726570);
  static const fpgm = Tag(0x6670676D);
  static const cvt = Tag(0x63767420); // 'cvt '
  static const gasp = Tag(0x67617370);

  // ── scripts ─────────────────────────────────────────────────────────────────
  static const dflt = Tag(0x44464C54); // 'DFLT'
  static const arab = Tag(0x61726162);
  static const latn = Tag(0x6C61746E);
  static const syrc = Tag(0x73797263);
  static const nko = Tag(0x6E6B6F20); // 'nko '
  static const mong = Tag(0x6D6F6E67);
  static const thaa = Tag(0x74686161);
  static const phag = Tag(0x70686167);
  static const mand = Tag(0x6D616E64);
  static const adlm = Tag(0x61646C6D);

  // ── features ────────────────────────────────────────────────────────────────
  //
  // The Arabic set is ordered the way the shaper must apply it, not
  // alphabetically. `stch` is absent on purpose: it needs a justification pass
  // we do not run.
  static const ccmp = Tag(0x63636D70);
  static const locl = Tag(0x6C6F636C);
  static const isol = Tag(0x69736F6C);
  static const init = Tag(0x696E6974);
  static const medi = Tag(0x6D656469);
  static const med2 = Tag(0x6D656432);
  static const fina = Tag(0x66696E61);
  static const fin2 = Tag(0x66696E32);
  static const fin3 = Tag(0x66696E33);
  static const rlig = Tag(0x726C6967);
  static const rclt = Tag(0x72636C74);
  static const calt = Tag(0x63616C74);
  static const liga = Tag(0x6C696761);
  static const clig = Tag(0x636C6967);
  static const dlig = Tag(0x646C6967);
  static const mset = Tag(0x6D736574);

  static const kern = Tag(0x6B65726E);
  static const mark = Tag(0x6D61726B);
  static const mkmk = Tag(0x6D6B6D6B);
  static const curs = Tag(0x63757273);
  static const cpsp = Tag(0x63707370);

  static const tnum = Tag(0x746E756D);
  static const lnum = Tag(0x6C6E756D);
  static const onum = Tag(0x6F6E756D);
  static const pnum = Tag(0x706E756D);
  static const frac = Tag(0x66726163);
  static const numr = Tag(0x6E756D72);
  static const dnom = Tag(0x646E6F6D);
  static const salt = Tag(0x73616C74);
  static const ss01 = Tag(0x73733031);
  static const smcp = Tag(0x736D6370);
  static const c2sc = Tag(0x63327363);
  static const unic = Tag(0x756E6963);

  // ── language systems ────────────────────────────────────────────────────────
  static const kur = Tag(0x4B555220); // 'KUR ' — Kurdish
  static const ara = Tag(0x41524120); // 'ARA '
  static const fas = Tag(0x46415220); // 'FAR ' — Persian, per the OT registry
  static const urd = Tag(0x55524420); // 'URD '
}
