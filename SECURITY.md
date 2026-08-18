# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/armanicdev/payv-dart/security/advisories/new)
rather than opening a public issue.

## What counts as a vulnerability here

`payv` parses binary font files, which routinely arrive from a network or from
user upload. The threat model is: **a malicious font must not be able to do
anything worse than throw `FontFormatException`.**

Report it if you can make payv:

- read outside the buffer it was given, or crash the VM;
- loop forever, or allocate unboundedly, on a bounded input (a decompression
  bomb in a font table, a cyclic composite-glyph reference, a
  `ClassDef` that claims more ranges than it has bytes for);
- emit a PDF whose text layer says something different from the glyphs drawn —
  that is a *forgery* primitive on a document people rely on as evidence, and it
  is treated as a security issue, not a rendering bug.

Every read from font data is meant to be bounds-checked. A missing check is a
bug even if you cannot yet weaponise it.

## What is not a vulnerability

- A font whose licence forbids embedding being **refused**. That is deliberate;
  see `PayvFont.canEmbedInPdf`.
- Mis-shaped text for a script payv does not claim to support (Indic, Khmer,
  Myanmar). That is a missing feature — open a normal issue.
- Extractor disagreement about visual order for Arabic-Indic digit runs. That is
  documented in `doc/DEFECTS.md`; different PDF readers genuinely differ.

## Supported versions

Pre-1.0. Only the latest published version gets fixes.
