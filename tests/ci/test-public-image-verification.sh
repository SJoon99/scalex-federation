#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/tests/fixtures/ci/fake-docker.sh" "$tmp/bin/docker"
chmod +x "$tmp/bin/docker"

values_files=(
  "$ROOT/releases/poc/rgw-analysis-web/values.yaml"
  "$ROOT/releases/cuty/rgw-analysis-web/values.yaml"
)
: >"$tmp/images.tsv"
: >"$tmp/expected-refs.txt"
for values in "${values_files[@]}"; do
  yq e -r '.images | to_entries[] | [.value.repository + ":" + .value.tag, .value.digest] | @tsv' \
    "$values" >>"$tmp/images.tsv"
  yq e -r -N '.images | to_entries[] | [(.value.repository + ":" + .value.tag), (.value.repository + "@" + .value.digest)] | .[]' \
    "$values" >>"$tmp/expected-refs.txt"
done
LC_ALL=C sort -o "$tmp/expected-refs.txt" "$tmp/expected-refs.txt"

PATH="$tmp/bin:$PATH" FAKE_IMAGE_MAP="$tmp/images.tsv" FAKE_DOCKER_LOG="$tmp/docker.log" \
  "$ROOT/scripts/rgw-analysis-web/verify-public-images.sh" >/dev/null
LC_ALL=C sort "$tmp/docker.log" >"$tmp/actual-refs.txt"
cmp -s "$tmp/expected-refs.txt" "$tmp/actual-refs.txt" || {
  echo "default public image verification did not inspect both active releases" >&2
  exit 1
}

for values in "${values_files[@]}"; do
  PATH="$tmp/bin:$PATH" FAKE_IMAGE_MAP="$tmp/images.tsv" \
    "$ROOT/scripts/rgw-analysis-web/verify-public-images.sh" "$values" >/dev/null
done

if PATH="$tmp/bin:$PATH" FAKE_IMAGE_MAP="$tmp/images.tsv" FAKE_IMAGE_SCENARIO=mismatch \
  "$ROOT/scripts/rgw-analysis-web/verify-public-images.sh" >"$tmp/mismatch.log" 2>&1; then
  echo "mismatched public tag/digest unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'public image tag/digest mismatch' "$tmp/mismatch.log"

echo "public image verification fixtures passed"
