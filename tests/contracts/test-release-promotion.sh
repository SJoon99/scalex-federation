#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: missing $tool" >&2
    exit 77
  }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
revision=1111111111111111111111111111111111111111

make_federation() {
  local target="$1"
  mkdir -p "$target/releases/temp-poc" "$target/scripts"
  cp "$ROOT/releases/temp-poc/release.yaml" "$target/releases/temp-poc/release.yaml"
  cp "$ROOT/releases/temp-poc/values.yaml" "$target/releases/temp-poc/values.yaml"
  cp "$ROOT/scripts/promote-release.sh" "$target/scripts/promote-release.sh"
  yq -i '.promotion.mode = "tracked"' "$target/releases/temp-poc/release.yaml"
}

make_payload() {
  local output="$1"
  jq -n --arg revision "$revision" '{
    apiVersion: "scalex.io/v1alpha1",
    kind: "ReleasePromotion",
    release: "temp-poc",
    source: {
      repoURL: "https://github.com/BellTigerLee/temp-poc.git",
      path: "chart",
      revision: $revision
    },
    images: {
      datasetIngest: {
        repository: "docker.io/belltigerlee/temp-poc-dataset-ingest",
        tag: ("sha-" + $revision),
        digest: ("sha256:" + ("1" * 64)),
        sourceRevision: $revision
      },
      batchAnalyzer: {
        repository: "docker.io/belltigerlee/temp-poc-batch-analyzer",
        tag: ("sha-" + $revision),
        digest: ("sha256:" + ("2" * 64)),
        sourceRevision: $revision
      },
      reportGenerator: {
        repository: "docker.io/belltigerlee/temp-poc-report-generator",
        tag: ("sha-" + $revision),
        digest: ("sha256:" + ("3" * 64)),
        sourceRevision: $revision
      }
    }
  }' >"$output"
}

happy="$tmp/happy"
make_federation "$happy"
make_payload "$tmp/promotion.json"
runtime_before="$(yq e -o=json -I=0 'del(.images)' "$happy/releases/temp-poc/values.yaml")"
FEDERATION_ROOT="$happy" "$happy/scripts/promote-release.sh" temp-poc "$tmp/promotion.json" >/dev/null
[ "$(yq e -r '.source.revision' "$happy/releases/temp-poc/release.yaml")" = "$revision" ]
[ "$(yq e -r '[.images[].sourceRevision] | unique | .[]' "$happy/releases/temp-poc/values.yaml")" = "$revision" ]
[ "$(yq e -r '[.images[].tag] | unique | .[]' "$happy/releases/temp-poc/values.yaml")" = "sha-$revision" ]
[ "$(yq e -o=json -I=0 'del(.images)' "$happy/releases/temp-poc/values.yaml")" = "$runtime_before" ]

pinned="$tmp/pinned"
make_federation "$pinned"
yq -i '.promotion.mode = "pinned"' "$pinned/releases/temp-poc/release.yaml"
before="$(sha256sum "$pinned/releases/temp-poc/release.yaml" "$pinned/releases/temp-poc/values.yaml")"
FEDERATION_ROOT="$pinned" "$pinned/scripts/promote-release.sh" temp-poc "$tmp/promotion.json" >/dev/null
after="$(sha256sum "$pinned/releases/temp-poc/release.yaml" "$pinned/releases/temp-poc/values.yaml")"
[ "$after" = "$before" ] || {
  echo "pinned release was modified" >&2
  exit 1
}

expect_reject() {
  local name="$1"
  local expression="$2"
  local expected="$3"
  local fixture="$tmp/$name"
  make_federation "$fixture"
  make_payload "$tmp/$name.json"
  jq "$expression" "$tmp/$name.json" >"$tmp/$name-mutated.json"
  if FEDERATION_ROOT="$fixture" "$fixture/scripts/promote-release.sh" \
      temp-poc "$tmp/$name-mutated.json" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "invalid promotion unexpectedly passed: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$name.err" || {
    cat "$tmp/$name.err" >&2
    exit 1
  }
}

expect_reject missing-image 'del(.images.reportGenerator)' \
  'promotion must contain exactly the release image set'
expect_reject repository-drift '.images.datasetIngest.repository = "docker.io/example/other"' \
  'promotion repository does not match release image: datasetIngest'
expect_reject mutable-tag '.images.batchAnalyzer.tag = "latest"' \
  "promotion tag must be sha-$revision: batchAnalyzer"
expect_reject revision-drift '.images.reportGenerator.sourceRevision = ("2" * 40)' \
  'promotion image revision does not match source revision: reportGenerator'
expect_reject invalid-digest '.images.datasetIngest.digest = "sha256:short"' \
  'promotion digest must be an immutable sha256 digest: datasetIngest'

echo "release promotion contracts passed"
