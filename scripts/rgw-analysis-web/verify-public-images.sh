#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES="${1:-$ROOT/releases/poc/rgw-analysis-web/values.yaml}"

fail() {
  echo "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required to verify public image manifests"
command -v yq >/dev/null 2>&1 || fail "yq is required to read release values"
test -f "$VALUES" || fail "values file not found: $VALUES"

while IFS=$'\t' read -r component repository tag digest; do
  if [ -z "$component" ] || [ -z "$repository" ] || [ -z "$tag" ] || [ -z "$digest" ]; then
    fail "incomplete image coordinate: $component"
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid image digest: $component"
  [ "$tag" != latest ] || fail "latest image tag is forbidden: $component"

  tag_output="$(docker buildx imagetools inspect "$repository:$tag")" ||
    fail "public image tag is unavailable: $component"
  actual_digest="$(awk '$1 == "Digest:" {print $2; exit}' <<<"$tag_output")"
  [ "$actual_digest" = "$digest" ] || fail "public image tag/digest mismatch: $component"
  docker buildx imagetools inspect "$repository@$digest" >/dev/null ||
    fail "public image digest is unavailable: $component"
done < <(yq e -r '.images | to_entries[] | [.key, .value.repository, .value.tag, .value.digest] | @tsv' "$VALUES")

echo "public image digests verified"
