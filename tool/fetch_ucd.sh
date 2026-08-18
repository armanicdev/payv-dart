#!/usr/bin/env bash
# Fetches the Unicode Character Database files this package builds and tests
# against.
#
#     tool/fetch_ucd.sh            # default UCD version
#     tool/fetch_ucd.sh 17.0.0     # a specific one
#
# You do NOT need this to USE payv, or even to build it: the derived tables live
# in lib/src/text/unicode_data.g.dart and are checked in, so a clean build never
# touches the network. You need it for two things:
#
#   1. Regenerating those tables — `dart run tool/gen_unicode_tables.dart`,
#      which reads the first group below.
#   2. Running the Unicode bidi CONFORMANCE suites, the second group. Those two
#      files are 15 MB together, which is why they are fetched rather than
#      vendored — and why `dart test` on a fresh clone reports 2 skipped tests
#      until you run this. CI runs it on every push, so the gate is real there
#      whether or not you run it locally.
set -euo pipefail

VER="${1:-16.0.0}"
cd "$(dirname "$0")"
mkdir -p ucd && cd ucd

# Property data — inputs to tool/gen_unicode_tables.dart.
PROPS=(
  ArabicShaping.txt
  UnicodeData.txt
  BidiBrackets.txt
  BidiMirroring.txt
  Scripts.txt
  DerivedCoreProperties.txt
)

# Conformance suites — inputs to test/text/bidi_conformance_test.dart.
# Large, and only ever read by tests.
TESTS=(
  BidiTest.txt
  BidiCharacterTest.txt
)

echo "Unicode $VER → $(pwd)"
for f in "${PROPS[@]}"; do
  curl -fsS -o "$f" "https://www.unicode.org/Public/$VER/ucd/$f"
  printf '  %-28s %s\n' "$f" "$(wc -c < "$f" | tr -d ' ') bytes"
done
for f in "${TESTS[@]}"; do
  curl -fsS -o "$f" "https://www.unicode.org/Public/$VER/ucd/$f"
  printf '  %-28s %s\n' "$f" "$(wc -c < "$f" | tr -d ' ') bytes"
done

echo
echo "Done. Now:"
echo "  dart run tool/gen_unicode_tables.dart   # regenerate the derived tables"
echo "  dart test                               # conformance suites now run"
