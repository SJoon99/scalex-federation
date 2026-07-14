#!/usr/bin/env bash
set -euo pipefail

ref="${*: -1}"
if [ -n "${FAKE_DOCKER_LOG:-}" ]; then
  printf '%s\n' "$ref" >>"$FAKE_DOCKER_LOG"
fi
if [[ "$ref" == *@sha256:* ]]; then
  exit 0
fi
digest="$(awk -F'\t' -v ref="$ref" '$1 == ref {print $2}' "$FAKE_IMAGE_MAP")"
[ -n "$digest" ] || exit 1
if [ "${FAKE_IMAGE_SCENARIO:-healthy}" = mismatch ]; then
  digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fi
printf 'Name: %s\nDigest: %s\n' "$ref" "$digest"
