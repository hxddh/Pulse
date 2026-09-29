#!/usr/bin/env bash
# Every source gate, in one place.
#
# CI, release.yml, scripts/release.sh and PulseBar/Scripts/package.sh each
# used to carry their own copy of this list, and by 11.0 the copies had
# drifted (the release job skipped some of the lint greps). Everything calls this now; adding a gate is one line here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/version_check.py
python3 scripts/agent_catalog_check.py
python3 scripts/coverage_check.py
python3 scripts/matrix_check.py
python3 scripts/scenario_map.py
python3 scripts/surface_check.py
python3 scripts/vendor_formats_check.py
python3 scripts/make_agent_icons.py --check
python3 scripts/appearance_check.py
python3 -m py_compile scripts/*.py

# The legacy Python collector was deleted in 0.99. Nothing in the product may
# fork an interpreter to observe a session again.
if grep -rn "activity_scan" --include='*.swift' PulseBar/Sources; then
  echo "::error::the harvest path must not reference the deleted Python collector"
  exit 1
fi
# SwiftPM's generated Bundle.module accessor fatalErrors when the bundle moves
# (the 0.21–0.23 launch crash). PulseResources resolves it and returns nil.
if grep -rnE --include='*.swift' '^[^/]*[^.a-zA-Z]Bundle\.module' PulseBar/Sources; then
  echo "::error::use PulseResources instead of Bundle.module — it fatalErrors when the bundle moves"
  exit 1
fi
echo "gates OK"
