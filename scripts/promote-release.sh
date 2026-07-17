#!/usr/bin/env bash
set -euo pipefail

ROOT="${FEDERATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/promote-release.sh RELEASE PROMOTION_JSON

Apply one child release promotion to the Federation working tree. The payload
must carry one full source SHA and the immutable tag/digest for every image.
Pinned releases are intentionally left unchanged.
EOF
}

[ "$#" -eq 2 ] || {
  usage >&2
  exit 2
}

release="$1"
payload="$2"
[[ "$release" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  fail "invalid release name: $release"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

descriptor="$ROOT/releases/$release/release.yaml"
[ -f "$descriptor" ] || fail "release descriptor not found: releases/$release/release.yaml"
[ -f "$payload" ] || fail "promotion payload not found: $payload"

mode="$(yq e -r '.promotion.mode' "$descriptor")"
case "$mode" in
  pinned)
    echo "release is pinned; promotion skipped: $release"
    exit 0
    ;;
  tracked) ;;
  *) fail "unsupported promotion mode for $release: $mode" ;;
esac

jq -e '
  type == "object" and
  (keys | sort) == ["apiVersion", "images", "kind", "release", "source"] and
  .apiVersion == "scalex.io/v1alpha1" and
  .kind == "ReleasePromotion" and
  (.release | type == "string") and
  (.source | type == "object") and
  (.source | keys | sort) == ["path", "repoURL", "revision"] and
  (.source.repoURL | type == "string") and
  (.source.path | type == "string") and
  (.source.revision | type == "string") and
  (.images | type == "object") and
  (.images | length) > 0 and
  all(.images[];
    type == "object" and
    (keys | sort) == ["digest", "repository", "sourceRevision", "tag"] and
    all(.[]; type == "string")
  )
' "$payload" >/dev/null || fail "invalid promotion payload contract"

[ "$(jq -r '.release' "$payload")" = "$release" ] ||
  fail "promotion release does not match target: $release"

repo_url="$(jq -r '.source.repoURL' "$payload")"
chart_path="$(jq -r '.source.path' "$payload")"
revision="$(jq -r '.source.revision' "$payload")"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "promotion revision must be a full commit SHA"
[ "$revision" != 0000000000000000000000000000000000000000 ] ||
  fail "promotion revision cannot be the all-zero placeholder"
[ "$repo_url" = "$(yq e -r '.source.repoURL' "$descriptor")" ] ||
  fail "promotion source repository does not match the release contract"
[ "$chart_path" = "$(yq e -r '.source.path' "$descriptor")" ] ||
  fail "promotion chart path does not match the release contract"

values_path="$(yq e -r '.values.path' "$descriptor")"
[ "$values_path" = "releases/$release/values.yaml" ] ||
  fail "release values path does not match release identity"
values="$ROOT/$values_path"
[ -f "$values" ] || fail "release values not found: $values_path"

current_keys="$(yq e -r '.images | keys | .[]' "$values" | LC_ALL=C sort)"
payload_keys="$(jq -r '.images | keys[]' "$payload" | LC_ALL=C sort)"
[ -n "$current_keys" ] || fail "release has no promotable images: $release"
[ "$payload_keys" = "$current_keys" ] ||
  fail "promotion must contain exactly the release image set"

while IFS= read -r component; do
  repository="$(jq -r --arg component "$component" '.images[$component].repository' "$payload")"
  tag="$(jq -r --arg component "$component" '.images[$component].tag' "$payload")"
  digest="$(jq -r --arg component "$component" '.images[$component].digest' "$payload")"
  image_revision="$(jq -r --arg component "$component" '.images[$component].sourceRevision' "$payload")"

  [ "$repository" = "$(COMPONENT="$component" yq e -r '.images[strenv(COMPONENT)].repository' "$values")" ] ||
    fail "promotion repository does not match release image: $component"
  [ "$tag" = "sha-$revision" ] || fail "promotion tag must be sha-$revision: $component"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "promotion digest must be an immutable sha256 digest: $component"
  [ "$image_revision" = "$revision" ] ||
    fail "promotion image revision does not match source revision: $component"
done <<<"$current_keys"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
descriptor_next="$tmp/release.yaml"
values_next="$tmp/values.yaml"
cp "$descriptor" "$descriptor_next"
cp "$values" "$values_next"

REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$descriptor_next"
while IFS= read -r component; do
  tag="$(jq -r --arg component "$component" '.images[$component].tag' "$payload")"
  digest="$(jq -r --arg component "$component" '.images[$component].digest' "$payload")"
  COMPONENT="$component" TAG="$tag" DIGEST="$digest" REVISION="$revision" yq -i '
    .images[strenv(COMPONENT)].tag = strenv(TAG) |
    .images[strenv(COMPONENT)].digest = strenv(DIGEST) |
    .images[strenv(COMPONENT)].sourceRevision = strenv(REVISION)
  ' "$values_next"
done <<<"$current_keys"

mv "$descriptor_next" "$descriptor"
mv "$values_next" "$values"

echo "promoted $release to $revision"
echo "updated releases/$release/release.yaml"
echo "updated $values_path"
