# Contributing to payv

## The bar

This package renders documents people rely on — invoices, contracts, receipts,
certificates. A substituted letter there is not a rendering artifact; it is
wrong information on a record someone will act on. So:

**Any change to the shaping path must keep `dart test --tags shaping` green.**
That suite compares our glyph ids and positions against HarfBuzz byte-for-byte.
If you believe HarfBuzz is wrong, say so in the PR with a spec citation; do not
loosen the test.

Adding a script, a feature or a font that exercises a new code path? Add cases
to `tool/gen_harfbuzz_corpus.py` and regenerate:

```bash
pip install uharfbuzz fonttools
python3 tool/gen_harfbuzz_corpus.py
```

## Setup

```bash
dart pub get
dart test
```

Two bidi conformance tests need the Unicode suites, which are 15 MB and fetched
rather than vendored — a fresh clone reports them as *skipped*:

```bash
tool/fetch_ucd.sh    # then `dart test` runs the whole suite
```

The end-to-end tests shell out to `pdftotext` and `mutool` and self-skip if
neither is installed:

```bash
brew install poppler mupdf-tools      # macOS
sudo apt install poppler-utils mupdf-tools   # Debian/Ubuntu
```

CI installs both and **fails if any test skips**, so a PR that passes locally
with skips will still be graded on the full suite.

The Unicode tables in `lib/src/text/unicode_data.g.dart` are generated and
checked in, so a normal build never touches the network. To regenerate against
a newer UCD:

```bash
tool/fetch_ucd.sh 17.0.0
dart run tool/gen_unicode_tables.dart
```

## House rules

- **Zero runtime dependencies, and `lib/` imports no `dart:io` and no Flutter.**
  This package has to run on the web and on a server. A dependency that breaks
  that will be rejected however convenient it is.
- **Bounds-check every read from font data.** Fonts arrive over networks.
  Throw `FontFormatException`; never read past the buffer.
- **Comment the why, not the what.** A comment restating the code is noise. A
  comment recording which real font broke without a branch is the point.
- `dart format` before you push — **with Dart 3.10.8**, the version CI's `format`
  job pins. `dart format` output changes between SDK releases, so a newer or
  older SDK will produce a tree CI rejects through no fault of your diff. Check
  yours with `dart --version`; if it differs, either match it or say so in the
  PR and let the maintainer reformat. The pin is bumped deliberately, never by
  a `stable` that moved underneath the repo.

## Good first contributions

- A **CFF/CFF2 charstring interpreter** — the seams are in place
  (`OpenTypeFont.glyf` is the only outline entry point).
- **More shapers** — Indic, Khmer and Myanmar need their own reordering passes.
- **Tagged PDF / PDF-UA structure trees**, currently the largest known gap.
- More corpus cases, especially from fonts we do not test against.
