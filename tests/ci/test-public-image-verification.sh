#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/tests/fixtures/ci/fake-docker.sh" "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"

yq e -r '.images | to_entries[] | [.value.repository + ":" + .value.tag, .value.digest] | @tsv' \
  "$ROOT/releases/poc/rgw-analysis-web/values.yaml" > "$tmp/images.tsv"

PATH="$tmp/bin:$PATH" FAKE_IMAGE_MAP="$tmp/images.tsv" \
  "$ROOT/scripts/rgw-analysis-web/verify-public-images.sh" >/dev/null

if PATH="$tmp/bin:$PATH" FAKE_IMAGE_MAP="$tmp/images.tsv" FAKE_IMAGE_SCENARIO=mismatch \
  "$ROOT/scripts/rgw-analysis-web/verify-public-images.sh" >"$tmp/mismatch.log" 2>&1; then
  echo "mismatched public tag/digest unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'public image tag/digest mismatch' "$tmp/mismatch.log"

echo "public image verification fixtures passed"
