#!/usr/bin/env bash
set -euo pipefail

test "${FAKE_SCENARIO:-healthy}" != unreachable-http || exit 28
if [ "${FAKE_SCENARIO:-healthy}" = legacy-loading ]; then
  cat "$FAKE_FIXTURE_ROOT/result-legacy-loading.html"
  exit 0
fi
cat "$FAKE_FIXTURE_ROOT/result.html"
