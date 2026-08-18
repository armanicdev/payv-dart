<!--
Thanks for contributing. The bar is in CONTRIBUTING.md; the short version is
below. Delete anything that does not apply.
-->

## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The reasoning, not a restatement of the diff. If a real font broke without
this change, name it — that is the comment worth keeping. -->

## Checks

- [ ] `dart test` passes (`dart test --tags shaping` in particular — that gate
      compares glyph ids against HarfBuzz and must not be loosened)
- [ ] `dart analyze --fatal-infos --fatal-warnings` is clean
- [ ] `dart format` with the SDK version CI's `format` job pins
- [ ] `lib/` still imports no `dart:io` and no Flutter, and adds no dependency
- [ ] New corpus cases regenerated with `tool/gen_harfbuzz_corpus.py`, if shaping changed

## If this changes shaping output

<!-- Paste the `hb-shape` output for the affected string. Where payv and
HarfBuzz disagree, payv is wrong — unless you can cite the spec saying
otherwise, in which case say so here. -->
