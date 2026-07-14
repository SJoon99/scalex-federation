#!/usr/bin/env bash
set -euo pipefail

if [ "${FAKE_SCENARIO:-}" = yq-failure ]; then
  for argument in "$@"; do
    case "$argument" in
      */karmada/overrides/*) exit 42 ;;
    esac
  done
fi

exec "${REAL_YQ:?REAL_YQ is required}" "$@"
