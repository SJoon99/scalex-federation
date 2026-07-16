#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required to verify public image manifests"
command -v yq >/dev/null 2>&1 || fail "yq is required to read release values"

values_files=()
if [ "$#" -gt 0 ]; then
  values_files=("$@")
else
  mapfile -t descriptors < <(
    find "$ROOT/releases" -mindepth 2 -maxdepth 2 -name release.yaml -type f | LC_ALL=C sort
  )
  [ "${#descriptors[@]}" -gt 0 ] || fail "no active release descriptors found"
  for descriptor in "${descriptors[@]}"; do
    [ "$(yq e -r '.state' "$descriptor")" = active ] || continue
    values_rel="$(yq e -r '.values.path' "$descriptor")"
    [[ "$values_rel" =~ ^releases/[a-z0-9-]+/values\.yaml$ ]] ||
      fail "invalid values path in release descriptor: $descriptor"
    values_files+=("$ROOT/$values_rel")
  done
  [ "${#values_files[@]}" -gt 0 ] || fail "no active release descriptors found"
fi

for values in "${values_files[@]}"; do
  test -f "$values" || fail "values file not found: $values"
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
  done < <(yq e -r '.images | to_entries[] | [.key, .value.repository, .value.tag, .value.digest] | @tsv' "$values")
done

echo "public image digests verified for ${#values_files[@]} release value file(s)"
