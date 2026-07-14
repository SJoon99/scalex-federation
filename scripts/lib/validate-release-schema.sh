#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$ROOT/contracts/federation-release-v1alpha1.schema.json"
EXPECTED_VERSION=0.33.3

[ "$#" -gt 0 ] || {
  echo "at least one release descriptor is required" >&2
  exit 1
}
command -v check-jsonschema >/dev/null 2>&1 || {
  echo "required command not found: check-jsonschema==$EXPECTED_VERSION" >&2
  exit 1
}
[ "$(check-jsonschema --version)" = "check-jsonschema, version $EXPECTED_VERSION" ] || {
  echo "check-jsonschema version must be $EXPECTED_VERSION" >&2
  exit 1
}
check-jsonschema --check-metaschema "$SCHEMA" >/dev/null || {
  echo "release schema metaschema validation failed" >&2
  exit 1
}
check-jsonschema --schemafile "$SCHEMA" "$@" || {
  echo "release schema validation failed" >&2
  exit 1
}
